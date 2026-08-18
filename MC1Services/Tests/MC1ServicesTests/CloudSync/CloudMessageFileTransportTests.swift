import Foundation
@testable import MC1Services
import Testing

// MARK: - Fixtures

private enum Fixture {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 37 })
  static let secret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 43 })
  static let wireTimestamp: UInt32 = 1_704_067_200

  /// A fresh temporary directory. No iCloud, no Apple ID, no network.
  static func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mc1-filetransport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func incomingDM(text: String = "hello", isRead: Bool = false) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: peerKey, wireTimestamp: wireTimestamp, text: text
      ),
      conversation: .direct(peerPublicKey: peerKey),
      direction: .incoming, text: text, wireTimestamp: wireTimestamp,
      senderNodeName: nil, isRead: isRead, originMessageID: nil
    )
  }

  static func incomingStrongChannel(text: String = "net at 1900") -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: secret, channelIndex: 0,
        senderNodeName: "Alice", wireTimestamp: wireTimestamp, text: text
      ),
      conversation: .channelSecret(secret),
      direction: .incoming, text: text, wireTimestamp: wireTimestamp,
      senderNodeName: "Alice", isRead: false, originMessageID: nil
    )
  }

  static func incomingWeakChannel(slot: UInt8 = 4) -> CloudMessageRecord {
    let text = "weak"
    return CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Data(), channelIndex: slot,
        senderNodeName: "Alice", wireTimestamp: wireTimestamp, text: text
      ),
      conversation: .channelSlot(slot),
      direction: .incoming, text: text, wireTimestamp: wireTimestamp,
      senderNodeName: "Alice", isRead: false, originMessageID: nil
    )
  }

  static func outgoing(id: UUID = UUID()) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.outgoing(originMessageID: id),
      conversation: .direct(peerPublicKey: peerKey),
      direction: .outgoing, text: "sent", wireTimestamp: wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: id
    )
  }

  static func twoRadioStore() async throws -> (PersistenceStore, UUID, UUID) {
    let a = UUID(), b = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: a)
    try await store.saveDevice(DeviceDTO.testDevice(
      id: b, radioID: b, publicKey: Data(repeating: 0x06, count: ProtocolLimits.publicKeySize)
    ))
    return (store, a, b)
  }
}

// MARK: - Round trip and identity

@Suite("File transport — round trip and file identity")
struct CloudMessageFileRoundTripTests {
  @Test
  func `Every record kind survives file round trip`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let id = UUID()

    for record in [
      Fixture.incomingDM(), Fixture.incomingStrongChannel(),
      Fixture.incomingWeakChannel(), Fixture.outgoing(id: id)
    ] {
      try store.save(record)
      #expect(try store.read(fingerprint: record.fingerprint) == record)
    }
    #expect(store.loadAll().records.count == 4)
    #expect(store.loadAll().failures.isEmpty)
  }

  @Test
  func `File name is the fingerprint and is deterministic`() throws {
    let record = Fixture.incomingDM()
    let name = try #require(CloudMessageDirectoryStore.fileName(for: record.fingerprint))
    #expect(name == "\(record.fingerprint).json")
    #expect(name == CloudMessageDirectoryStore.fileName(for: record.fingerprint))

    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    try store.save(record)
    let listed = try FileManager.default.contentsOfDirectory(atPath: store.messagesDirectory.path)
    #expect(listed == [name])
  }

  /// Path traversal and separators are impossible by charset construction.
  @Test(arguments: [
    "../escape", "a/b", "a\\b", "..", ".", "", "with space",
    "cmf1-dm-AA/../../etc", "notafingerprint", "CMF1-dm-AA"
  ])
  func `Illegal file stems are rejected`(stem: String) {
    #expect(!CloudMessageDirectoryStore.isValidFingerprintFileStem(stem))
    #expect(CloudMessageDirectoryStore.fileName(for: stem) == nil)
  }

  @Test
  func `Over-long stems are rejected`() {
    let long = "cmf1-dm-" + String(repeating: "A", count: 300)
    #expect(!CloudMessageDirectoryStore.isValidFingerprintFileStem(long))
  }

  /// The file name alone is never trusted.
  @Test
  func `Content whose fingerprint differs from the file name is rejected`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let honest = Fixture.incomingDM(text: "honest")
    let impostor = Fixture.incomingDM(text: "impostor")
    try store.save(honest)

    // Plant the impostor's body under the honest record's name.
    let url = store.messagesDirectory.appendingPathComponent("\(honest.fingerprint).json")
    try CloudMessageDirectoryStore.makeEncoder().encode(impostor).write(to: url)

    #expect(throws: CloudMessageFileTransportError.fingerprintMismatch) {
      try store.read(fingerprint: honest.fingerprint)
    }
    #expect(store.loadAll().records.isEmpty)
    #expect(store.loadAll().failures.first?.reason == .fingerprintMismatch)
  }

  @Test
  func `Malformed, truncated, and unsupported-version files are rejected`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let record = Fixture.incomingDM()
    let name = try #require(CloudMessageDirectoryStore.fileName(for: record.fingerprint))
    let url = store.messagesDirectory
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let file = url.appendingPathComponent(name)

    // Malformed JSON
    try Data("{not json".utf8).write(to: file)
    #expect(throws: CloudMessageFileTransportError.malformedContent) {
      try store.read(fingerprint: record.fingerprint)
    }

    // Truncated valid JSON
    let full = try CloudMessageDirectoryStore.makeEncoder().encode(record)
    try full.prefix(full.count / 2).write(to: file)
    #expect(throws: CloudMessageFileTransportError.malformedContent) {
      try store.read(fingerprint: record.fingerprint)
    }

    // Unsupported future format version — rejected, never read as version 1.
    let future = CloudMessageRecord(
      formatVersion: 99, fingerprint: record.fingerprint, conversation: record.conversation,
      direction: .incoming, text: record.text, wireTimestamp: record.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )
    try JSONEncoder().encode(future).write(to: file)
    #expect(throws: CloudMessageFileTransportError.fingerprintMismatch) {
      try store.read(fingerprint: record.fingerprint)
    }
  }
}

