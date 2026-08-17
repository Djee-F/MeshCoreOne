import Foundation
@testable import MC1Services
import Testing

// MARK: - Fixtures

private enum Fixture {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 17 })
  static let otherPeerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 123 })
  static let channelSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 29 })
  static let wireTimestamp: UInt32 = 1_704_067_200

  static func incomingDM(
    text: String = "hello",
    wireTimestamp: UInt32 = Fixture.wireTimestamp,
    isRead: Bool = false,
    peerKey: Data = Fixture.peerKey
  ) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: peerKey, wireTimestamp: wireTimestamp, text: text
      ),
      conversation: .direct(peerPublicKey: peerKey),
      direction: .incoming, text: text, wireTimestamp: wireTimestamp,
      senderNodeName: nil, isRead: isRead, originMessageID: nil
    )
  }

  static func incomingChannelSecret(
    text: String = "net at 1900",
    senderNodeName: String? = "Alice",
    isRead: Bool = false
  ) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: channelSecret, channelIndex: 0,
        senderNodeName: senderNodeName, wireTimestamp: wireTimestamp, text: text
      ),
      conversation: .channelSecret(channelSecret),
      direction: .incoming, text: text, wireTimestamp: wireTimestamp,
      senderNodeName: senderNodeName, isRead: isRead, originMessageID: nil
    )
  }

  static func incomingChannelSlot(
    slot: UInt8 = 4,
    senderNodeName: String? = "Alice"
  ) -> CloudMessageRecord {
    let text = "weak"
    return CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Data(), channelIndex: slot,
        senderNodeName: senderNodeName, wireTimestamp: wireTimestamp, text: text
      ),
      conversation: .channelSlot(slot),
      direction: .incoming, text: text, wireTimestamp: wireTimestamp,
      senderNodeName: senderNodeName, isRead: false, originMessageID: nil
    )
  }

  static func outgoing(
    originMessageID: UUID = UUID(),
    conversation: CloudConversationIdentity = .direct(peerPublicKey: Fixture.peerKey),
    isRead: Bool = false
  ) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.outgoing(originMessageID: originMessageID),
      conversation: conversation,
      direction: .outgoing, text: "sent", wireTimestamp: wireTimestamp,
      senderNodeName: nil, isRead: isRead, originMessageID: originMessageID
    )
  }
}

/// In-memory stand-in for the private CloudKit database.
///
/// §18.I: the storage tests need no Apple ID, no iCloud login, no CloudKit
/// environment, and no network — this actor is the entire backing store.
private actor FakeRemoteDatabase: CloudMessageRemoteDatabase {
  private var records: [String: CloudMessageCloudKitPayload] = [:]
  private(set) var zonePrepareCount = 0
  private(set) var saveCount = 0
  var failure: (any Error)?

  var recordCount: Int { records.count }

  func setFailure(_ error: (any Error)?) { failure = error }

  func ensureZoneExists() async throws {
    zonePrepareCount += 1
    if let failure { throw failure }
  }

  func payload(forRecordName recordName: String) async throws -> CloudMessageCloudKitPayload? {
    if let failure { throw failure }
    return records[recordName]
  }

  func save(_ payload: CloudMessageCloudKitPayload) async throws {
    if let failure { throw failure }
    saveCount += 1
    records[payload.fingerprint] = payload
  }

  func delete(recordName: String) async throws {
    if let failure { throw failure }
    records.removeValue(forKey: recordName)
  }

  /// Test-only surgery: plant a payload the schema would refuse to produce.
  func plant(_ payload: CloudMessageCloudKitPayload, as recordName: String) {
    records[recordName] = payload
  }

  func storedNames() -> [String] { Array(records.keys) }
}

// MARK: - A. Record identity

