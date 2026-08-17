import Foundation
@testable import MC1Services
import Testing

// MARK: - Fixtures

private enum Fixture {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 31 })
  static let otherPeerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 130 })
  static let sharedSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 41 })
  static let otherSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 170 })
  static let wireTimestamp: UInt32 = 1_704_067_200

  /// One local database hosting two radios.
  static func makeTwoRadioStore() async throws -> (store: PersistenceStore, radioA: UUID, radioB: UUID) {
    let radioA = UUID()
    let radioB = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioA)
    try await store.saveDevice(
      DeviceDTO.testDevice(
        id: radioB, radioID: radioB,
        publicKey: Data(repeating: 0x03, count: ProtocolLimits.publicKeySize)
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

  static func coordinator(_ store: PersistenceStore) -> CloudMessageSyncCoordinator {
    CloudMessageSyncCoordinator(store: store)
  }

  static func state(
    _ plan: CloudMessageRoutingPlan,
    _ radioID: UUID
  ) -> CloudRadioRoutingState? {
    plan.decisions.first { $0.radioID == radioID }?.state
  }

  /// Every message row in the store for a DM conversation on one radio.
  static func dmRows(
    _ store: PersistenceStore,
    contactID: UUID
  ) async throws -> [MessageDTO] {
    try await store.fetchMessages(contactID: contactID, limit: 100, offset: 0)
  }
}

// MARK: - Direct messages

@Suite("CloudMessageSyncCoordinator — direct messages")
struct CloudMessageSyncCoordinatorDirectTests {
  /// Scenarios 1, 4, 7, 8, 30: a local incoming DM exports and fans out to the
  /// other eligible radio, which keeps its own local identifiers.
  @Test
  func `Local incoming DM exports and creates the missing observation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)
    #expect(contactA.id != contactB.id)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "fan me out",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let outcome = try await Fixture.coordinator(store)
      .synchronizeLocalMessage(onA, across: [radioA, radioB])

    #expect(outcome.unchangedRadioIDs == [radioA], "source row untouched")
    #expect(outcome.insertedRadioIDs == [radioB])
    #expect(outcome.failures.isEmpty)
    #expect(outcome.succeededEverywhere)

    let rowsB = try await Fixture.dmRows(store, contactID: contactB.id)
    #expect(rowsB.count == 1)
    let rowB = try #require(rowsB.first)

    // Scenario 30 / 29: independent local identity on each radio.
    #expect(rowB.radioID == radioB)
    #expect(rowB.contactID == contactB.id)
    #expect(rowB.id != onA.id)

    // Scenarios 7 + 8: differing radioID and Contact.id leave the logical
    // fingerprint identical.
    let reExported = try await CloudMessageExporter(store: store).export(rowB)
    #expect(reExported.fingerprint == outcome.fingerprint)
    #expect(reExported.conversation == outcome.record.conversation)
  }

  /// Scenario 2: the same flow driven by a record "received from a transport".
  @Test
  func `Remote incoming DM record reconciles into the local store`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    // A record built entirely from portable data — no local row behind it.
    let record = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Fixture.peerKey, wireTimestamp: Fixture.wireTimestamp, text: "from afar"
      ),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .incoming, text: "from afar", wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )

    let outcome = try await Fixture.coordinator(store).synchronize(record, across: [radioA, radioB])

    #expect(outcome.insertedRadioIDs.sorted(by: { $0.uuidString < $1.uuidString })
      == [radioA, radioB].sorted(by: { $0.uuidString < $1.uuidString }))
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// Scenarios 3, 9, 10, 28: both radios independently received the message
  /// before any synchronization. Recognize both; insert nothing; touch nothing.
  @Test
  func `Independently received message on both radios is recognized twice`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    // Deliberately different reception metadata per radio.
    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "both heard it",
      timestamp: Fixture.wireTimestamp, direction: .incoming,
      pathLength: 3, snr: -7.25, heardRepeats: 2
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "both heard it",
      timestamp: Fixture.wireTimestamp, direction: .incoming,
      pathLength: 1, snr: 4.5, heardRepeats: 0
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let outcome = try await Fixture.coordinator(store)
      .synchronizeLocalMessage(onA, across: [radioA, radioB])

    // Two observations of one logical message — normal, not an error.
    #expect(outcome.plan.existingObservations.count == 2)
    #expect(outcome.insertedRadioIDs.isEmpty, "no third row")
    #expect(outcome.unchangedRadioIDs.count == 2)

    // Scenario 9 + 19: reception metadata stayed local and un-crossed.
    let afterA = try #require(try await store.fetchMessage(id: onA.id))
    let afterB = try #require(try await store.fetchMessage(id: onB.id))
    #expect(afterA.pathLength == 3)
    #expect(afterA.snr == -7.25)
    #expect(afterA.heardRepeats == 2)
    #expect(afterB.pathLength == 1)
    #expect(afterB.snr == 4.5)
    #expect(afterB.heardRepeats == 0)

    // Scenario 28 + neither row moved between radios.
    #expect(afterA.radioID == radioA)
    #expect(afterB.radioID == radioB)
    #expect(afterA.contactID == contactA.id)
    #expect(afterB.contactID == contactB.id)
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
  }

  /// A radio without the peer key is refused, and the reason is reported.
  @Test
  func `Radio lacking the peer key is reported ineligible`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB, publicKey: Fixture.otherPeerKey)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "stranger",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let outcome = try await Fixture.coordinator(store)
      .synchronizeLocalMessage(onA, across: [radioA, radioB])

    #expect(outcome.insertedRadioIDs.isEmpty)
    #expect(outcome.ineligible.count == 1)
    #expect(outcome.ineligible.first?.radioID == radioB)
    #expect(outcome.ineligible.first?.reason == .noContactWithPeerKey)
  }
}

// MARK: - Idempotency

@Suite("CloudMessageSyncCoordinator — idempotency")
struct CloudMessageSyncCoordinatorIdempotencyTests {
  /// Scenarios 5, 6, 26: once, twice, ten times — the store converges and stops.
  @Test
  func `Repeated reconciliation converges and stays stable`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "idempotent",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let coordinator = Fixture.coordinator(store)
    let record = try await coordinator.exportRecord(for: onA)

    // First pass creates the missing observation.
    let first = try await coordinator.synchronize(record, across: [radioA, radioB])
    #expect(first.insertedRadioIDs == [radioB])
    let importedID = try #require(
      try await Fixture.dmRows(store, contactID: contactB.id).first?.id
    )

    // Second pass changes nothing.
    let second = try await coordinator.synchronize(record, across: [radioA, radioB])
    #expect(second.insertedRadioIDs.isEmpty)
    #expect(second.unchangedRadioIDs.count == 2)

    // Ten more passes still change nothing.
    for _ in 0..<10 {
      let outcome = try await coordinator.synchronize(record, across: [radioA, radioB])
      #expect(outcome.insertedRadioIDs.isEmpty)
      #expect(outcome.failures.isEmpty)
      #expect(outcome.fingerprint == record.fingerprint)
    }

    // Row counts stable, ids stable, nothing moved, no send work.
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
    #expect(try await store.fetchMessage(id: onA.id)?.radioID == radioA)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).first?.id == importedID)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)

    // Fingerprints of both observations remain identical to the record's.
    for row in try await Fixture.dmRows(store, contactID: contactA.id)
      + Fixture.dmRows(store, contactID: contactB.id) {
      #expect(try await CloudMessageExporter(store: store).export(row).fingerprint == record.fingerprint)
    }
  }
}

// MARK: - Channels

@Suite("CloudMessageSyncCoordinator — channels")
struct CloudMessageSyncCoordinatorChannelTests {
  /// Scenario 10: strong channel fans from slot 3 to the matching-secret slot 7.
  @Test
  func `Strong channel fans out to the matching secret at a different slot`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 7, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "net at 1900",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let outcome = try await Fixture.coordinator(store)
      .synchronizeLocalMessage(onA, across: [radioA, radioB])

    #expect(outcome.insertedRadioIDs == [radioB])

    let rowsAtSeven = try await store.fetchMessages(radioID: radioB, channelIndex: 7, limit: 10, offset: 0)
    #expect(rowsAtSeven.count == 1)
    let rowB = try #require(rowsAtSeven.first)
    #expect(rowB.channelIndex == 7)
    #expect(rowB.radioID == radioB)

    // No slot number crossed from A to B.
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 3, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchMessages(radioID: radioA, channelIndex: 3, limit: 10, offset: 0).count == 1)

    let reExported = try await CloudMessageExporter(store: store).export(rowB)
    #expect(reExported.fingerprint == outcome.fingerprint)
  }

  /// Scenario 11: both radios already had it — no third observation.
  @Test
  func `Strong channel already seen on both radios creates no third row`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 7, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "both heard it",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    let onB = MessageDTO.testChannelMessage(
      radioID: radioB, channelIndex: 7, text: "both heard it",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let outcome = try await Fixture.coordinator(store)
      .synchronizeLocalMessage(onA, across: [radioA, radioB])

    #expect(outcome.plan.existingObservations.count == 2)
    #expect(outcome.insertedRadioIDs.isEmpty)
    #expect(try await store.fetchMessages(radioID: radioA, channelIndex: 3, limit: 10, offset: 0).count == 1)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 7, limit: 10, offset: 0).count == 1)
  }

  /// Scenario 12: same slot number, different secret — no fan-out.
  @Test
  func `Same slot with a different secret does not fan out`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 3, secret: Fixture.otherSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "not yours",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let outcome = try await Fixture.coordinator(store)
      .synchronizeLocalMessage(onA, across: [radioA, radioB])

    #expect(outcome.insertedRadioIDs.isEmpty)
    #expect(outcome.ineligible.first?.reason == .noChannelWithSecret)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 3, limit: 10, offset: 0).isEmpty)
  }

  /// Scenarios 13 + 14: weak slot identity is recognized but never propagated,
  /// and no secret is invented.
  @Test
  func `Weak channel is recognized but never fanned out`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    // Radio B even has a real channel at the same slot — still refused.
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 4, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 4, text: "weak identity",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let coordinator = Fixture.coordinator(store)
    let outcome = try await coordinator.synchronizeLocalMessage(onA, across: [radioA, radioB])

    #expect(outcome.record.conversation == .channelSlot(4))
    #expect(!outcome.record.conversation.isStrong)
    // Scenario 14: A's own observation is recognized.
    #expect(Fixture.state(outcome.plan, radioA)?.existingMessageID == onA.id)
    // Scenario 13: B refused.
    #expect(outcome.insertedRadioIDs.isEmpty)
    #expect(outcome.ineligible.first?.reason == .weakSlotIdentityNotPropagated)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 4, limit: 10, offset: 0).isEmpty)

    // No secret invented, and nothing changed on repeat.
    #expect(try await coordinator.synchronizeLocalMessage(onA, across: [radioA, radioB])
      .insertedRadioIDs.isEmpty)
    #expect(try await store.fetchChannels(radioID: radioA).isEmpty)
  }
}

// MARK: - Outgoing

@Suite("CloudMessageSyncCoordinator — outgoing history")
struct CloudMessageSyncCoordinatorOutgoingTests {
  /// Scenarios 15, 16, 20: outgoing is recognize-only and never cloned, and no
  /// send/runtime state crosses.
  @Test
  func `Outgoing history is recognized on its origin radio and never cloned`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let sent = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "authored on A",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .delivered,
      ackCode: 0xDEADBEEF, roundTripTime: 1234, sendCount: 2, retryAttempt: 1, maxRetryAttempts: 3
    )
    try await store.saveMessage(sent)

    let outcome = try await Fixture.coordinator(store)
      .synchronizeLocalMessage(sent, across: [radioA, radioB])

    #expect(outcome.insertedRadioIDs.isEmpty, "outgoing must never be cloned")
    #expect(outcome.unchangedRadioIDs == [radioA])
    #expect(outcome.ineligible.first?.radioID == radioB)
    #expect(outcome.ineligible.first?.reason == .outgoingNotFannedOut)

    // Nothing on B; A untouched, including its send/runtime state.
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).isEmpty)
    let afterA = try #require(try await store.fetchMessage(id: sent.id))
    #expect(afterA.status == .delivered)
    #expect(afterA.ackCode == 0xDEADBEEF)
    #expect(afterA.roundTripTime == 1234)
    #expect(afterA.sendCount == 2)
    #expect(afterA.retryAttempt == 1)
    #expect(afterA.radioID == radioA)

    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// An outgoing channel message behaves identically.
  @Test
  func `Outgoing channel history is recognize-only`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 1, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 6, secret: Fixture.sharedSecret)

    let sent = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 1, text: "net control",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, senderNodeName: "Me"
    )
    try await store.saveMessage(sent)

    let outcome = try await Fixture.coordinator(store)
      .synchronizeLocalMessage(sent, across: [radioA, radioB])

    #expect(outcome.insertedRadioIDs.isEmpty)
    #expect(outcome.ineligible.first?.reason == .outgoingNotFannedOut)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 6, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }
}

// MARK: - Read state

@Suite("CloudMessageSyncCoordinator — read state")
struct CloudMessageSyncCoordinatorReadStateTests {
  /// Scenario 17: a read upgrade reaches every existing observation.
  @Test
  func `isRead true propagates monotonically to every observation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "read everywhere",
      timestamp: Fixture.wireTimestamp, direction: .incoming, pathLength: 3, snr: -7.25
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "read everywhere",
      timestamp: Fixture.wireTimestamp, direction: .incoming, pathLength: 1, snr: 4.5
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let coordinator = Fixture.coordinator(store)
    let base = try await coordinator.exportRecord(for: onA)
    let readRecord = CloudMessageRecord(
      fingerprint: base.fingerprint, conversation: base.conversation, direction: base.direction,
      text: base.text, wireTimestamp: base.wireTimestamp, senderNodeName: base.senderNodeName,
      isRead: true, originMessageID: nil
    )

    let outcome = try await coordinator.synchronize(readRecord, across: [radioA, radioB])
    #expect(outcome.updatedRadioIDs.count == 2)

    #expect(try await store.fetchMessage(id: onA.id)?.isRead == true)
    #expect(try await store.fetchMessage(id: onB.id)?.isRead == true)

    // Scenario 19: reception metadata untouched by the read merge.
    #expect(try await store.fetchMessage(id: onA.id)?.snr == -7.25)
    #expect(try await store.fetchMessage(id: onB.id)?.snr == 4.5)

    // Repeating is a no-op.
    #expect(try await coordinator.synchronize(readRecord, across: [radioA, radioB])
      .unchangedRadioIDs.count == 2)
  }

  /// Scenario 18: unread never propagates.
  @Test
  func `isRead false never un-reads an observation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "already read",
      timestamp: Fixture.wireTimestamp, direction: .incoming, isRead: true
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "already read",
      timestamp: Fixture.wireTimestamp, direction: .incoming, isRead: true
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let coordinator = Fixture.coordinator(store)
    let unread = try await coordinator.exportRecord(for: onA.copy { $0.isRead = false })
    #expect(!unread.isRead)

    let outcome = try await coordinator.synchronize(unread, across: [radioA, radioB])
    #expect(outcome.unchangedRadioIDs.count == 2)
    #expect(try await store.fetchMessage(id: onA.id)?.isRead == true)
    #expect(try await store.fetchMessage(id: onB.id)?.isRead == true)
  }
}

// MARK: - Safety

@Suite("CloudMessageSyncCoordinator — safety")
struct CloudMessageSyncCoordinatorSafetyTests {
  /// Scenarios 21 + 22: no record shape, orchestrated across radios, creates
  /// send work. `ChatSendQueueService.hydrate()` draws work solely from
  /// `PendingSend`, so an empty outbox proves no transmission can follow.
  @Test
  func `No record shape creates send work`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 1, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 6, secret: Fixture.sharedSecret)

    var sources: [MessageDTO] = []
    for direction in [MessageDirection.incoming, .outgoing] {
      sources.append(MessageDTO.testDirectMessage(
        radioID: radioA, contactID: contactA.id, text: "dm \(direction)",
        timestamp: Fixture.wireTimestamp, direction: direction
      ))
      sources.append(MessageDTO.testChannelMessage(
        radioID: radioA, channelIndex: 1, text: "ch \(direction)",
        timestamp: Fixture.wireTimestamp, direction: direction, senderNodeName: "Alice"
      ))
    }
    for message in sources { try await store.saveMessage(message) }

    let coordinator = Fixture.coordinator(store)
    for message in sources {
      _ = try await coordinator.synchronizeLocalMessage(message, across: [radioA, radioB])
    }

    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
    for message in sources {
      #expect(try await store.hasPendingSend(messageID: message.id) == false)
    }
  }

  /// Scenario 25: planning is read-only, even repeated.
  @Test
  func `Planning performs no database mutation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "untouched",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let coordinator = Fixture.coordinator(store)
    let before = try await Fixture.dmRows(store, contactID: contactA.id)

    for _ in 0..<3 {
      let (record, plan) = try await coordinator.plan(forLocalMessage: onA, across: [radioA, radioB])
      #expect(plan.fingerprint == record.fingerprint)
      #expect(plan.importableRadioIDs == [radioB])
      _ = try await coordinator.plan(for: record, across: [radioA, radioB])
    }

    #expect(try await Fixture.dmRows(store, contactID: contactA.id) == before)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }

  /// Scenarios 23 + 24: malformed records are rejected during planning, so the
  /// rejection happens before any radio is written to.
  @Test
  func `Malformed records are rejected before any write`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)
    let coordinator = Fixture.coordinator(store)

    let honest = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Fixture.peerKey, wireTimestamp: Fixture.wireTimestamp, text: "hi"
      ),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .incoming, text: "hi", wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )

    // Unsupported format version.
    let future = CloudMessageRecord(
      formatVersion: 99, fingerprint: honest.fingerprint, conversation: honest.conversation,
      direction: .incoming, text: honest.text, wireTimestamp: honest.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )
    await #expect(throws: CloudMessageImportError.unsupportedFormatVersion(99)) {
      try await coordinator.synchronize(future, across: [radioA, radioB])
    }

    // Scenario 24: fingerprint disagreeing with the record's own fields.
    let tampered = CloudMessageRecord(
      fingerprint: honest.fingerprint, conversation: honest.conversation,
      direction: .incoming, text: "different text", wireTimestamp: honest.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )
    await #expect(throws: CloudMessageImportError.fingerprintMismatch) {
      try await coordinator.synchronize(tampered, across: [radioA, radioB])
    }

    // Nothing was written by either rejection.
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }
}

