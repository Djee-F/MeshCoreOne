import Foundation
@testable import MC1Services
import Testing

private enum Fx {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 91 })
  static let secret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 67 })
  static let ts: UInt32 = 1_704_067_200

  static func tempRoot() throws -> URL {
    let u = FileManager.default.temporaryDirectory
      .appendingPathComponent("mc1-2c-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }

  static func twoRadios() async throws -> (PersistenceStore, UUID, UUID) {
    let a = UUID(), b = UUID()
    let s = try await PersistenceStore.createTestDataStore(radioID: a)
    try await s.saveDevice(DeviceDTO.testDevice(
      id: b, radioID: b, publicKey: Data(repeating: 0x07, count: ProtocolLimits.publicKeySize)))
    return (s, a, b)
  }

  static func transport(
    folder: URL?, store: PersistenceStore
  ) -> CloudMessageFolderTransport {
    CloudMessageFolderTransport(
      folderProvider: CloudSyncStaticFolderProvider(url: folder),
      coordinator: CloudMessageSyncCoordinator(store: store),
      radioProvider: CloudSyncPersistedRadioProvider(store: store)
    )
  }

  static func incomingDM(text: String = "hello", isRead: Bool = false) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: peerKey, wireTimestamp: ts, text: text),
      conversation: .direct(peerPublicKey: peerKey),
      direction: .incoming, text: text, wireTimestamp: ts,
      senderNodeName: nil, isRead: isRead, originMessageID: nil)
  }

  static func strongChannel(text: String = "net") -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: secret, channelIndex: 0, senderNodeName: "Alice",
        wireTimestamp: ts, text: text),
      conversation: .channelSecret(secret),
      direction: .incoming, text: text, wireTimestamp: ts,
      senderNodeName: "Alice", isRead: false, originMessageID: nil)
  }

  static func weakChannel(slot: UInt8 = 4) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Data(), channelIndex: slot, senderNodeName: "Alice",
        wireTimestamp: ts, text: "weak"),
      conversation: .channelSlot(slot),
      direction: .incoming, text: "weak", wireTimestamp: ts,
      senderNodeName: "Alice", isRead: false, originMessageID: nil)
  }

  static func files(_ root: URL) -> CloudMessageDirectoryStore {
    CloudMessageDirectoryStore(root: root)
  }
}

// MARK: - Configuration

@Suite("Folder transport — configuration")
struct FolderTransportConfigurationTests {
  /// §16.C: with no folder chosen every operation is a safe no-op.
  @Test
  func `No configured folder is a safe no-op`() async throws {
    let (store, radioA, _) = try await Fx.twoRadios()
    let t = Fx.transport(folder: nil, store: store)

    #expect(await t.status == .notConfigured)
    #expect(await t.upload(Fx.incomingDM()) == false)
    let summary = await t.reconcile()
    #expect(summary == CloudMessageReconciliationSummary())
    #expect(await t.status == .notConfigured)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }

  @Test
  func `Configured folder reports ready`() async throws {
    let (store, _, _) = try await Fx.twoRadios()
    let t = Fx.transport(folder: try Fx.tempRoot(), store: store)
    #expect(await t.refreshStatus() == .ready(lastReconciled: nil))
  }

  /// §16.W: forgetting the folder must not touch its contents.
  @Test
  func `Disconnecting forgets access without deleting remote files`() async throws {
    let (store, _, _) = try await Fx.twoRadios()
    let root = try Fx.tempRoot()
    #expect(await Fx.transport(folder: root, store: store).upload(Fx.incomingDM()))
    #expect(Fx.files(root).loadAll().records.count == 1)

    // "Disconnect" == a provider that no longer yields the folder.
    let disconnected = Fx.transport(folder: nil, store: store)
    #expect(await disconnected.refreshStatus() == .notConfigured)
    _ = await disconnected.reconcile()

    // Files survive untouched.
    #expect(Fx.files(root).loadAll().records.count == 1)
  }
}

// MARK: - Local -> remote

@Suite("Folder transport — local history to remote file")
struct FolderTransportUploadTests {
  /// §16.D/E: one local record produces one file; repeating changes nothing.
  @Test
  func `Local record produces one file and repeat is idempotent`() async throws {
    let (store, _, _) = try await Fx.twoRadios()
    let root = try Fx.tempRoot()
    let t = Fx.transport(folder: root, store: store)
    let record = Fx.incomingDM()

    #expect(await t.upload(record))
    #expect(await t.upload(record))
    #expect(await t.upload(record))
    #expect(Fx.files(root).loadAll().records == [record])
  }

