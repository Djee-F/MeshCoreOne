import Foundation
@testable import MC1Services
import Testing

// MARK: - Fixtures

private enum Fixture {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 71 })
  static let sharedSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 83 })
  static let wireTimestamp: UInt32 = 1_704_067_200

  static func makeTwoRadioStore() async throws -> (store: PersistenceStore, radioA: UUID, radioB: UUID) {
    let radioA = UUID()
    let radioB = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioA)
    try await store.saveDevice(
      DeviceDTO.testDevice(
        id: radioB, radioID: radioB,
        publicKey: Data(repeating: 0x05, count: ProtocolLimits.publicKeySize)
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

/// Records how often the participating-radio policy was consulted, so tests can
/// prove the session asks rather than assuming.
private actor CountingRadioProvider: CloudSyncRadioProviding {
  private let radioIDs: [UUID]
  private(set) var callCount = 0

  init(_ radioIDs: [UUID]) { self.radioIDs = radioIDs }

  func participatingRadioIDs() async -> [UUID] {
    callCount += 1
    return radioIDs
  }

  func consultations() -> Int { callCount }
}

// MARK: - Subscription lifetime

@Suite("CloudMessageSyncSession — subscription lifetime")
struct CloudMessageSyncSessionLifetimeTests {
  /// §15.1 + §15.2: the subscription starts once, and re-wiring on reconnect
  /// does not create a second subscriber.
  @Test
  func `Start is idempotent so reconnect cannot duplicate the subscription`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )

    let (streamA, continuationA) = AsyncStream<SyncDataEvent>.makeStream()
    let (streamB, _) = AsyncStream<SyncDataEvent>.makeStream()

    await session.start(consuming: streamA)
    #expect(await session.isConsumingEvents)
    // A second start while live is ignored — the reconnect case.
    await session.start(consuming: streamB)

    let received = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "once only",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(received)

    continuationA.yield(.directMessageReceived(message: received, contact: contactA))
    continuationA.finish()

    // Drain.
    var attempts = 0
    while await session.processedTriggerCount == 0, attempts < 200 {
      try await Task.sleep(for: .milliseconds(5))
      attempts += 1
    }

    #expect(await session.processedTriggerCount == 1, "one subscriber, one delivery")
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)

    await session.stop()
  }

  /// §15.3: cancellation stops processing.
  @Test
  func `Stopping the session halts event processing`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    let (stream, continuation) = AsyncStream<SyncDataEvent>.makeStream()
    await session.start(consuming: stream)
    await session.stop()
    #expect(await session.isConsumingEvents == false)

    let received = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "after stop",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(received)
    continuation.yield(.directMessageReceived(message: received, contact: contactA))
    continuation.finish()

    try await Task.sleep(for: .milliseconds(50))
    #expect(await session.processedTriggerCount == 0)
  }

  /// §15.6 + §15.7: the policy is consulted per trigger, and nothing invents a
  /// "connected radios only" default.
  @Test
  func `The radio provider is consulted for every trigger`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let provider = CountingRadioProvider([radioA, radioB])
    let session = CloudMessageSyncSession(store: store, radioProvider: provider)

    let message = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "consulted",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(message)

    await session.recordLocalMessage(message)
    await session.recordLocalMessage(message)
    #expect(await provider.consultations() == 2)
  }

  /// An empty policy means "no synchronization domain configured" — inert and
  /// counted as skipped, never an error and never an invented default.
  @Test
  func `An empty radio set performs no work and is not an error`() async throws {
    let (store, radioA, _) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [])
    )
    let message = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "nowhere to go",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(message)

    await session.recordLocalMessage(message)
    #expect(await session.skippedTriggerCount == 1)
    #expect(await session.failureCount == 0)
    #expect(await session.processedTriggerCount == 0)
  }
}

// MARK: - Failure isolation