// MARK: - Known limitations

@Suite("CloudMessageSyncCoordinator — known limitations")
struct CloudMessageSyncCoordinatorLimitationTests {
  /// Scenario 27: the Sprint 1B/1C clock-correction gap, still present at the
  /// orchestration level and deliberately not papered over here.
  ///
  /// Observation lookup narrows on `Message.timestamp` while portable identity
  /// uses `senderTimestamp ?? timestamp`, so a clock-corrected local row escapes
  /// the candidate window and orchestration inserts a second observation on the
  /// same radio. Both rows still export to one fingerprint, so logical identity
  /// is unharmed; only the local lookup misses. A stored fingerprint column
  /// closes this properly — out of scope for this sprint.
  @Test
  func `Clock-corrected row is missed — known gap, unchanged by orchestration`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let corrected = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "skewed clock",
      timestamp: Fixture.wireTimestamp + 999_999, direction: .incoming
    ).copy {
      $0.timestampCorrected = true
      $0.senderTimestamp = Fixture.wireTimestamp
    }
    try await store.saveMessage(corrected)

    let coordinator = Fixture.coordinator(store)
    let record = try await coordinator.exportRecord(for: corrected)
    #expect(record.wireTimestamp == Fixture.wireTimestamp)

    let outcome = try await coordinator.synchronize(record, across: [radioA])

    // The gap: radio A holds the message but is not recognized as holding it.
    #expect(
      outcome.insertedRadioIDs == [radioA],
      "known gap: corrected rows escape the wire-timestamp candidate window"
    )
    let rows = try await Fixture.dmRows(store, contactID: contactA.id)
    #expect(rows.count == 2, "documented duplicate on one radio")

    // Logical identity is nonetheless intact: both rows share one fingerprint.
    var fingerprints: Set<String> = []
    for row in rows {
      fingerprints.insert(try await coordinator.exportRecord(for: row).fingerprint)
    }
    #expect(fingerprints == [record.fingerprint])
  }

  /// Sprint 1B's deliberate decision, re-pinned here because orchestration could
  /// otherwise make it look like CloudSync owns radio dedup.
  ///
  /// Imported rows carry no MeshCore `deduplicationKey`, so a later live-radio
  /// delivery of the same message creates its own observation rather than being
  /// suppressed. Losing real radio traffic would be far worse than a visible
  /// duplicate.
  @Test
  func `Imported rows carry no live-radio deduplication key`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "cloud first",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    ).copy { $0.deduplicationKey = "dm-live-radio-key" }
    try await store.saveMessage(onA)

    _ = try await Fixture.coordinator(store).synchronizeLocalMessage(onA, across: [radioA, radioB])

    let importedB = try #require(try await Fixture.dmRows(store, contactID: contactB.id).first)
    #expect(importedB.deduplicationKey == nil, "cloud import must not enter the radio dedup namespace")
    // The source row keeps its own live-radio key.
    #expect(try await store.fetchMessage(id: onA.id)?.deduplicationKey == "dm-live-radio-key")
  }
}