  /// §16.F: the same logical message observed on two radios is one remote file.
  @Test
  func `Two radio observations of one message produce one remote file`() async throws {
    let (store, radioA, radioB) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    let cB = ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fx.peerKey)
    try await store.saveContact(cA)
    try await store.saveContact(cB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: cA.id, text: "both", timestamp: Fx.ts, direction: .incoming)
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: cB.id, text: "both", timestamp: Fx.ts, direction: .incoming)
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let root = try Fx.tempRoot()
    let t = Fx.transport(folder: root, store: store)
    #expect(await t.uploadLocalMessage(onA))
    #expect(await t.uploadLocalMessage(onB))
    #expect(Fx.files(root).loadAll().records.count == 1, "one logical message, one file")
  }

  /// §16.G/H/I: strong channel, weak channel, and outgoing all serialize.
  @Test
  func `Strong channel, weak channel, and outgoing each produce one file`() async throws {
    let (store, radioA, _) = try await Fx.twoRadios()
    let contact = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(contact)
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioA, index: 3, secret: Fx.secret))

    let strong = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "net", timestamp: Fx.ts,
      direction: .incoming, senderNodeName: "Alice")
    let weak = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 9, text: "weak", timestamp: Fx.ts,
      direction: .incoming, senderNodeName: "Alice")
    let outgoing = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contact.id, text: "sent", timestamp: Fx.ts, direction: .outgoing)
    for m in [strong, weak, outgoing] { try await store.saveMessage(m) }

    let root = try Fx.tempRoot()
    let t = Fx.transport(folder: root, store: store)
    for m in [strong, weak, outgoing] { #expect(await t.uploadLocalMessage(m)) }

    let records = Fx.files(root).loadAll().records
    #expect(records.count == 3)
    // Weak identity is preserved as weak — never upgraded on the way out.
    #expect(records.contains { $0.conversation == .channelSlot(9) })
    #expect(records.contains { $0.conversation == .channelSecret(Fx.secret) })
    #expect(records.contains { $0.direction == .outgoing })
  }

  /// §16.J: a resend mutates the same row, so it must not mint a second record.
  @Test
  func `Resend does not create a second remote logical record`() async throws {
    let (store, radioA, _) = try await Fx.twoRadios()
    let contact = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(contact)

    let sent = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contact.id, text: "ping",
      timestamp: Fx.ts, direction: .outgoing, status: .pending)
    try await store.saveMessage(sent)

    let root = try Fx.tempRoot()
    let t = Fx.transport(folder: root, store: store)
    #expect(await t.uploadLocalMessage(sent))

    // What a resend does to the row: new wire timestamp, bumped count, new status.
    let afterResend = sent.copy {
      $0.timestamp = Fx.ts + 42; $0.sendCount = 2; $0.status = .sent
    }
    #expect(await t.uploadLocalMessage(afterResend))
    #expect(Fx.files(root).loadAll().records.count == 1, "same origin id, same logical record")
  }

  /// §16.L/M: read state merges monotonically in the remote file.
  @Test
  func `Read state merges monotonically in the remote file`() async throws {
    let (store, _, _) = try await Fx.twoRadios()
    let root = try Fx.tempRoot()
    let t = Fx.transport(folder: root, store: store)

    #expect(await t.upload(Fx.incomingDM(isRead: false)))
    #expect(Fx.files(root).loadAll().records.first?.isRead == false)

    #expect(await t.upload(Fx.incomingDM(isRead: true)))
    #expect(Fx.files(root).loadAll().records.first?.isRead == true)

    // A stale unread upload must never revert it.
    #expect(await t.upload(Fx.incomingDM(isRead: false)))
    #expect(Fx.files(root).loadAll().records.first?.isRead == true)
    #expect(Fx.files(root).loadAll().records.count == 1)
  }
}