@Suite("CloudKit schema — record identity")
struct CloudMessageCloudKitIdentityTests {
  @Test
  func `Same fingerprint yields the same record name`() {
    let a = Fixture.incomingDM()
    let b = Fixture.incomingDM()
    #expect(a.fingerprint == b.fingerprint)
    #expect(CloudMessageCloudKitSchema.recordName(for: a.fingerprint)
      == CloudMessageCloudKitSchema.recordName(for: b.fingerprint))
  }

  @Test
  func `Different fingerprints yield different record names`() {
    let a = CloudMessageCloudKitSchema.recordName(for: Fixture.incomingDM(text: "one").fingerprint)
    let b = CloudMessageCloudKitSchema.recordName(for: Fixture.incomingDM(text: "two").fingerprint)
    #expect(a != b)
  }

  /// §18.A.3: the record name carries no local placement. Two installs holding
  /// the same logical message under different radios/contacts converge.
  @Test
  func `Record name is independent of local observation`() {
    let fingerprint = Fixture.incomingDM().fingerprint
    let name = CloudMessageCloudKitSchema.recordName(for: fingerprint)
    #expect(name == fingerprint)
    #expect(!name.contains("-0000-"), "no UUID shape")
    #expect(CloudMessageCloudKitSchema.isValidRecordName(name))
  }

  /// Every fingerprint shape must be a legal CloudKit record name.
  @Test
  func `All fingerprint kinds are legal CloudKit record names`() {
    for record in [
      Fixture.incomingDM(), Fixture.incomingChannelSecret(),
      Fixture.incomingChannelSlot(), Fixture.outgoing()
    ] {
      let name = CloudMessageCloudKitSchema.recordName(for: record.fingerprint)
      #expect(CloudMessageCloudKitSchema.isValidRecordName(name))
      #expect(name.count <= 255)
      #expect(!name.hasPrefix("_"))
    }
  }
}

// MARK: - B. Round trip

@Suite("CloudKit schema — round trip")
struct CloudMessageCloudKitRoundTripTests {
  private func roundTrip(_ record: CloudMessageRecord) throws -> CloudMessageRecord {
    try CloudMessageCloudKitSchema.record(
      from: try CloudMessageCloudKitSchema.payload(for: record)
    )
  }

  @Test
  func `Every record kind survives encode and decode`() throws {
    let originID = UUID()
    for record in [
      Fixture.incomingDM(),
      Fixture.incomingChannelSecret(),
      Fixture.incomingChannelSlot(),
      Fixture.outgoing(originMessageID: originID),
      Fixture.outgoing(originMessageID: originID, conversation: .channelSecret(Fixture.channelSecret))
    ] {
      #expect(try roundTrip(record) == record)
    }
  }

  /// §18.B.9–11: identity-bearing values must survive byte-exactly.
  @Test
  func `Identity payloads survive exactly`() throws {
    let originID = UUID()
    let outgoing = try roundTrip(Fixture.outgoing(originMessageID: originID))
    #expect(outgoing.originMessageID == originID)

    guard case let .direct(key) = try roundTrip(Fixture.incomingDM()).conversation else {
      Issue.record("expected direct"); return
    }
    #expect(key == Fixture.peerKey)
    #expect(key.count == ProtocolLimits.publicKeySize)

    guard case let .channelSecret(secret) = try roundTrip(Fixture.incomingChannelSecret()).conversation else {
      Issue.record("expected channelSecret"); return
    }
    #expect(secret == Fixture.channelSecret)

    guard case let .channelSlot(slot) = try roundTrip(Fixture.incomingChannelSlot(slot: 7)).conversation else {
      Issue.record("expected channelSlot"); return
    }
    #expect(slot == 7)
  }

  /// §18.B.12–13: nil and "" are different facts and must stay different.
  @Test
  func `Nil and empty senderNodeName stay distinct`() throws {
    let absent = try roundTrip(Fixture.incomingChannelSecret(senderNodeName: nil))
    let empty = try roundTrip(Fixture.incomingChannelSecret(senderNodeName: ""))
    #expect(absent.senderNodeName == nil)
    #expect(empty.senderNodeName == "")
    #expect(absent != empty)
    #expect(absent.fingerprint != empty.fingerprint)
  }

  /// §18.B.14: the full `UInt32` range survives the `Int64` bridge.
  @Test(arguments: [UInt32.min, 1, Fixture.wireTimestamp, UInt32.max - 1, UInt32.max])
  func `wireTimestamp boundary values survive`(timestamp: UInt32) throws {
    let record = Fixture.incomingDM(wireTimestamp: timestamp)
    #expect(try roundTrip(record).wireTimestamp == timestamp)
  }

  @Test
  func `Read state survives`() throws {
    #expect(try roundTrip(Fixture.incomingDM(isRead: true)).isRead)
    #expect(try !roundTrip(Fixture.incomingDM(isRead: false)).isRead)
  }
}

// MARK: - C. Validation