// MARK: - Directory hygiene

@Suite("File transport — directory hygiene")
struct CloudMessageFileDirectoryTests {
  /// Unrelated files, dotfiles, iCloud placeholders, conflict copies, and
  /// atomic-write temporaries must all be ignored rather than misread.
  @Test
  func `Enumeration ignores everything that is not a message document`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let record = Fixture.incomingDM()
    try store.save(record)

    let dir = store.messagesDirectory
    for noise in [
      ".DS_Store",
      ".\(record.fingerprint).json.icloud",       // iCloud not-yet-downloaded placeholder
      "\(record.fingerprint) 2.json",              // iCloud conflict copy (space)
      "notes.txt",
      "\(record.fingerprint).json.tmp",            // atomic-write style temporary
      "README"
    ] {
      try Data("noise".utf8).write(to: dir.appendingPathComponent(noise))
    }

    let result = store.loadAll()
    #expect(result.records == [record], "only the genuine document loads")
    #expect(result.failures.isEmpty, "noise is skipped silently, not reported as corruption")
  }

  /// One corrupt record must not block the rest.
  @Test
  func `A corrupt file does not prevent other records loading`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let good1 = Fixture.incomingDM(text: "one")
    let good2 = Fixture.incomingStrongChannel(text: "two")
    try store.save(good1)
    try store.save(good2)

    let corrupt = Fixture.incomingWeakChannel()
    let name = try #require(CloudMessageDirectoryStore.fileName(for: corrupt.fingerprint))
    try Data("{".utf8).write(to: store.messagesDirectory.appendingPathComponent(name))

    let result = store.loadAll()
    #expect(Set(result.records) == Set([good1, good2]))
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.reason == .malformedContent)
    #expect(result.failures.first?.fileName == name)
  }
}

// MARK: - Idempotency, merge, conflict

@Suite("File transport — idempotency, merge, conflict")
struct CloudMessageFileMergeTests {
  @Test
  func `Repeated save is idempotent and leaves one valid file`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let record = Fixture.incomingDM()

    #expect(try store.save(record) == .created)
    #expect(try store.save(record) == .unchanged)
    #expect(try store.save(record) == .unchanged)

