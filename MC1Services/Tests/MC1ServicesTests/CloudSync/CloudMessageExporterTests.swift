import Foundation
@testable import MC1Services
import Testing

// MARK: - Fixtures

private enum Fixture {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 7 })
  static let otherPeerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 99 })
  static let generalSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 3 })
  static let publicChannelSecret = Data(repeating: 0, count: ProtocolLimits.channelSecretSize)
  static let wireTimestamp: UInt32 = 1_704_067_200

  /// An in-memory store seeded with a device, so each test gets an isolated MC1
  /// installation with its own locally-minted identifiers.
  static func makeStore(radioID: UUID = UUID()) async throws -> PersistenceStore {
    try await PersistenceStore.createTestDataStore(radioID: radioID)
  }

  static func saveContact(
    in store: PersistenceStore,
    radioID: UUID,
    id: UUID = UUID(),
    publicKey: Data = Fixture.peerKey
  ) async throws -> ContactDTO {
    let contact = ContactDTO.testContact(id: id, radioID: radioID, publicKey: publicKey)
    try await store.saveContact(contact)
    return contact
  }

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
}

// MARK: - Incoming direct messages

@Suite("CloudMessageExporter — incoming direct messages")
struct CloudMessageExporterIncomingDirectTests {
  @Test
  func `Incoming DM exports portable identity and payload`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    let message = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id,
      text: "meet at the ridge", timestamp: Fixture.wireTimestamp, direction: .incoming
    )

    let record = try await CloudMessageExporter(store: store).export(message)

    #expect(record.conversation == .direct(peerPublicKey: Fixture.peerKey))
    #expect(record.direction == .incoming)
    #expect(record.text == "meet at the ridge")
    #expect(record.wireTimestamp == Fixture.wireTimestamp)
    #expect(record.senderNodeName == nil)
    #expect(record.formatVersion == CloudMessageRecord.currentFormatVersion)
    // Incoming identity is content-derived; the local row id must not travel.
    #expect(record.originMessageID == nil)
    #expect(record.fingerprint == CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.peerKey, wireTimestamp: Fixture.wireTimestamp, text: "meet at the ridge"
    ))
  }

  /// The headline Sprint 1A invariant: two genuinely independent installs,
  /// sharing nothing but the peer's public key and the wire payload, must export
  /// the same CloudSync identity.
  @Test
  func `Same logical DM converges across two independent installations`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    // Same peer, different local contact rows.
    let contactA = try await Fixture.saveContact(in: storeA, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: storeB, radioID: radioB)

    let messageA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id,
      text: "converge", timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    let messageB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id,
      text: "converge", timestamp: Fixture.wireTimestamp, direction: .incoming
    )

    // Everything local differs.
    #expect(messageA.id != messageB.id)
    #expect(contactA.id != contactB.id)
    #expect(radioA != radioB)

    let recordA = try await CloudMessageExporter(store: storeA).export(messageA)
    let recordB = try await CloudMessageExporter(store: storeB).export(messageB)

    #expect(recordA.fingerprint == recordB.fingerprint)
    #expect(recordA.conversation == recordB.conversation)
    #expect(recordA == recordB)
  }

  /// MC1 rewrites `Message.timestamp` when the sender's clock is implausible and
  /// keeps the original in `senderTimestamp`. Identity must follow the original,
  /// or two installs that corrected differently would diverge.
  @Test
  func `Export uses senderTimestamp as the wire timestamp when present`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    let corrected = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id,
      text: "skewed clock", timestamp: 999_999, direction: .incoming
    ).copy {
      // What SyncCoordinator.correctTimestampIfNeeded persists on correction.
      $0.timestampCorrected = true
      $0.senderTimestamp = Fixture.wireTimestamp
    }

    let record = try await CloudMessageExporter(store: store).export(corrected)

    #expect(record.wireTimestamp == Fixture.wireTimestamp)
    #expect(record.wireTimestamp != corrected.timestamp)

    // An uncorrected copy on another install carries the same value in
    // `timestamp` and no `senderTimestamp` — and must converge.
    let uncorrected = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id,
      text: "skewed clock", timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    let other = try await CloudMessageExporter(store: store).export(uncorrected)
    #expect(record.fingerprint == other.fingerprint)
  }

  @Test
  func `Different peers produce different portable identities`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let alice = try await Fixture.saveContact(in: store, radioID: radioID, publicKey: Fixture.peerKey)
    let bob = try await Fixture.saveContact(in: store, radioID: radioID, publicKey: Fixture.otherPeerKey)

    let exporter = CloudMessageExporter(store: store)
    let fromAlice = try await exporter.export(MessageDTO.testDirectMessage(
      radioID: radioID, contactID: alice.id, text: "hi",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    ))
    let fromBob = try await exporter.export(MessageDTO.testDirectMessage(
      radioID: radioID, contactID: bob.id, text: "hi",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    ))

    #expect(fromAlice.fingerprint != fromBob.fingerprint)
    #expect(fromAlice.conversation != fromBob.conversation)
  }
}