@Suite("CloudKit schema — validation of untrusted remote data")
struct CloudMessageCloudKitValidationTests {
  private func payload(_ record: CloudMessageRecord) throws -> CloudMessageCloudKitPayload {
    try CloudMessageCloudKitSchema.payload(for: record)
  }

  @Test
  func `Unsupported format version is rejected and never read as version 1`() throws {
    var p = try payload(Fixture.incomingDM())
    p.formatVersion = 99
    #expect(throws: CloudMessageCloudKitSchemaError.unsupportedFormatVersion(99)) {
      try CloudMessageCloudKitSchema.record(from: p)
    }
  }

  @Test
  func `Unknown conversation discriminator is rejected`() throws {
    var p = try payload(Fixture.incomingDM())
    p.conversationKind = "quantumEntangled"
    #expect(throws: CloudMessageCloudKitSchemaError.unknownConversationKind("quantumEntangled")) {
      try CloudMessageCloudKitSchema.record(from: p)
    }
  }

  @Test
  func `Unknown direction is rejected`() throws {
    var p = try payload(Fixture.incomingDM())
    p.direction = "sideways"
    #expect(throws: CloudMessageCloudKitSchemaError.unknownDirection("sideways")) {
      try CloudMessageCloudKitSchema.record(from: p)
    }
  }

  @Test
  func `Malformed peer key length is rejected`() throws {
    var p = try payload(Fixture.incomingDM())
    p.peerPublicKey = Data([1, 2, 3])
    #expect(throws: CloudMessageCloudKitSchemaError.invalidPeerPublicKeyLength(3)) {
      try CloudMessageCloudKitSchema.record(from: p)
    }
  }

  @Test
  func `Missing required field is rejected`() throws {
    var p = try payload(Fixture.incomingDM())
    p.peerPublicKey = nil
    #expect(throws: CloudMessageCloudKitSchemaError.missingField("peerPublicKey")) {
      try CloudMessageCloudKitSchema.record(from: p)
    }
  }

  /// An all-zero secret is by definition not stable identity, so it can never
  /// legitimately carry the `channelSecret` discriminator.
  @Test
  func `Unstable channel secret under the secret discriminator is rejected`() throws {
    var p = try payload(Fixture.incomingChannelSecret())
    p.channelSecret = Data(repeating: 0, count: ProtocolLimits.channelSecretSize)
    #expect(throws: CloudMessageCloudKitSchemaError.missingField("channelSecret")) {
      try CloudMessageCloudKitSchema.record(from: p)
    }
  }

  @Test
  func `Out-of-range slot and timestamp are rejected`() throws {
    var slotPayload = try payload(Fixture.incomingChannelSlot())
    slotPayload.channelSlot = 999
    #expect(throws: CloudMessageCloudKitSchemaError.channelSlotOutOfRange(999)) {
      try CloudMessageCloudKitSchema.record(from: slotPayload)
    }

    var timePayload = try payload(Fixture.incomingDM())
    timePayload.wireTimestamp = Int64(UInt32.max) + 1
    #expect(throws: CloudMessageCloudKitSchemaError.wireTimestampOutOfRange(Int64(UInt32.max) + 1)) {
      try CloudMessageCloudKitSchema.record(from: timePayload)
    }

    var negative = try payload(Fixture.incomingDM())
    negative.wireTimestamp = -1
    #expect(throws: CloudMessageCloudKitSchemaError.wireTimestampOutOfRange(-1)) {
      try CloudMessageCloudKitSchema.record(from: negative)
    }
  }

  @Test
  func `Malformed origin message id is rejected`() throws {
    var p = try payload(Fixture.outgoing())
    p.originMessageID = "not-a-uuid"
    #expect(throws: CloudMessageCloudKitSchemaError.malformedOriginMessageID) {
      try CloudMessageCloudKitSchema.record(from: p)
    }
  }

  /// §18.C.21: content that disagrees with its own fingerprint never encodes,
  /// and never decodes. Reuses the existing CloudSync validation rather than a
  /// third fingerprint implementation.
  @Test
  func `Fingerprint and content mismatch is rejected in both directions`() throws {
    let honest = Fixture.incomingDM()
    let tampered = CloudMessageRecord(
      fingerprint: honest.fingerprint, conversation: honest.conversation,
      direction: .incoming, text: "different text", wireTimestamp: honest.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )
    #expect(throws: CloudMessageCloudKitSchemaError.fingerprintMismatch) {
      try CloudMessageCloudKitSchema.payload(for: tampered)
    }

    var decoded = try payload(honest)
    decoded.text = "different text"
    #expect(throws: CloudMessageCloudKitSchemaError.fingerprintMismatch) {
      try CloudMessageCloudKitSchema.record(from: decoded)
    }
  }
}