@Suite("CloudMessageSyncSession — failure isolation")
struct CloudMessageSyncSessionFailureTests {
  /// §15.5 + §16.7 + §9: a failing trigger is counted, never thrown, and never
  /// stops the loop. Because every entry point is non-throwing, a CloudSync
  /// failure cannot surface to a caller as a send failure.
  @Test
  func `A failing trigger is isolated and the session keeps working`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )

    // Unexportable: its contact row does not exist.
    let broken = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: UUID(), text: "orphan",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    await session.recordLocalMessage(broken)
    #expect(await session.failureCount == 1)
    #expect(await session.processedTriggerCount == 0)

    // A good trigger immediately afterwards still works.
    let good = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "still fine",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(good)
    await session.recordLocalMessage(good)

    #expect(await session.processedTriggerCount == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
  }

  /// A failure inside event handling does not terminate the subscription.
  @Test
  func `A failing event does not end the consumption loop`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    let (stream, continuation) = AsyncStream<SyncDataEvent>.makeStream()
    await session.start(consuming: stream)

    let orphanContact = ContactDTO.testContact(radioID: radioA, publicKey: Fixture.peerKey)
    let broken = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: UUID(), text: "boom",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    let good = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "recovered",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(good)

    continuation.yield(.directMessageReceived(message: broken, contact: orphanContact))
    continuation.yield(.directMessageReceived(message: good, contact: contactA))
    continuation.finish()

    var attempts = 0
    while await session.processedTriggerCount == 0, attempts < 200 {
      try await Task.sleep(for: .milliseconds(5))
      attempts += 1
    }

    #expect(await session.failureCount == 1)
    #expect(await session.processedTriggerCount == 1, "loop survived the failure")
    await session.stop()
  }
}

// MARK: - Incoming multi-radio, through the wired path

@Suite("CloudMessageSyncSession — incoming multi-radio")
struct CloudMessageSyncSessionIncomingTests {
  /// §18A: the same DM independently received on two radios, driven through the
  /// actual event intake.
  @Test
  func `Same DM on two radios yields two observations and one fingerprint`() async throws {
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

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    await session.handle(.directMessageReceived(message: onA, contact: contactA))
    await session.handle(.directMessageReceived(message: onB, contact: contactB))

    // Two observations, unmoved, each keeping its own reception metadata.
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
    #expect(try await store.fetchMessage(id: onA.id)?.snr == -7.25)
    #expect(try await store.fetchMessage(id: onB.id)?.snr == 4.5)
    #expect(try await store.fetchMessage(id: onA.id)?.radioID == radioA)
    #expect(try await store.fetchMessage(id: onB.id)?.radioID == radioB)

    // One logical identity.
    let exporter = CloudMessageExporter(store: store)
    let fpA = try await exporter.export(try #require(try await store.fetchMessage(id: onA.id))).fingerprint
    let fpB = try await exporter.export(try #require(try await store.fetchMessage(id: onB.id))).fingerprint
    #expect(fpA == fpB)

    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// §18B: strong channel, same secret at different local slots.
  @Test
  func `Strong channel event fans to the local slot and stays there`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 7, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "net at 1900",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    await session.handle(.channelMessageReceived(message: onA, channelIndex: 3))

    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 7, limit: 10, offset: 0).count == 1)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 3, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchMessages(radioID: radioA, channelIndex: 3, limit: 10, offset: 0).count == 1)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// §18C: weak slot reaches the trigger layer but is refused cross-radio, and
  /// no secret is invented.
  @Test
  func `Weak slot event is processed but never fanned out`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 4, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 4, text: "weak",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    await session.handle(.channelMessageReceived(message: onA, channelIndex: 4))

    #expect(await session.processedTriggerCount == 1, "the event was handled")
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 4, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchChannels(radioID: radioA).isEmpty, "no secret invented")
  }

  /// §15.4: duplicate events are idempotent.
  @Test
  func `Duplicate events remain idempotent`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "many times",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    for _ in 0..<10 {
      await session.handle(.directMessageReceived(message: onA, contact: contactA))
    }

    #expect(await session.processedTriggerCount == 10)
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
  }
}

// MARK: - Local actions

