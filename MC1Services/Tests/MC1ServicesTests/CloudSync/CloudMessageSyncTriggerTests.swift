import Foundation
@testable import MC1Services
import Testing

// MARK: - Fixtures

private enum Fixture {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 53 })
  static let sharedSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 61 })
  static let wireTimestamp: UInt32 = 1_704_067_200

  static func makeTwoRadioStore() async throws -> (store: PersistenceStore, radioA: UUID, radioB: UUID) {
    let radioA = UUID()
    let radioB = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioA)
    try await store.saveDevice(
      DeviceDTO.testDevice(
        id: radioB, radioID: radioB,
        publicKey: Data(repeating: 0x04, count: ProtocolLimits.publicKeySize)
      )
    )
    return (store, radioA, radioB)
  }

  @discardableResult
  static func saveContact(
    in store: PersistenceStore,
    radioID: UUID,
    publicKey: Data = Fixture.peerKey
  ) async throws -> ContactDTO {
    let contact = ContactDTO.testContact(id: UUID(), radioID: radioID, publicKey: publicKey)
    try await store.saveContact(contact)
    return contact
  }

  @discardableResult
  static func saveChannel(
    in store: PersistenceStore,
    radioID: UUID,
    index: UInt8,
    secret: Data
  ) async throws -> ChannelDTO {
    let channel = ChannelDTO.testChannel(radioID: radioID, index: index, secret: secret)
    try await store.saveChannel(channel)
    return channel
  }

  static func dmRows(_ store: PersistenceStore, contactID: UUID) async throws -> [MessageDTO] {
    try await store.fetchMessages(contactID: contactID, limit: 100, offset: 0)
  }
}

// MARK: - Event adaptation

@Suite("CloudMessageSyncTrigger — event adaptation")
struct CloudMessageSyncTriggerAdaptationTests {
  /// Incoming DM and channel events are the two MC1 already emits after
  /// persistence, and both carry the full DTO — so no new upstream event is
  /// needed for incoming history.
  @Test
  func `Incoming message events adapt to a persisted trigger`() {
    let dm = MessageDTO.testDirectMessage(text: "hi", direction: .incoming)
    let channel = MessageDTO.testChannelMessage(text: "hi", direction: .incoming, senderNodeName: "Alice")
    let contact = ContactDTO.testContact(publicKey: Fixture.peerKey)

    #expect(CloudMessageSyncTrigger.from(.directMessageReceived(message: dm, contact: contact))
      == .messagePersisted(dm))
    #expect(CloudMessageSyncTrigger.from(.channelMessageReceived(message: channel, channelIndex: 1))
      == .messagePersisted(channel))
  }

  /// Events that are not message history produce no trigger, so a subscriber may
  /// forward its whole stream unfiltered.
  @Test
  func `Non-history events produce no trigger`() {
    #expect(CloudMessageSyncTrigger.from(.contactsChanged) == nil)
    #expect(CloudMessageSyncTrigger.from(.conversationsChanged) == nil)
    #expect(CloudMessageSyncTrigger.from(.reactionReceived(messageID: UUID(), summary: "👍:1")) == nil)
  }

  /// Descriptions reach logs; message text must not.
  @Test
  func `Trigger descriptions omit message text`() {
    let secretText = "RENDEZVOUS AT GRID 44821"
    let trigger = CloudMessageSyncTrigger.messagePersisted(
      MessageDTO.testDirectMessage(text: secretText, direction: .incoming)
    )
    #expect(!trigger.description.contains(secretText))
    #expect(!trigger.description.contains("44821"))
    #expect(!trigger.debugDescription.contains(secretText))
    #expect(trigger.description.contains("textBytes:"))
  }
}

// MARK: - Incoming integration

@Suite("CloudMessageSyncDriver — incoming integration")
struct CloudMessageSyncDriverIncomingTests {
  /// The DTO on the event is already persisted, so the driver can export it
  /// immediately and the row is found.
  @Test
  func `Incoming DM event drives reconciliation across radios`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let received = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "from the mesh",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(received)