// MARK: - D/E/F. Store behaviour

@Suite("CloudKit store — idempotency, merge, collision")
struct CloudMessageCloudKitStoreTests {
  @Test
  func `Repeated save creates exactly one remote record`() async throws {
    let db = FakeRemoteDatabase()
    let store = CloudMessageCloudKitStore(database: db)
    let record = Fixture.incomingDM()

    #expect(try await store.save(record) == .created)
    #expect(try await store.save(record) == .unchanged)
    #expect(try await store.save(record) == .unchanged)

    #expect(await db.recordCount == 1)
    #expect(await db.saveCount == 1, "no redundant writes after the first")
    #expect(try await store.fetch(fingerprint: record.fingerprint) == record)
  }

  @Test
  func `Delete removes exactly that record`() async throws {
    let db = FakeRemoteDatabase()
    let store = CloudMessageCloudKitStore(database: db)
    let keep = Fixture.incomingDM(text: "keep")
    let drop = Fixture.incomingDM(text: "drop")
    try await store.save(keep)
    try await store.save(drop)
    #expect(await db.recordCount == 2)

    try await store.delete(fingerprint: drop.fingerprint)
    #expect(await db.recordCount == 1)
    #expect(try await store.fetch(fingerprint: drop.fingerprint) == nil)
    #expect(try await store.fetch(fingerprint: keep.fingerprint) == keep)

    // Deleting an absent record is a no-op, not an error.
    try await store.delete(fingerprint: drop.fingerprint)
  }

  /// §18.E: monotonic. Read wins; a stale unread upload can never un-read.
  @Test
  func `isRead merges monotonically`() async throws {
    let db = FakeRemoteDatabase()
    let store = CloudMessageCloudKitStore(database: db)
    let unread = Fixture.incomingDM(isRead: false)
    let read = Fixture.incomingDM(isRead: true)
    #expect(unread.fingerprint == read.fingerprint, "isRead is not part of identity")

    #expect(try await store.save(unread) == .created)
    #expect(try await store.fetch(fingerprint: unread.fingerprint)?.isRead == false)

    // unread → read
    #expect(try await store.save(read) == .markedRead)
    #expect(try await store.fetch(fingerprint: read.fingerprint)?.isRead == true)

    // read → unread must NOT revert
    #expect(try await store.save(unread) == .unchanged)
    #expect(try await store.fetch(fingerprint: read.fingerprint)?.isRead == true)

    // repeated read is a no-op
    #expect(try await store.save(read) == .unchanged)
    #expect(try await store.fetch(fingerprint: read.fingerprint)?.isRead == true)
    #expect(await db.recordCount == 1)
  }

  /// §18.F: a fingerprint collision with different immutable content must be
  /// rejected, and the existing record left untouched.
  @Test
  func `Incompatible immutable content under one fingerprint is rejected`() async throws {
    let db = FakeRemoteDatabase()
    let store = CloudMessageCloudKitStore(database: db)
    let genuine = Fixture.incomingDM(text: "genuine")
    try await store.save(genuine)

    // Plant a record whose stored content differs while keeping the name.
    var forged = try CloudMessageCloudKitSchema.payload(for: genuine)
    forged.wireTimestamp = Int64(Fixture.wireTimestamp) + 1
    await db.plant(forged, as: genuine.fingerprint)

    await #expect(throws: CloudMessageRemoteStoreError.immutableContentConflict(
      fingerprint: genuine.fingerprint
    )) {
      try await store.save(genuine)
    }

    // The planted record survived — nothing was overwritten.
    #expect(await db.recordCount == 1)
    let stored = try await db.payload(forRecordName: genuine.fingerprint)
    #expect(stored?.wireTimestamp == Int64(Fixture.wireTimestamp) + 1)
  }

  @Test
  func `Zone preparation is idempotent and separate from saving`() async throws {
    let db = FakeRemoteDatabase()
    let store = CloudMessageCloudKitStore(database: db)
    try await store.prepare()
    try await store.prepare()
    #expect(await db.zonePrepareCount == 2, "each call is forwarded; the adapter absorbs existing-zone")
    // Saving does not implicitly create zones.
    try await store.save(Fixture.incomingDM())
    #expect(await db.zonePrepareCount == 2)
  }

  /// Remote failures collapse into the narrow model without leaking detail.
  @Test
  func `CloudKit failures map to the narrow error model`() async throws {
    let db = FakeRemoteDatabase()
    let store = CloudMessageCloudKitStore(database: db)
    await db.setFailure(CKErrorStub.notAuthenticated)

    await #expect(throws: CloudMessageRemoteStoreError.self) {
      try await store.save(Fixture.incomingDM())
    }
    #expect(await db.recordCount == 0)
  }
}