@Suite("CloudMessageSyncSession — local actions")
struct CloudMessageSyncSessionLocalActionTests {
  /// §16.1 + §16.11: a genuine outgoing message triggers reconciliation and is
  /// never cloned onto another radio.
  @Test
  func `Outgoing message trigger reconciles without cloning`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let composed = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "composed",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .pending
    )
    try await store.saveMessage(composed)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    await session.recordLocalMessage(composed)

    #expect(await session.processedTriggerCount == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).isEmpty, "never cloned")
    // §16.10: origin send state untouched.
    #expect(try await store.fetchMessage(id: composed.id)?.status == .pending)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }

  /// §16.3 + §16.4: a retry/resend of the same row is the same logical message.
  /// Re-triggering after a resend creates no second history entry.
  @Test
  func `Re-triggering after a resend keeps one identity and one row`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let composed = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "resent",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .pending
    )
    try await store.saveMessage(composed)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    let exporter = CloudMessageExporter(store: store)
    let before = try await exporter.export(composed).fingerprint
    await session.recordLocalMessage(composed)

    // What a resend does to the row: new wire timestamp, bumped send count.
    let afterResend = composed.copy {
      $0.timestamp = Fixture.wireTimestamp + 42
      $0.sendCount = 2
      $0.status = .sent
    }
    await session.recordLocalMessage(afterResend)

    #expect(try await exporter.export(afterResend).fingerprint == before, "identity unchanged")
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
  }

  /// §17.1 + §17.5 + §17.6: a local read propagates monotonically without
  /// disturbing radio-local metadata.
  @Test
  func `Local read trigger propagates monotonically`() async throws {
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

    // The local action MC1 performs (NotificationActionHandler.handleMarkAsRead).
    try await store.markMessageAsRead(id: onA.id)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )
    await session.recordLocalRead(messageID: onA.id)

    #expect(try await store.fetchMessage(id: onA.id)?.isRead == true)
    #expect(try await store.fetchMessage(id: onB.id)?.isRead == true)
    #expect(try await store.fetchMessage(id: onA.id)?.snr == -7.25)
    #expect(try await store.fetchMessage(id: onB.id)?.snr == 4.5)

    // §17.4: repeating is harmless.
    await session.recordLocalRead(messageID: onA.id)
    #expect(await session.failureCount == 0)
  }

  /// §17.7: a driver failure must not revert the local read.
  @Test
  func `A failing read trigger leaves the local read intact`() async throws {
    let (store, radioA, _) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)

    // Row whose contact is then removed, so export fails on the read trigger.
    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "read then break",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)
    try await store.markMessageAsRead(id: onA.id)
    try await store.deleteContact(id: contactA.id)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA])
    )
    await session.recordLocalRead(messageID: onA.id)

    // Either the row cascaded away with its contact, or it survived still read —
    // in neither case did CloudSync revert anything.
    if let row = try await store.fetchMessage(id: onA.id) {
      #expect(row.isRead == true)
    }
    #expect(await session.processedTriggerCount == 0)
  }

  /// §17.8 + §3C: clearing a Contact's unread counter is *not* per-message read
  /// state, and must not be mistaken for one. MC1 writes `Message.isRead` in
  /// exactly one place (`PersistenceStore+Messages.swift:436`); `clearUnreadCount`
  /// touches only the Contact row.
  @Test
  func `Clearing the unread count does not change per-message read state`() async throws {
    let (store, radioA, _) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "still unread",
      timestamp: Fixture.wireTimestamp, direction: .incoming, isRead: false
    )
    try await store.saveMessage(onA)
    try await store.incrementUnreadCount(contactID: contactA.id)

    try await store.clearUnreadCount(contactID: contactA.id)

    #expect(try await store.fetchContact(id: contactA.id)?.unreadCount == 0)
    #expect(try await store.fetchMessage(id: onA.id)?.isRead == false,
            "unread-count clearing is a different state from Message.isRead")
  }
}

// MARK: - Loop prevention through the wired path

@Suite("CloudMessageSyncSession — loop prevention")
struct CloudMessageSyncSessionLoopPreventionTests {
  /// §19: a cloud import produces **zero** local-origin triggers, counted at the
  /// trigger boundary itself rather than inferred from row counts.
  @Test
  func `Cloud import produces zero local-origin triggers`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )

    let record = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Fixture.peerKey, wireTimestamp: Fixture.wireTimestamp, text: "from cloud"
      ),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .incoming, text: "from cloud", wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: true, originMessageID: nil
    )

    // The importer writes history directly — saveMessage and markMessageAsRead.
    let importer = CloudMessageImporter(store: store)
    _ = try await importer.import(record, into: CloudMessageImportContext(targetRadioID: radioA))
    _ = try await importer.import(record, into: CloudMessageImportContext(targetRadioID: radioB))

    // Rows were written…
    #expect(try await Fixture.dmRows(store, contactID: contactA.id).count == 1)
    #expect(try await Fixture.dmRows(store, contactID: contactB.id).count == 1)
    // …and the trigger boundary saw nothing at all.
    #expect(await session.processedTriggerCount == 0)
    #expect(await session.failureCount == 0)
    #expect(await session.skippedTriggerCount == 0)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// A cloud-applied read upgrade likewise reaches no trigger.
  @Test
  func `Cloud-applied read produces zero local-origin triggers`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "cloud read",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "cloud read",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncStaticRadioProvider(radioIDs: [radioA, radioB])
    )

    let readRecord = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Fixture.peerKey, wireTimestamp: Fixture.wireTimestamp, text: "cloud read"
      ),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .incoming, text: "cloud read", wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: true, originMessageID: nil
    )
    _ = try await CloudMessageImporter(store: store)
      .import(readRecord, into: CloudMessageImportContext(targetRadioID: radioB))

    #expect(try await store.fetchMessage(id: onB.id)?.isRead == true)
    #expect(await session.processedTriggerCount == 0)
    #expect(await session.failureCount == 0)
  }
}