    let driver = CloudMessageSyncDriver(store: store)
    let outcome = try #require(
      try await driver.handle(
        .directMessageReceived(message: received, contact: contactA),
        across: [radioA, radioB]
      )
    )

    #expect(outcome.unchangedRadioIDs == [radioA])
    #expect(outcome.insertedRadioIDs == [radioB])
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// Section 13A: two radios each fire their own local event for one logical
  /// message. Two observations, one fingerprint, no third row.
  @Test
  func `Same DM received on two radios yields two events and two observations`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "both heard it",
      timestamp: Fixture.wireTimestamp, direction: .incoming, pathLength: 3, snr: -7.25
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "both heard it",
      timestamp: Fixture.wireTimestamp, direction: .incoming, pathLength: 1, snr: 4.5
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let driver = CloudMessageSyncDriver(store: store)
    let fromA = try #require(try await driver.handle(
      .directMessageReceived(message: onA, contact: contactA), across: [radioA, radioB]
    ))
    let fromB = try #require(try await driver.handle(
      .directMessageReceived(message: onB, contact: contactB), across: [radioA, radioB]
    ))

    // One logical message despite two independent local events.
    #expect(fromA.fingerprint == fromB.fingerprint)
    #expect(fromA.insertedRadioIDs.isEmpty)
    #expect(fromB.insertedRadioIDs.isEmpty)

    // Both observations survive, unmoved, with their own reception metadata.
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
    #expect(try await store.fetchMessage(id: onA.id)?.snr == -7.25)
    #expect(try await store.fetchMessage(id: onB.id)?.snr == 4.5)
    #expect(try await store.fetchMessage(id: onA.id)?.radioID == radioA)
    #expect(try await store.fetchMessage(id: onB.id)?.radioID == radioB)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// Duplicate delivery of the same event is harmless.
  @Test
  func `Duplicate incoming events are idempotent`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let received = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "twice over",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(received)

    let driver = CloudMessageSyncDriver(store: store)
    let event = SyncDataEvent.directMessageReceived(message: received, contact: contactA)
    for _ in 0..<5 {
      _ = try await driver.handle(event, across: [radioA, radioB])
    }

    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
  }

  /// Section 13B: strong channel across differing local slots.
  @Test
  func `Incoming channel event fans to the matching secret at another slot`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 7, secret: Fixture.sharedSecret)

    let received = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "net at 1900",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(received)

    let driver = CloudMessageSyncDriver(store: store)
    let outcome = try #require(try await driver.handle(
      .channelMessageReceived(message: received, channelIndex: 3), across: [radioA, radioB]
    ))

    #expect(outcome.insertedRadioIDs == [radioB])
    let rowB = try #require(
      try await store.fetchMessages(radioID: radioB, channelIndex: 7, limit: 10, offset: 0).first
    )
    #expect(rowB.channelIndex == 7)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 3, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// Section 13C: a weak-slot event still drives export, but the router refuses
  /// cross-radio fan-out and no secret is invented.
  @Test
  func `Weak slot event exports but is never fanned out`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 4, secret: Fixture.sharedSecret)

    let received = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 4, text: "weak identity",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(received)

    let driver = CloudMessageSyncDriver(store: store)
    let outcome = try #require(try await driver.handle(
      .channelMessageReceived(message: received, channelIndex: 4), across: [radioA, radioB]
    ))

    #expect(outcome.record.conversation == .channelSlot(4))
    #expect(outcome.insertedRadioIDs.isEmpty)
    #expect(outcome.ineligible.first?.reason == .weakSlotIdentityNotPropagated)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 4, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchChannels(radioID: radioA).isEmpty, "no secret invented")
  }
}

// MARK: - Outgoing and read triggers