// MARK: - Remote -> local

@Suite("Folder transport — remote file to local history")
struct FolderTransportReconcileTests {
  /// §16.N/R/Y: a remote DM reconciles onto every eligible radio as independent
  /// observations, with no send work created.
  @Test
  func `Remote DM reconciles onto every eligible radio`() async throws {
    let (store, radioA, radioB) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    let cB = ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fx.peerKey)
    try await store.saveContact(cA)
    try await store.saveContact(cB)

    let root = try Fx.tempRoot()
    try Fx.files(root).save(Fx.incomingDM(text: "from another device"))

    let summary = await Fx.transport(folder: root, store: store).reconcile()
    #expect(summary.filesExamined == 1)
    #expect(summary.validRecords == 1)
    #expect(summary.observationsInserted == 2)
    #expect(summary.isClean)

    let rowsA = try await store.fetchMessages(contactID: cA.id, limit: 10, offset: 0)
    let rowsB = try await store.fetchMessages(contactID: cB.id, limit: 10, offset: 0)
    #expect(rowsA.count == 1)
    #expect(rowsB.count == 1)
    #expect(rowsA.first?.radioID == radioA)
    #expect(rowsB.first?.radioID == radioB)
    #expect(rowsA.first?.id != rowsB.first?.id, "distinct local observations")
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// §16.O/P/Q: strong channel maps per-radio; weak never fans out; outgoing
  /// never clones.
  @Test
  func `Channel and outgoing policies are preserved through reconciliation`() async throws {
    let (store, radioA, radioB) = try await Fx.twoRadios()
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioA, index: 3, secret: Fx.secret))
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioB, index: 7, secret: Fx.secret))
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(cA)
    try await store.saveContact(ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fx.peerKey))

    let originID = UUID()
    let root = try Fx.tempRoot()
    try Fx.files(root).save(Fx.strongChannel())
    try Fx.files(root).save(Fx.weakChannel(slot: 4))
    try Fx.files(root).save(CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.outgoing(originMessageID: originID),
      conversation: .direct(peerPublicKey: Fx.peerKey),
      direction: .outgoing, text: "sent", wireTimestamp: Fx.ts,
      senderNodeName: nil, isRead: false, originMessageID: originID))

    _ = await Fx.transport(folder: root, store: store).reconcile()

    // Strong channel: each radio's own local slot, no crossing.
    #expect(try await store.fetchMessages(radioID: radioA, channelIndex: 3, limit: 5, offset: 0).count == 1)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 7, limit: 5, offset: 0).count == 1)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 3, limit: 5, offset: 0).isEmpty)
    // Weak slot: never propagated.
    #expect(try await store.fetchMessages(radioID: radioA, channelIndex: 4, limit: 5, offset: 0).isEmpty)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 4, limit: 5, offset: 0).isEmpty)
    // Outgoing: never cloned onto a radio that did not author it.
    #expect(try await store.fetchMessage(id: originID) == nil)

    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// §16.S/T/U: one bad document must not stop the good ones.
  @Test
  func `Malformed documents are counted without blocking valid ones`() async throws {
    let (store, radioA, _) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(cA)

    let root = try Fx.tempRoot()
    let files = Fx.files(root)
    try files.save(Fx.incomingDM(text: "good"))

    // Malformed JSON under an otherwise legal name.
    let bad = Fx.incomingDM(text: "corrupt")
    let badName = try #require(CloudMessageDirectoryStore.fileName(for: bad.fingerprint))
    try Data("{".utf8).write(to: files.messagesDirectory.appendingPathComponent(badName))

    // Unsupported future format version.
    let future = Fx.incomingDM(text: "future")
    let futureName = try #require(CloudMessageDirectoryStore.fileName(for: future.fingerprint))
    let bumped = CloudMessageRecord(
      formatVersion: 99, fingerprint: future.fingerprint, conversation: future.conversation,
      direction: .incoming, text: future.text, wireTimestamp: future.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil)
    try JSONEncoder().encode(bumped).write(to: files.messagesDirectory.appendingPathComponent(futureName))

    let summary = await Fx.transport(folder: root, store: store).reconcile()
    #expect(summary.filesExamined == 3)
    #expect(summary.validRecords == 1)
    #expect(summary.rejectedRecords == 2)
    #expect(summary.observationsInserted == 1)
    #expect(!summary.isClean)
    #expect(try await store.fetchMessages(contactID: cA.id, limit: 10, offset: 0).count == 1)
  }

  /// §16.X: repeated and back-to-back reconciliation is idempotent. The actor
  /// serializes overlapping passes.
  @Test
  func `Repeated and concurrent reconciliation is idempotent`() async throws {
    let (store, radioA, radioB) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    let cB = ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fx.peerKey)
    try await store.saveContact(cA)
    try await store.saveContact(cB)

    let root = try Fx.tempRoot()
    try Fx.files(root).save(Fx.incomingDM(text: "once"))
    let t = Fx.transport(folder: root, store: store)

    _ = await t.reconcile()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<5 { group.addTask { _ = await t.reconcile() } }
    }

    #expect(try await store.fetchMessages(contactID: cA.id, limit: 10, offset: 0).count == 1)
    #expect(try await store.fetchMessages(contactID: cB.id, limit: 10, offset: 0).count == 1)
    #expect(await t.lastSummary.observationsInserted == 0, "converged")
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }

  /// §16.V: a document vanishing from the folder must not delete local history.
  @Test
  func `A removed remote file does not delete local history`() async throws {
    let (store, radioA, _) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(cA)

    let root = try Fx.tempRoot()
    let record = Fx.incomingDM(text: "durable")
    try Fx.files(root).save(record)
    let t = Fx.transport(folder: root, store: store)
    _ = await t.reconcile()
    #expect(try await store.fetchMessages(contactID: cA.id, limit: 10, offset: 0).count == 1)

    try Fx.files(root).delete(fingerprint: record.fingerprint)
    let summary = await t.reconcile()
    #expect(summary.filesExamined == 0)
    #expect(try await store.fetchMessages(contactID: cA.id, limit: 10, offset: 0).count == 1,
            "local history is durable")
  }

  /// A round trip through the folder: upload from one store, reconcile into a
  /// second independent store — the end-to-end shape this sprint exists for.
  @Test
  func `Record uploaded by one installation reconciles into another`() async throws {
    let root = try Fx.tempRoot()

    // Installation 1 uploads.
    let (storeOne, radioOne, _) = try await Fx.twoRadios()
    let contactOne = ContactDTO.testContact(id: UUID(), radioID: radioOne, publicKey: Fx.peerKey)
    try await storeOne.saveContact(contactOne)
    let local = MessageDTO.testDirectMessage(
      radioID: radioOne, contactID: contactOne.id, text: "across devices",
      timestamp: Fx.ts, direction: .incoming)
    try await storeOne.saveMessage(local)
    #expect(await Fx.transport(folder: root, store: storeOne).uploadLocalMessage(local))

    // Installation 2 reconciles the same folder.
    let (storeTwo, radioTwo, _) = try await Fx.twoRadios()
    let contactTwo = ContactDTO.testContact(id: UUID(), radioID: radioTwo, publicKey: Fx.peerKey)
    try await storeTwo.saveContact(contactTwo)
    let summary = await Fx.transport(folder: root, store: storeTwo).reconcile()

    #expect(summary.validRecords == 1)
    let imported = try await storeTwo.fetchMessages(contactID: contactTwo.id, limit: 10, offset: 0)
    #expect(imported.count == 1)
    #expect(imported.first?.radioID == radioTwo, "local placement, not the source radio")
    #expect(imported.first?.id != local.id, "independent local observation")
    #expect(imported.first?.text == "across devices")
    #expect(try await storeTwo.fetchPendingSends(radioID: radioTwo).isEmpty)
  }
}