    let listed = try FileManager.default.contentsOfDirectory(atPath: store.messagesDirectory.path)
    #expect(listed.count == 1, "atomic write leaves no stray temporary behind")
    #expect(try store.read(fingerprint: record.fingerprint) == record)
  }

  /// Monotonic in all four combinations.
  @Test
  func `isRead merges monotonically`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let unread = Fixture.incomingDM(isRead: false)
    let read = Fixture.incomingDM(isRead: true)
    #expect(unread.fingerprint == read.fingerprint)

    // false + false -> false
    #expect(try store.save(unread) == .created)
    #expect(try store.save(unread) == .unchanged)
    #expect(try store.read(fingerprint: unread.fingerprint)?.isRead == false)

    // false + true -> true
    #expect(try store.save(read) == .markedRead)
    #expect(try store.read(fingerprint: read.fingerprint)?.isRead == true)

    // true + false -> stays true
    #expect(try store.save(unread) == .unchanged)
    #expect(try store.read(fingerprint: read.fingerprint)?.isRead == true)

    // true + true -> stays true
    #expect(try store.save(read) == .unchanged)
    #expect(try store.read(fingerprint: read.fingerprint)?.isRead == true)
  }

  @Test
  func `Incompatible immutable content under one fingerprint is rejected`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let genuine = Fixture.incomingDM(text: "genuine")
    try store.save(genuine)

    // A record claiming the same fingerprint with different immutable content.
    let forged = CloudMessageRecord(
      fingerprint: genuine.fingerprint, conversation: genuine.conversation,
      direction: .incoming, text: genuine.text,
      wireTimestamp: genuine.wireTimestamp + 1,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )
    // It cannot even be encoded — its own fingerprint disagrees with its content.
    #expect(throws: CloudMessageFileTransportError.fingerprintMismatch) {
      try store.save(forged)
    }

    // Plant it on disk to exercise the store's own collision check.
    let url = store.messagesDirectory.appendingPathComponent("\(genuine.fingerprint).json")
    try JSONEncoder().encode(forged).write(to: url)
    #expect(throws: CloudMessageFileTransportError.fingerprintMismatch) {
      try store.save(genuine)
    }
    // The planted file was not overwritten.
    #expect(try Data(contentsOf: url) != CloudMessageDirectoryStore.makeEncoder().encode(genuine))
  }

  /// Two devices independently writing the same logical message converge on one
  /// file rather than duplicating.
  @Test
  func `Two devices writing the same logical message converge`() throws {
    let shared = try Fixture.makeTempRoot()
    let deviceA = CloudMessageDirectoryStore(root: shared)
    let deviceB = CloudMessageDirectoryStore(root: shared)
    let record = Fixture.incomingDM(text: "both saw it")

    #expect(try deviceA.save(record) == .created)
    #expect(try deviceB.save(record) == .unchanged)
    #expect(deviceA.loadAll().records.count == 1)

    // B later marks it read; A observes the merge.
    #expect(try deviceB.save(Fixture.incomingDM(text: "both saw it", isRead: true)) == .markedRead)
    #expect(try deviceA.read(fingerprint: record.fingerprint)?.isRead == true)
  }

  /// Deletion is local-only; the policy is durable remote history.
  @Test
  func `Delete removes exactly one file and is not propagated`() throws {
    let root = try Fixture.makeTempRoot()
    let store = CloudMessageDirectoryStore(root: root)
    let keep = Fixture.incomingDM(text: "keep")
    let drop = Fixture.incomingDM(text: "drop")
    try store.save(keep)
    try store.save(drop)

    try store.delete(fingerprint: drop.fingerprint)
    #expect(store.loadAll().records == [keep].sorted { $0.fingerprint < $1.fingerprint }
      || store.loadAll().records == [keep])
    #expect(try store.read(fingerprint: drop.fingerprint) == nil)
    // Absent delete is a no-op.
    try store.delete(fingerprint: drop.fingerprint)
  }
}

// MARK: - Reconciliation through the existing engine