@Suite("CloudMessageSyncDriver — outgoing and read triggers")
struct CloudMessageSyncDriverLocalActionTests {
  /// Section 12.5: a genuine local outgoing message produces a usable trigger
  /// and reconciles as recognize-only.
  ///
  /// The trigger is constructed from the `MessageDTO` that
  /// `MessageService.createPendingMessage` already returns to its caller — see
  /// the Sprint 1E report for why emission is a separate wiring decision.
  @Test
  func `Local outgoing message trigger reconciles without cloning`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let composed = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "composed locally",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .pending
    )
    try await store.saveMessage(composed)

    let driver = CloudMessageSyncDriver(store: store)
    let outcome = try #require(
      try await driver.handle(.messagePersisted(composed), across: [radioA, radioB])
    )

    // Origin recognized, never cloned.
    #expect(outcome.unchangedRadioIDs == [radioA])
    #expect(outcome.insertedRadioIDs.isEmpty)
    #expect(outcome.ineligible.first?.reason == .outgoingNotFannedOut)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).isEmpty)

    // Section 13D: CloudSync created no PendingSend of its own.
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// Section 13D, precisely stated: a PendingSend created by the *normal* send
  /// path is untouched by CloudSync. The invariant is not "no PendingSend
  /// exists" — it is "CloudSync neither creates, duplicates, nor modifies one".
  @Test
  func `An existing PendingSend from the normal send path is left untouched`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let composed = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "queued for send",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .pending
    )
    try await store.saveMessage(composed)

    // What the real send path does, independently of CloudSync.
    let pending = PendingSendDTO(
      id: UUID(), radioID: radioA, messageID: composed.id, kind: .dm,
      contactID: contactA.id, channelIndex: nil, isResend: false,
      messageText: composed.text, messageTimestamp: composed.timestamp,
      localNodeName: nil, sequence: 0, enqueuedAt: Date(), attemptCount: 0
    )
    _ = try await store.insertPendingSendAssigningSequence(pending)
    let before = try await store.fetchPendingSends(radioID: radioA)
    #expect(before.count == 1)

    _ = try await CloudMessageSyncDriver(store: store)
      .handle(.messagePersisted(composed), across: [radioA, radioB])

    // Exactly the same outbox afterwards: not duplicated, not modified, not removed.
    let after = try await store.fetchPendingSends(radioID: radioA)
    #expect(after == before)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
    // And the message's own send state is untouched.
    #expect(try await store.fetchMessage(id: composed.id)?.status == .pending)
  }

  /// Section 12.6 / 14: a genuine local read action produces a trigger that
  /// propagates read state monotonically to every observation.
  @Test
  func `Local read trigger propagates monotonically to every observation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "read me",
      timestamp: Fixture.wireTimestamp, direction: .incoming, pathLength: 3, snr: -7.25
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "read me",
      timestamp: Fixture.wireTimestamp, direction: .incoming, pathLength: 1, snr: 4.5
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    // The local action MC1 performs today (NotificationActionHandler.handleMarkAsRead).
    try await store.markMessageAsRead(id: onA.id)

    let driver = CloudMessageSyncDriver(store: store)
    let outcome = try #require(
      try await driver.handle(.messageRead(messageID: onA.id), across: [radioA, radioB])
    )

    #expect(outcome.updatedRadioIDs == [radioB], "B upgraded; A was already read")
    #expect(try await store.fetchMessage(id: onA.id)?.isRead == true)
    #expect(try await store.fetchMessage(id: onB.id)?.isRead == true)

    // Radio-local metadata untouched by the read merge.
    #expect(try await store.fetchMessage(id: onA.id)?.snr == -7.25)
    #expect(try await store.fetchMessage(id: onB.id)?.snr == 4.5)

    // Repeating requires no further work.
    let again = try #require(
      try await driver.handle(.messageRead(messageID: onA.id), across: [radioA, radioB])
    )
    #expect(again.updatedRadioIDs.isEmpty)
    #expect(again.unchangedRadioIDs.count == 2)
  }

  /// Read state is monotonic: an unread row never un-reads its peers.
  @Test
  func `A read trigger never un-reads another observation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "still unread on A",
      timestamp: Fixture.wireTimestamp, direction: .incoming, isRead: false
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "still unread on A",
      timestamp: Fixture.wireTimestamp, direction: .incoming, isRead: true
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    // Trigger on the *unread* row: B must stay read.
    _ = try await CloudMessageSyncDriver(store: store)
      .handle(.messageRead(messageID: onA.id), across: [radioA, radioB])

    #expect(try await store.fetchMessage(id: onB.id)?.isRead == true)
    #expect(try await store.fetchMessage(id: onA.id)?.isRead == false)
  }

  /// A trigger naming a deleted row is a benign race, not an error.
  @Test
  func `Read trigger for a deleted row returns no outcome`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveContact(in: store, radioID: radioA)

    let outcome = try await CloudMessageSyncDriver(store: store)
      .handle(.messageRead(messageID: UUID()), across: [radioA, radioB])
    #expect(outcome == nil)
  }
}

// MARK: - Loop prevention