// MARK: - Privacy

@Suite("Folder transport — privacy")
struct FolderTransportPrivacyTests {
  /// §19: status and summary are coarse counts only.
  @Test
  func `Status and summary expose no sensitive content`() async throws {
    let secretText = "RENDEZVOUS AT GRID 44821"
    let (store, radioA, _) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(cA)

    let root = try Fx.tempRoot()
    try Fx.files(root).save(Fx.incomingDM(text: secretText))
    let t = Fx.transport(folder: root, store: store)
    let summary = await t.reconcile()

    for rendered in ["\(summary)", "\(await t.status)"] {
      #expect(!rendered.contains(secretText))
      #expect(!rendered.contains("44821"))
      #expect(!rendered.contains(Fx.peerKey.uppercaseHexString().prefix(8)))
      #expect(!rendered.contains(Fx.secret.uppercaseHexString().prefix(8)))
      #expect(!rendered.contains(radioA.uuidString))
    }
  }
}

// MARK: - Session sink

/// A sink that always fails, to prove local history is never held hostage to it.
private struct FailingUploader: CloudMessageRecordUploading {
  func upload(_ record: CloudMessageRecord) async -> Bool { false }
}

@Suite("Folder transport — session sink")
struct FolderTransportSessionSinkTests {
  /// The transport receives every record the session already handles — no new
  /// trigger call sites anywhere in the app.
  @Test
  func `Session triggers reach the attached folder`() async throws {
    let (store, radioA, _) = try await Fx.twoRadios()
    let contact = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(contact)

    let root = try Fx.tempRoot()
    let transport = Fx.transport(folder: root, store: store)
    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncPersistedRadioProvider(store: store))
    await session.setUploader(transport)