// MARK: - Incoming channel messages

@Suite("CloudMessageExporter — incoming channel messages")
struct CloudMessageExporterIncomingChannelTests {
  @Test
  func `Incoming channel message exports secret-based identity`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 2, secret: Fixture.generalSecret)

    let message = MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 2, text: "net at 1900",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )

    let record = try await CloudMessageExporter(store: store).export(message)

    #expect(record.conversation == .channelSecret(Fixture.generalSecret))
    #expect(record.conversation.isStrong)
    #expect(record.senderNodeName == "Alice")
    #expect(record.direction == .incoming)
    #expect(record.originMessageID == nil)
  }

  /// Slot placement is local. The same secret-identified channel occupying
  /// different slots on two radios must export one logical identity.
  @Test
  func `Same channel at different local slots converges across installations`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    let channelA = try await Fixture.saveChannel(in: storeA, radioID: radioA, index: 3, secret: Fixture.generalSecret)
    let channelB = try await Fixture.saveChannel(in: storeB, radioID: radioB, index: 7, secret: Fixture.generalSecret)
    #expect(channelA.id != channelB.id)
    #expect(channelA.index != channelB.index)

    let recordA = try await CloudMessageExporter(store: storeA).export(
      MessageDTO.testChannelMessage(
        radioID: radioA, channelIndex: 3, text: "roger",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )
    let recordB = try await CloudMessageExporter(store: storeB).export(
      MessageDTO.testChannelMessage(
        radioID: radioB, channelIndex: 7, text: "roger",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )

    #expect(recordA.fingerprint == recordB.fingerprint)
    #expect(recordA.conversation == recordB.conversation)
  }

  /// The public channel and unconfigured slots hold an empty or all-zero secret.
  /// Both degrade to the explicitly weaker slot identity rather than pretending
  /// such a secret is cryptographic.
  @Test(arguments: [Data(), Data(repeating: 0, count: ProtocolLimits.channelSecretSize)])
  func `Channel without a stable secret degrades to weak slot identity`(secret: Data) async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 0, secret: secret)

    let record = try await CloudMessageExporter(store: store).export(
      MessageDTO.testChannelMessage(
        radioID: radioID, channelIndex: 0, text: "cq cq",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )

    #expect(record.conversation == .channelSlot(0))
    #expect(!record.conversation.isStrong)

    // The weak identity must agree with how the fingerprint was built.
    #expect(record.fingerprint == CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Data(), channelIndex: 0,
      senderNodeName: "Alice", wireTimestamp: Fixture.wireTimestamp, text: "cq cq"
    ))
  }

  /// CORRECTED POLICY: a channel message whose slot has no local `Channel` row
  /// is still exportable. History is preserved under the weak slot identity
  /// rather than lost, and no secret is invented to fill the gap.
  @Test
  func `Missing Channel row falls back to weak slot identity instead of failing`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    // Deliberately no saveChannel: slot 6 is unknown to this installation.
    #expect(try await store.fetchChannel(radioID: radioID, index: 6) == nil)

    let message = MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 6, text: "unresolved but worth keeping",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    let record = try await CloudMessageExporter(store: store).export(message)

    #expect(record.conversation == .channelSlot(6))
    #expect(!record.conversation.isStrong)
    #expect(record.text == "unresolved but worth keeping")
  }

  /// Fingerprint/identity agreement for the missing-row path: the fingerprint
  /// must be exactly the Sprint 0 slot fallback for that same index. A record
  /// whose conversation says `channelSlot(X)` while its fingerprint was derived
  /// from some other identity source would be silently corrupt.
  @Test
  func `Missing Channel row fingerprint matches the Sprint 0 slot fallback`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)

    let record = try await CloudMessageExporter(store: store).export(
      MessageDTO.testChannelMessage(
        radioID: radioID, channelIndex: 6, text: "slot fallback",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )

    #expect(record.fingerprint == CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Data(), channelIndex: 6,
      senderNodeName: "Alice", wireTimestamp: Fixture.wireTimestamp, text: "slot fallback"
    ))
    #expect(record.conversation == .channelSlot(6))
  }

  /// No fabricated identity may leak in through the fallback: an unresolved slot
  /// must never present itself as a secret-identified channel, and must not
  /// collide with a real channel that happens to sit at the same index.
  @Test
  func `Slot fallback invents no secret and never aliases a real channel`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let exporter = CloudMessageExporter(store: store)

    // Slot 6 unknown → weak identity.
    let unresolved = try await exporter.export(MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 6, text: "same words",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    ))

    // Now configure slot 6 with a real secret; the same payload must produce a
    // different, strong identity.
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 6, secret: Fixture.generalSecret)
    let resolved = try await exporter.export(MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 6, text: "same words",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    ))

    #expect(unresolved.conversation == .channelSlot(6))
    #expect(resolved.conversation == .channelSecret(Fixture.generalSecret))
    #expect(!unresolved.conversation.isStrong)
    #expect(resolved.conversation.isStrong)
    #expect(unresolved.fingerprint != resolved.fingerprint)

    // Nothing resembling a secret appears in the weak record.
    let encoded = try String(decoding: JSONEncoder().encode(unresolved), as: UTF8.self)
    #expect(!encoded.contains("channelSecret"))
    #expect(encoded.contains("channelSlot"))
  }

  /// ACCEPTED PROTOCOL LIMITATION, kept as an executable note.
  ///
  /// The MeshCore channel wire format carries no authenticated sender key, so
  /// two distinct operators sharing a node name, posting identical text in the
  /// same second on the same channel, export to one identity. Not a defect in
  /// the exporter, and not something to paper over with invented identity.
  @Test
  func `Two senders sharing a node name are indistinguishable — protocol limitation`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 1, secret: Fixture.generalSecret)
    let exporter = CloudMessageExporter(store: store)

    let first = try await exporter.export(MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 1, text: "roger",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    ))
    let second = try await exporter.export(MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 1, text: "roger",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    ))

    #expect(
      first.fingerprint == second.fingerprint,
      "protocol limitation: channel wire format carries no sender public key"
    )
  }
}