/// A stand-in error; the store must not require a real `CKError` to behave.
private enum CKErrorStub: Error { case notAuthenticated }

// MARK: - G/H. Privacy and scope

@Suite("CloudKit storage — privacy and scope")
struct CloudMessageCloudKitPrivacyTests {
  private static let secretText = "RENDEZVOUS AT GRID 44821"

  @Test
  func `Descriptions reveal no text, peer key, channel secret, or node name`() throws {
    let record = Fixture.incomingChannelSecret(text: Self.secretText, senderNodeName: "Alice")
    let payload = try CloudMessageCloudKitSchema.payload(for: record)

    for rendered in [payload.description, payload.debugDescription] {
      #expect(!rendered.contains(Self.secretText))
      #expect(!rendered.contains("44821"))
      #expect(!rendered.contains("Alice"))
      #expect(!rendered.contains(Fixture.channelSecret.uppercaseHexString().prefix(8)))
      #expect(!rendered.contains(Fixture.peerKey.uppercaseHexString().prefix(8)))
      #expect(rendered.contains("textBytes:"))
    }
  }

  @Test
  func `Error descriptions reveal no sensitive payload`() {
    let errors: [any Error] = [
      CloudMessageCloudKitSchemaError.fingerprintMismatch,
      CloudMessageCloudKitSchemaError.invalidPeerPublicKeyLength(3),
      CloudMessageCloudKitSchemaError.unsupportedFormatVersion(99),
      CloudMessageRemoteStoreError.immutableContentConflict(fingerprint: "cmf1-dm-AA"),
      CloudMessageRemoteStoreError.accountUnavailable,
      CloudMessageRemoteStoreError.cloudKitFailure
    ]
    for error in errors {
      let rendered = "\(error)"
      #expect(!rendered.contains(Self.secretText))
      #expect(!rendered.contains("44821"))
      #expect(!rendered.contains(Fixture.peerKey.uppercaseHexString().prefix(8)))
      #expect(!rendered.contains(Fixture.channelSecret.uppercaseHexString().prefix(8)))
    }
  }

  /// §18.H: the remote schema carries no local placement or send machinery.
  @Test
  func `Remote payload carries no local or send-machinery fields`() throws {
    let record = Fixture.outgoing()
    let payload = try CloudMessageCloudKitSchema.payload(for: record)
    let mirrored = Mirror(reflecting: payload).children.compactMap(\.label)

    for forbidden in ["radioID", "contactID", "channelIndex", "messageID", "status",
                      "ackCode", "retryAttempt", "maxRetryAttempts", "sendCount",
                      "heardRepeats", "roundTripTime", "pathLength", "pathNodes",
                      "snr", "routeType", "regionScope", "createdAt", "sortDate",
                      "deduplicationKey", "pendingSend", "reactionSummary"] {
      #expect(!mirrored.contains(forbidden), "remote schema must not carry \(forbidden)")
    }
    // The one deliberately-portable local identifier, outgoing only.
    #expect(mirrored.contains("originMessageID"))
    #expect(try CloudMessageCloudKitSchema.payload(for: Fixture.incomingDM()).originMessageID == nil)
  }

  /// The sensitive fields are exactly the ones flagged for CloudKit encryption.
  @Test
  func `Sensitive fields are the encrypted ones`() {
    #expect(CloudMessageCloudKitPayload.encryptedFieldNames == [
      "text", "peerPublicKey", "channelSecret", "senderNodeName"
    ])
    // Identity/routing fields stay queryable and are not encrypted.
    for plain in ["formatVersion", "fingerprint", "conversationKind", "direction",
                  "wireTimestamp", "isRead", "channelSlot", "originMessageID"] {
      #expect(!CloudMessageCloudKitPayload.encryptedFieldNames.contains(plain))
    }
  }
}