    let outgoing = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contact.id, text: "composed",
      timestamp: Fx.ts, direction: .outgoing)
    try await store.saveMessage(outgoing)
    await session.recordLocalMessage(outgoing)

    #expect(await session.processedTriggerCount == 1)
    let records = Fx.files(root).loadAll().records
    #expect(records.count == 1)
    #expect(records.first?.direction == .outgoing)
    #expect(records.first?.originMessageID == outgoing.id)
  }

  /// A local read reaches the folder and merges monotonically.
  @Test
  func `A local read trigger propagates read state to the folder`() async throws {
    let (store, radioA, _) = try await Fx.twoRadios()
    let contact = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(contact)

    let root = try Fx.tempRoot()
    let transport = Fx.transport(folder: root, store: store)
    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncPersistedRadioProvider(store: store))
    await session.setUploader(transport)

    let incoming = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contact.id, text: "unread",
      timestamp: Fx.ts, direction: .incoming)
    try await store.saveMessage(incoming)
    await session.recordLocalMessage(incoming)
    #expect(Fx.files(root).loadAll().records.first?.isRead == false)

    try await store.markMessageAsRead(id: incoming.id)
    await session.recordLocalRead(messageID: incoming.id)

    let records = Fx.files(root).loadAll().records
    #expect(records.count == 1, "read is a merge, not a second record")
    #expect(records.first?.isRead == true)
  }

  /// No destination attached is the pre-transport behaviour, unchanged.
  @Test
  func `No attached destination leaves reconciliation purely local`() async throws {
    let (store, radioA, radioB) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    let cB = ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fx.peerKey)
    try await store.saveContact(cA)
    try await store.saveContact(cB)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncPersistedRadioProvider(store: store))
    let incoming = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: cA.id, text: "local only",
      timestamp: Fx.ts, direction: .incoming)
    try await store.saveMessage(incoming)
    await session.recordLocalMessage(incoming)

    #expect(await session.processedTriggerCount == 1)
    #expect(try await store.fetchMessages(contactID: cB.id, limit: 10, offset: 0).count == 1)
  }

  /// §18: an unreachable destination degrades to local-only. It must not be
  /// counted as a failure, must not stop later triggers, and must not roll back
  /// the local reconciliation that already happened.
  @Test
  func `A failing destination never costs local history`() async throws {
    let (store, radioA, radioB) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    let cB = ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fx.peerKey)
    try await store.saveContact(cA)
    try await store.saveContact(cB)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncPersistedRadioProvider(store: store))
    await session.setUploader(FailingUploader())

    for index in 0..<3 {
      let message = MessageDTO.testDirectMessage(
        radioID: radioA, contactID: cA.id, text: "msg \(index)",
        timestamp: Fx.ts + UInt32(index), direction: .incoming)
      try await store.saveMessage(message)
      await session.recordLocalMessage(message)
    }

    #expect(await session.processedTriggerCount == 3, "later triggers still run")
    #expect(await session.failureCount == 0, "a remote miss is not a sync failure")
    #expect(try await store.fetchMessages(contactID: cB.id, limit: 10, offset: 0).count == 3,
            "local fan-out is unaffected")
  }

  /// Detaching stops uploads without disturbing local reconciliation.
  @Test
  func `Detaching the destination stops uploads only`() async throws {
    let (store, radioA, radioB) = try await Fx.twoRadios()
    let cA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey)
    try await store.saveContact(cA)
    try await store.saveContact(ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fx.peerKey))

    let root = try Fx.tempRoot()
    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncPersistedRadioProvider(store: store))
    await session.setUploader(Fx.transport(folder: root, store: store))

    let first = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: cA.id, text: "before", timestamp: Fx.ts, direction: .incoming)
    try await store.saveMessage(first)
    await session.recordLocalMessage(first)
    #expect(Fx.files(root).loadAll().records.count == 1)

    await session.setUploader(nil)
    let second = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: cA.id, text: "after", timestamp: Fx.ts + 1, direction: .incoming)
    try await store.saveMessage(second)
    await session.recordLocalMessage(second)

    #expect(Fx.files(root).loadAll().records.count == 1, "nothing uploaded after detaching")
    #expect(await session.processedTriggerCount == 2, "local work continued")
  }
}