// MARK: - Outgoing messages

@Suite("CloudMessageExporter — outgoing messages")
struct CloudMessageExporterOutgoingTests {
  @Test
  func `Outgoing DM keys on origin message id and keeps conversation identity`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    let message = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "on my way",
      timestamp: Fixture.wireTimestamp, direction: .outgoing
    )
    let record = try await CloudMessageExporter(store: store).export(message)

    #expect(record.direction == .outgoing)
    #expect(record.originMessageID == message.id)
    #expect(record.conversation == .direct(peerPublicKey: Fixture.peerKey))
    #expect(record.fingerprint == CloudMessageFingerprint.outgoing(originMessageID: message.id))
  }

  @Test
  func `Outgoing channel message keys on origin message id`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 1, secret: Fixture.generalSecret)

    let message = MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 1, text: "net control here",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, senderNodeName: "Me"
    )
    let record = try await CloudMessageExporter(store: store).export(message)

    #expect(record.direction == .outgoing)
    #expect(record.originMessageID == message.id)
    #expect(record.conversation == .channelSecret(Fixture.generalSecret))
    #expect(record.fingerprint == CloudMessageFingerprint.outgoing(originMessageID: message.id))
  }

  /// Content hashing alone could not do this: two deliberate sends agreeing on
  /// text, timestamp and recipient must stay distinct history entries.
  @Test
  func `Two separate outgoing sends with identical text and timestamp stay distinct`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    let exporter = CloudMessageExporter(store: store)

    let first = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "ok",
      timestamp: Fixture.wireTimestamp, direction: .outgoing
    )
    let second = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "ok",
      timestamp: Fixture.wireTimestamp, direction: .outgoing
    )
    #expect(first.text == second.text)
    #expect(first.timestamp == second.timestamp)

    let recordOne = try await exporter.export(first)
    let recordTwo = try await exporter.export(second)
    #expect(recordOne.fingerprint != recordTwo.fingerprint)
  }

  /// `resendDirectMessage(preserveTimestamp: false)` re-stamps the row's
  /// timestamp and bumps status/sendCount. Re-exporting the same row must yield
  /// the same CloudSync entry, not a forked one.
  @Test
  func `Re-exporting the same outgoing message after a resend keeps its identity`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    let exporter = CloudMessageExporter(store: store)

    let original = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "ping",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .sending
    )
    let afterResend = original.copy {
      $0.timestamp = Fixture.wireTimestamp + 42
      $0.sendCount = 2
      $0.status = .delivered
      $0.ackCode = 0xDEADBEEF
      $0.roundTripTime = 1234
    }

    let before = try await exporter.export(original)
    let after = try await exporter.export(afterResend)

    #expect(before.fingerprint == after.fingerprint)
    #expect(before.originMessageID == after.originMessageID)
    // Payload may legitimately advance; identity may not.
    #expect(before.wireTimestamp != after.wireTimestamp)
  }
}