@Suite("File transport — reconciliation reuses the existing engine")
struct CloudMessageFileReconciliationTests {
  /// Files decoded from the transport go through the accepted importer/router,
  /// not a second import path.
  @Test
  func `Imported DM lands on both eligible radios as two observations`() async throws {
    let (store, radioA, radioB) = try await Fixture.twoRadioStore()
    let contactA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fixture.peerKey)
    let contactB = ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fixture.peerKey)
    try await store.saveContact(contactA)
    try await store.saveContact(contactB)

    let root = try Fixture.makeTempRoot()
    let files = CloudMessageDirectoryStore(root: root)
    try files.save(Fixture.incomingDM(text: "from a file"))

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncPersistedRadioProvider(store: store)
    )
    let coordinator = CloudMessageSyncCoordinator(store: store)
    for record in files.loadAll().records {
      _ = try await coordinator.synchronize(record, across: [radioA, radioB])
    }

    let rowsA = try await store.fetchMessages(contactID: contactA.id, limit: 10, offset: 0)
    let rowsB = try await store.fetchMessages(contactID: contactB.id, limit: 10, offset: 0)
    #expect(rowsA.count == 1)
    #expect(rowsB.count == 1)
    #expect(rowsA.first?.radioID == radioA)
    #expect(rowsB.first?.radioID == radioB)
    #expect(rowsA.first?.id != rowsB.first?.id, "independent local observations")

    // Repeating creates no extra rows.
    for record in files.loadAll().records {
      _ = try await coordinator.synchronize(record, across: [radioA, radioB])
    }
    #expect(try await store.fetchMessages(contactID: contactA.id, limit: 10, offset: 0).count == 1)
    #expect(try await store.fetchMessages(contactID: contactB.id, limit: 10, offset: 0).count == 1)

    // THE invariant: no send work anywhere.
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
    #expect(await session.processedTriggerCount == 0, "file import is not a local-origin trigger")
  }

  @Test
  func `Strong channel maps to each radio local slot, weak does not propagate`() async throws {
    let (store, radioA, radioB) = try await Fixture.twoRadioStore()
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioA, index: 3, secret: Fixture.secret))
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioB, index: 7, secret: Fixture.secret))

    let root = try Fixture.makeTempRoot()
    let files = CloudMessageDirectoryStore(root: root)
    try files.save(Fixture.incomingStrongChannel())
    try files.save(Fixture.incomingWeakChannel(slot: 4))

    let coordinator = CloudMessageSyncCoordinator(store: store)
    for record in files.loadAll().records {
      _ = try await coordinator.synchronize(record, across: [radioA, radioB])
    }

    // Strong channel: each radio's own slot, no slot crossing.
    #expect(try await store.fetchMessages(radioID: radioA, channelIndex: 3, limit: 10, offset: 0).count == 1)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 7, limit: 10, offset: 0).count == 1)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 3, limit: 10, offset: 0).isEmpty)

    // Weak channel: never fanned out.
    #expect(try await store.fetchMessages(radioID: radioA, channelIndex: 4, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 4, limit: 10, offset: 0).isEmpty)

    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  @Test
  func `Outgoing is not fanned out and creates no send work`() async throws {
    let (store, radioA, radioB) = try await Fixture.twoRadioStore()
    let contactA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: Fixture.peerKey)
    try await store.saveContact(contactA)
    try await store.saveContact(ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: Fixture.peerKey))

    let root = try Fixture.makeTempRoot()
    let files = CloudMessageDirectoryStore(root: root)
    let outgoing = Fixture.outgoing()
    try files.save(outgoing)

    let coordinator = CloudMessageSyncCoordinator(store: store)
    for record in files.loadAll().records {
      let outcome = try await coordinator.synchronize(record, across: [radioA, radioB])
      #expect(outcome.insertedRadioIDs.isEmpty, "recognize-only; never cloned")
    }
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }
}

// MARK: - Privacy

@Suite("File transport — privacy")
struct CloudMessageFilePrivacyTests {
  private static let secretText = "RENDEZVOUS AT GRID 44821"

  @Test
  func `Errors and failure reports reveal no sensitive payload`() throws {
    let record = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Fixture.secret, channelIndex: 0, senderNodeName: "Alice",
        wireTimestamp: Fixture.wireTimestamp, text: Self.secretText
      ),
      conversation: .channelSecret(Fixture.secret),
      direction: .incoming, text: Self.secretText, wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: "Alice", isRead: false, originMessageID: nil
    )

    let errors: [any Error] = [
      CloudMessageFileTransportError.invalidFileName,
      CloudMessageFileTransportError.malformedContent,
      CloudMessageFileTransportError.fingerprintMismatch,
      CloudMessageFileTransportError.immutableContentConflict(fingerprint: record.fingerprint),
      CloudMessageFileTransportError.ioFailure
    ]
    let failure = CloudMessageFileLoadFailure(
      fileName: "\(record.fingerprint).json", reason: .malformedContent
    )

    for rendered in errors.map({ "\($0)" }) + ["\(failure)"] {
      #expect(!rendered.contains(Self.secretText))
      #expect(!rendered.contains("44821"))
      #expect(!rendered.contains("Alice"))
      #expect(!rendered.contains(Fixture.secret.uppercaseHexString().prefix(8)))
      #expect(!rendered.contains(Fixture.peerKey.uppercaseHexString().prefix(8)))
    }
  }

  /// The file name is the fingerprint — an opaque digest. It must not expose
  /// text, node name, peer key, or channel secret to the storage provider.
  @Test
  func `File name exposes no sensitive material`() throws {
    let record = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Fixture.secret, channelIndex: 0, senderNodeName: "Alice",
        wireTimestamp: Fixture.wireTimestamp, text: Self.secretText
      ),
      conversation: .channelSecret(Fixture.secret),
      direction: .incoming, text: Self.secretText, wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: "Alice", isRead: false, originMessageID: nil
    )
    let name = try #require(CloudMessageDirectoryStore.fileName(for: record.fingerprint))
    #expect(!name.contains(Self.secretText))
    #expect(!name.contains("44821"))
    #expect(!name.contains("Alice"))
    #expect(!name.contains(Fixture.secret.uppercaseHexString().prefix(8)))
    #expect(!name.contains(Fixture.peerKey.uppercaseHexString().prefix(8)))
    #expect(name.hasPrefix("cmf1-"))
  }
}