// MARK: - iCloud materialization

@Suite("Folder transport — iCloud materialization")
struct FolderTransportMaterializationTests {
  /// The placeholder check must be invisible for ordinary local folders, which
  /// is what every other test — and any non-iCloud folder the user picks — uses.
  ///
  /// The `.notDownloaded` branch itself needs a real iCloud item and cannot be
  /// unit-tested here; what is pinned is that a file with no ubiquitous status
  /// is always considered readable, so the check can never silently swallow
  /// local history.
  @Test
  func `Ordinary local files are always readable and never pending`() async throws {
    let (store, radioA, _) = try await Fx.twoRadios()
    try await store.saveContact(
      ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fx.peerKey))

    let root = try Fx.tempRoot()
    let files = Fx.files(root)
    try files.save(Fx.incomingDM(text: "local"))

    let fileName = try #require(
      CloudMessageDirectoryStore.fileName(for: Fx.incomingDM(text: "local").fingerprint))
    let url = files.messagesDirectory.appendingPathComponent(fileName)
    #expect(CloudMessageDirectoryStore.isReadable(url))

    let loaded = files.loadAll()
    #expect(loaded.records.count == 1)
    #expect(loaded.pendingDownloads == 0)

    let summary = await Fx.transport(folder: root, store: store).reconcile()
    #expect(summary.pendingDownloads == 0)
    #expect(summary.isClean)
  }

  /// A missing file is absent, not "not downloaded" — the two must not be
  /// conflated, or `save` would refuse to create a record that simply is not
  /// there yet.
  @Test
  func `An absent record reads as nil rather than pending`() async throws {
    let files = Fx.files(try Fx.tempRoot())
    #expect(try files.read(fingerprint: Fx.incomingDM().fingerprint) == nil)
    #expect(try files.save(Fx.incomingDM()) == .created)
  }

  /// Pending downloads are not failures: a first sync on a new device is an
  /// ordinary state, not a broken folder.
  @Test
  func `Pending downloads do not make a summary unclean`() {
    var summary = CloudMessageReconciliationSummary()
    summary.pendingDownloads = 7
    #expect(summary.isClean)

    summary.rejectedRecords = 1
    #expect(!summary.isClean)
  }
}