// MARK: - Portability invariants

@Suite("CloudMessageExporter — portability invariants")
struct CloudMessageExporterPortabilityTests {
  /// No local database identifier may appear anywhere in the encoded record,
  /// except the deliberately-allowed outgoing `originMessageID`.
  @Test
  func `Incoming records carry no local Contact, Channel, Message, or radio identifier`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    let channel = try await Fixture.saveChannel(
      in: store, radioID: radioID, index: 4, secret: Fixture.generalSecret
    )
    let exporter = CloudMessageExporter(store: store)

    let dm = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "hello",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    let channelMessage = MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 4, text: "hello",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )

    for (record, message) in try await [
      (exporter.export(dm), dm),
      (exporter.export(channelMessage), channelMessage)
    ] {
      let encoded = try String(decoding: JSONEncoder().encode(record), as: UTF8.self)
      #expect(!encoded.contains(contact.id.uuidString))
      #expect(!encoded.contains(channel.id.uuidString))
      #expect(!encoded.contains(radioID.uuidString))
      #expect(!encoded.contains(message.id.uuidString))
      #expect(record.originMessageID == nil)
    }
  }

  /// Runtime and send-machinery state must not survive into the portable record.
  /// A remote device must never believe it owns the originating device's send state.
  @Test
  func `Record omits send state and radio reception metadata`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    let message = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "hello",
      timestamp: Fixture.wireTimestamp, direction: .outgoing,
      status: .retrying, ackCode: 0xABCDEF01, pathLength: 3, snr: -7.25,
      roundTripTime: 4321, sendCount: 4, retryAttempt: 2, maxRetryAttempts: 5
    )

    let encoded = try String(
      decoding: JSONEncoder().encode(await CloudMessageExporter(store: store).export(message)),
      as: UTF8.self
    )

    for forbidden in ["status", "ackCode", "retryAttempt", "maxRetryAttempts", "sendCount",
                      "roundTripTime", "snr", "pathLength", "pathNodes", "routeType",
                      "regionScope", "heardRepeats", "createdAt", "sortDate",
                      "radioID", "contactID", "channelIndex", "reactionSummary", "linkPreview"] {
      #expect(!encoded.contains(forbidden), "portable record must not carry \(forbidden)")
    }
  }

  @Test
  func `Record survives a Codable round-trip deterministically`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    let exporter = CloudMessageExporter(store: store)

    let dm = try await exporter.export(MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "round trip",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    ))
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 1, secret: Fixture.generalSecret)
    let channelRecord = try await exporter.export(MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 1, text: "round trip",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    ))
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 5, secret: Fixture.publicChannelSecret)
    let slotRecord = try await exporter.export(MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 5, text: "round trip",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: nil
    ))

    // Byte-stable re-encoding requires `.sortedKeys`: JSONEncoder does not
    // otherwise promise a key order, so a future storage layer that hashes or
    // diffs serialized bytes must pin the formatting rather than assume it.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let decoder = JSONDecoder()

    // Covers all three conversation-identity cases, including the hand-written
    // enum coding.
    for record in [dm, channelRecord, slotRecord] {
      let data = try encoder.encode(record)
      let decoded = try decoder.decode(CloudMessageRecord.self, from: data)
      #expect(decoded == record)
      #expect(decoded.conversation == record.conversation)
      #expect(try encoder.encode(decoded) == data)
    }
  }

  @Test
  func `Format version is explicit in the encoded payload and survives a round-trip`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    let record = try await CloudMessageExporter(store: store).export(
      MessageDTO.testDirectMessage(
        radioID: radioID, contactID: contact.id, text: "versioned",
        timestamp: Fixture.wireTimestamp, direction: .incoming
      )
    )

    let encoded = try String(decoding: JSONEncoder().encode(record), as: UTF8.self)
    // Readable without decoding into a Swift type, so a future reader can decide
    // whether it understands the format before trusting it.
    #expect(encoded.contains("\"formatVersion\":1"))
    #expect(record.fingerprint.hasPrefix("cmf1-"))

    let decoded = try JSONDecoder().decode(CloudMessageRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded.formatVersion == CloudMessageRecord.currentFormatVersion)
  }

  /// A future record must not be silently mistaken for a version 1 record, and a
  /// record with no version at all must not default to one. Both would let a
  /// future reader misinterpret data it does not actually understand.
  @Test
  func `Unknown format versions decode as themselves and a missing version fails`() throws {
    let future = """
    {"formatVersion":999,"fingerprint":"cmf1-dm-AA","conversation":{"kind":"channelSlot",\
    "channelSlot":3},"direction":"incoming","text":"hi","wireTimestamp":1,"isRead":false}
    """
    let decoded = try JSONDecoder().decode(CloudMessageRecord.self, from: Data(future.utf8))
    #expect(decoded.formatVersion == 999)
    #expect(decoded.formatVersion != CloudMessageRecord.currentFormatVersion)

    let versionless = """
    {"fingerprint":"cmf1-dm-AA","conversation":{"kind":"channelSlot","channelSlot":3},\
    "direction":"incoming","text":"hi","wireTimestamp":1,"isRead":false}
    """
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(CloudMessageRecord.self, from: Data(versionless.utf8))
    }
  }

  /// An absent sender name and an empty one are different facts about the wire
  /// payload, and must stay different across a round-trip.
  @Test
  func `Nil and empty senderNodeName stay distinguishable across a round-trip`() throws {
    func record(senderNodeName: String?) -> CloudMessageRecord {
      CloudMessageRecord(
        fingerprint: "cmf1-ch-AA", conversation: .channelSlot(1), direction: .incoming,
        text: "hi", wireTimestamp: 1, senderNodeName: senderNodeName,
        isRead: false, originMessageID: nil
      )
    }
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let absent = try decoder.decode(CloudMessageRecord.self, from: encoder.encode(record(senderNodeName: nil)))
    let empty = try decoder.decode(CloudMessageRecord.self, from: encoder.encode(record(senderNodeName: "")))

    #expect(absent.senderNodeName == nil)
    #expect(empty.senderNodeName == "")
    #expect(absent != empty)
  }

  /// The one local identifier deliberately allowed to travel must survive intact.
  @Test
  func `Outgoing originMessageID survives a round-trip`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    let message = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "sent",
      timestamp: Fixture.wireTimestamp, direction: .outgoing
    )

    let record = try await CloudMessageExporter(store: store).export(message)
    let decoded = try JSONDecoder().decode(
      CloudMessageRecord.self, from: JSONEncoder().encode(record)
    )

    #expect(decoded.originMessageID == message.id)
    #expect(decoded == record)
  }

  /// `Data` payloads inside the conversation enum must survive byte-exactly —
  /// the peer key and channel secret are the identity, so any corruption there
  /// silently repoints a conversation.
  @Test
  func `Data payloads in conversation identity survive a round-trip byte-exactly`() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for identity in [
      CloudConversationIdentity.direct(peerPublicKey: Fixture.peerKey),
      .channelSecret(Fixture.generalSecret),
      .channelSlot(9)
    ] {
      let record = CloudMessageRecord(
        fingerprint: "cmf1-dm-AA", conversation: identity, direction: .incoming,
        text: "hi", wireTimestamp: 1, senderNodeName: nil, isRead: false, originMessageID: nil
      )
      let decoded = try decoder.decode(CloudMessageRecord.self, from: encoder.encode(record))
      #expect(decoded.conversation == identity)
    }
  }
}