@Suite("CloudMessageSyncDriver — loop prevention")
struct CloudMessageSyncDriverLoopPreventionTests {
  /// Section 12.1–12.4, observed rather than assumed.
  ///
  /// The structural argument is that `CloudMessageImporter` has no reference to
  /// any MC1 event stream, so a cloud-applied change cannot produce a
  /// `SyncDataEvent` and therefore cannot produce a trigger. These tests pin the
  /// observable consequence: after a cloud import, re-running the driver over
  /// the imported rows converges immediately and creates nothing further.
  @Test
  func `Cloud-imported rows do not cascade into further reconciliation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "imported once",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let driver = CloudMessageSyncDriver(store: store)
    // Pass 1: the cloud path creates B's observation.
    _ = try await driver.handle(.messagePersisted(onA), across: [radioA, radioB])
    let importedB = try #require(try await Fixture.dmRows(store, contactID: contactB.id).first)

    // Simulating the loop: feed the cloud-created row straight back in, as a
    // naive persistence-level event would have done. It converges instead of
    // multiplying — which is why duplicate notifications are harmless even if a
    // future integration is imprecise.
    let originalFingerprint = try await CloudMessageExporter(store: store).export(onA).fingerprint
    for _ in 0..<5 {
      let outcome = try #require(
        try await driver.handle(.messagePersisted(importedB), across: [radioA, radioB])
      )
      #expect(outcome.insertedRadioIDs.isEmpty)
      // The imported row is the *same logical message*, so feeding it back
      // resolves to the same identity rather than minting a new one.
      #expect(outcome.fingerprint == originalFingerprint)
    }

    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// Section 12.3: importing outgoing history creates no local outgoing work and
  /// no additional observation, however many times it is replayed.
  @Test
  func `Replaying an outgoing record creates no work and no clone`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let sent = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "authored once",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .delivered
    )
    try await store.saveMessage(sent)

    let driver = CloudMessageSyncDriver(store: store)
    for _ in 0..<5 {
      let outcome = try #require(
        try await driver.handle(.messagePersisted(sent), across: [radioA, radioB])
      )
      #expect(outcome.insertedRadioIDs.isEmpty)
    }

    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).isEmpty)
    #expect(try await store.fetchMessage(id: sent.id)?.status == .delivered)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }

  /// Section 12.4: a CloudSync-applied read upgrade converges — replaying it
  /// produces no further change, so even a duplicated notification is inert.
  @Test
  func `Cloud read upgrade converges and does not cascade`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "read cascade",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "read cascade",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)
    try await store.markMessageAsRead(id: onA.id)

    let driver = CloudMessageSyncDriver(store: store)
    let first = try #require(
      try await driver.handle(.messageRead(messageID: onA.id), across: [radioA, radioB])
    )
    #expect(first.updatedRadioIDs == [radioB])

    // Replaying against the row CloudSync just updated changes nothing further.
    for _ in 0..<5 {
      let outcome = try #require(
        try await driver.handle(.messageRead(messageID: onB.id), across: [radioA, radioB])
      )
      #expect(outcome.updatedRadioIDs.isEmpty)
      #expect(outcome.insertedRadioIDs.isEmpty)
    }
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
  }

  /// The structural guarantee, asserted as a fact about the source: CloudSync
  /// contains no reference to any MC1 event broadcaster, so an import cannot
  /// emit an event that would feed back into the driver.
  ///
  /// This is verified by grep in the Sprint 1E report; the runtime counterpart is
  /// that the importer's store protocol exposes no broadcaster at all, which the
  /// compiler enforces.
  @Test
  func `Importer has no event-emitting capability`() async throws {
    let (store, radioA, _) = try await Fixture.makeTwoRadioStore()
    let contact = try await Fixture.saveContact(in: store, radioID: radioA)

    let record = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Fixture.peerKey, wireTimestamp: Fixture.wireTimestamp, text: "silent"
      ),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .incoming, text: "silent", wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )

    // A direct import writes history and returns; there is no event stream on
    // `CloudSyncMessageImporting` for it to publish to.
    _ = try await CloudMessageImporter(store: store)
      .import(record, into: CloudMessageImportContext(targetRadioID: radioA))

    #expect(try await Fixture.dmRows(store, contactID: contact.id).count == 1)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }
}

// MARK: - Failure and ordering

@Suite("CloudMessageSyncDriver — failure and ordering")
struct CloudMessageSyncDriverFailureTests {
  /// Export failure surfaces as a thrown error before any write, and leaves the
  /// database untouched. A CloudSync failure cannot affect the send path,
  /// because the send path never awaits this driver.
  @Test
  func `Export failure throws and writes nothing`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()

    // A message whose contact row does not exist: unexportable.
    let danglingContactID = UUID()
    let orphan = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: danglingContactID, text: "orphan",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )

    await #expect(throws: CloudMessageExportError.contactNotFound(contactID: danglingContactID)) {
      try await CloudMessageSyncDriver(store: store)
        .handle(.messagePersisted(orphan), across: [radioA, radioB])
    }
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }

  /// Two radios producing equivalent triggers "concurrently" converge on one
  /// logical message with no third row — order-independent by construction.
  @Test
  func `Equivalent triggers from two radios converge in either order`() async throws {
    for reversed in [false, true] {
      let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
      let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
      let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

      let onA = MessageDTO.testDirectMessage(
        radioID: radioA, contactID: contactA.id, text: "order free",
        timestamp: Fixture.wireTimestamp, direction: .incoming
      )
      let onB = MessageDTO.testDirectMessage(
        radioID: radioB, contactID: contactB.id, text: "order free",
        timestamp: Fixture.wireTimestamp, direction: .incoming
      )
      try await store.saveMessage(onA)
      try await store.saveMessage(onB)

      let driver = CloudMessageSyncDriver(store: store)
      let triggers = reversed
        ? [CloudMessageSyncTrigger.messagePersisted(onB), .messagePersisted(onA)]
        : [CloudMessageSyncTrigger.messagePersisted(onA), .messagePersisted(onB)]
      for trigger in triggers {
        _ = try await driver.handle(trigger, across: [radioA, radioB])
      }

      #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
      #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
    }
  }
}