// MARK: - Privacy

@Suite("CloudMessageExporter — privacy")
struct CloudMessageExporterPrivacyTests {
  @Test
  func `Fingerprint reveals neither message text nor channel secret`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 1, secret: Fixture.generalSecret)

    let secretText = "RENDEZVOUS AT GRID 44821"
    let record = try await CloudMessageExporter(store: store).export(
      MessageDTO.testChannelMessage(
        radioID: radioID, channelIndex: 1, text: secretText,
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )

    #expect(!record.fingerprint.contains(secretText))
    #expect(!record.fingerprint.contains("44821"))
    #expect(!record.fingerprint.contains(Fixture.generalSecret.uppercaseHexString().prefix(16)))
  }

  /// Descriptions are what end up in logs and error dumps, so they must not
  /// carry the body, the peer key, or the channel secret.
  @Test
  func `Descriptions redact message text, peer keys, and channel secrets`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 1, secret: Fixture.generalSecret)
    let exporter = CloudMessageExporter(store: store)

    let secretText = "RENDEZVOUS AT GRID 44821"
    let dm = try await exporter.export(MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: secretText,
      timestamp: Fixture.wireTimestamp, direction: .incoming
    ))
    let channelRecord = try await exporter.export(MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 1, text: secretText,
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    ))

    for rendered in [dm.description, dm.debugDescription,
                     channelRecord.description, channelRecord.debugDescription] {
      #expect(!rendered.contains(secretText))
      #expect(!rendered.contains("44821"))
      #expect(!rendered.contains(Fixture.peerKey.uppercaseHexString().prefix(8)))
      #expect(!rendered.contains(Fixture.generalSecret.uppercaseHexString().prefix(8)))
    }
    #expect(dm.description.contains("<redacted>"))
    #expect(channelRecord.description.contains("<redacted>"))
    // Slot indexes are not sensitive and stay legible for debugging.
    #expect(CloudConversationIdentity.channelSlot(4).description == "channelSlot(4)")
  }
}

// MARK: - Read-only and failure behaviour

@Suite("CloudMessageExporter — read-only and failure behaviour")
struct CloudMessageExporterSafetyTests {
  /// The no-send invariant, observably. Export must leave the database exactly
  /// as it found it — in particular it must not create a `PendingSend`, which is
  /// the only row type that can cause MC1 to transmit.
  @Test
  func `Export creates no PendingSend and mutates nothing`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 1, secret: Fixture.generalSecret)

    let dm = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "no send please",
      timestamp: Fixture.wireTimestamp, direction: .outgoing
    )
    let channelMessage = MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 1, text: "no send please",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, senderNodeName: "Me"
    )
    // The slot-fallback path must be read-only too: a missing Channel row must
    // not tempt the exporter into creating one.
    let unresolvedChannelMessage = MessageDTO.testChannelMessage(
      radioID: radioID, channelIndex: 6, text: "no send please",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )

    #expect(try await store.fetchPendingSends(radioID: radioID).isEmpty)
    let contactsBefore = try await store.fetchContacts(radioID: radioID)
    let channelsBefore = try await store.fetchChannels(radioID: radioID)

    let exporter = CloudMessageExporter(store: store)
    _ = try await exporter.export(dm)
    _ = try await exporter.export(channelMessage)
    _ = try await exporter.export(unresolvedChannelMessage)

    // No outbox row was created, so nothing can be drained onto the radio.
    #expect(try await store.fetchPendingSends(radioID: radioID).isEmpty)
    // No message row was persisted by exporting it.
    #expect(try await store.fetchMessage(id: dm.id) == nil)
    #expect(try await store.fetchMessage(id: channelMessage.id) == nil)
    #expect(try await store.fetchMessage(id: unresolvedChannelMessage.id) == nil)
    // Nothing the exporter read was modified, and no Channel row was conjured
    // for the unresolved slot.
    #expect(try await store.fetchContacts(radioID: radioID) == contactsBefore)
    #expect(try await store.fetchChannels(radioID: radioID) == channelsBefore)
    #expect(try await store.fetchChannel(radioID: radioID, index: 6) == nil)
  }

  @Test
  func `A message belonging to no conversation fails explicitly`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let orphan = MessageDTO.testDirectMessage(
      radioID: radioID, text: "orphan", timestamp: Fixture.wireTimestamp, direction: .incoming
    ).copy { $0.contactID = nil }

    await #expect(throws: CloudMessageExportError.missingConversation(messageID: orphan.id)) {
      try await CloudMessageExporter(store: store).export(orphan)
    }
  }

  @Test
  func `A message claiming both a contact and a channel fails explicitly`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    let corrupt = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "both",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    ).copy { $0.channelIndex = 1 }

    await #expect(throws: CloudMessageExportError.ambiguousConversation(messageID: corrupt.id)) {
      try await CloudMessageExporter(store: store).export(corrupt)
    }
  }

  @Test
  func `A missing contact row fails explicitly rather than producing a malformed record`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let danglingID = UUID()
    let message = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: danglingID, text: "dangling",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )

    await #expect(throws: CloudMessageExportError.contactNotFound(contactID: danglingID)) {
      try await CloudMessageExporter(store: store).export(message)
    }
  }

  @Test
  func `A contact with a malformed public key fails explicitly`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contactID = UUID()
    try await store.saveContact(
      ContactDTO.testContact(id: contactID, radioID: radioID, publicKey: Data([0x01, 0x02, 0x03]))
    )
    let message = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contactID, text: "bad key",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )

    await #expect(throws: CloudMessageExportError.invalidPeerPublicKey(contactID: contactID, byteCount: 3)) {
      try await CloudMessageExporter(store: store).export(message)
    }
  }
}
