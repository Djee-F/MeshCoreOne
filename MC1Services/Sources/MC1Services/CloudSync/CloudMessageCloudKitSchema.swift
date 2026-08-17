import Foundation

// MARK: - Wire payload

/// The exact CloudKit field set for one message record, as a `Sendable` value.
///
/// A neutral struct rather than a `CKRecord` for two reasons. `CKRecord` is a
/// mutable class and not `Sendable`, so it cannot cross the `async` boundaries
/// this package compiles under; and keeping the schema in a plain value makes the
/// mapping fully unit-testable without constructing any CloudKit object. The
/// production adapter is the only place that converts this to a `CKRecord`.
///
/// Field names are a **permanent wire contract**. Once a record exists in a
/// user's iCloud database these strings cannot change without a migration, so
/// they are declared explicitly here rather than being inherited from Swift
/// property names.
public struct CloudMessageCloudKitPayload: Sendable, Equatable {
  // MARK: Field names — frozen

  public enum Field {
    public static let formatVersion = "formatVersion"
    public static let fingerprint = "fingerprint"
    public static let conversationKind = "conversationKind"
    public static let peerPublicKey = "peerPublicKey"
    public static let channelSecret = "channelSecret"
    public static let channelSlot = "channelSlot"
    public static let direction = "direction"
    public static let text = "text"
    public static let wireTimestamp = "wireTimestamp"
    public static let senderNodeName = "senderNodeName"
    public static let isRead = "isRead"
    public static let originMessageID = "originMessageID"
  }

  /// Conversation discriminator values — frozen.
  public enum ConversationKind: String, Sendable {
    case direct
    case channelSecret
    case channelSlot
  }

  /// Direction values — frozen. Strings, not the `Int` raw values of an upstream
  /// MC1 enum, so the cloud format cannot drift with a local refactor.
  public enum Direction: String, Sendable {
    case incoming
    case outgoing
  }

  /// Fields whose values CloudKit should encrypt at rest.
  ///
  /// `text`, `peerPublicKey`, `channelSecret`, and `senderNodeName` are the
  /// sensitive payload. The adapter writes exactly these through
  /// `CKRecord.encryptedValues`; everything else is a plain field. Encrypted
  /// fields cannot be queried or indexed by CloudKit, which is acceptable here
  /// because every lookup is by deterministic record name.
  public static let encryptedFieldNames: Set<String> = [
    Field.text, Field.peerPublicKey, Field.channelSecret, Field.senderNodeName
  ]

  // MARK: Values

  public var formatVersion: Int64
  public var fingerprint: String
  public var conversationKind: String
  /// Present only for ``ConversationKind/direct``.
  public var peerPublicKey: Data?
  /// Present only for ``ConversationKind/channelSecret``.
  public var channelSecret: Data?
  /// Present only for ``ConversationKind/channelSlot``.
  public var channelSlot: Int64?
  public var direction: String
  public var text: String
  public var wireTimestamp: Int64
  /// Absent key means `nil`; an empty string means `""`. The two are distinct
  /// facts about the wire payload and must not collapse.
  public var senderNodeName: String?
  public var isRead: Int64
  /// Present only for outgoing records. Stored as a UUID string.
  public var originMessageID: String?

  public init(
    formatVersion: Int64,
    fingerprint: String,
    conversationKind: String,
    peerPublicKey: Data? = nil,
    channelSecret: Data? = nil,
    channelSlot: Int64? = nil,
    direction: String,
    text: String,
    wireTimestamp: Int64,
    senderNodeName: String? = nil,
    isRead: Int64,
    originMessageID: String? = nil
  ) {
    self.formatVersion = formatVersion
    self.fingerprint = fingerprint
    self.conversationKind = conversationKind
    self.peerPublicKey = peerPublicKey
    self.channelSecret = channelSecret
    self.channelSlot = channelSlot
    self.direction = direction
    self.text = text
    self.wireTimestamp = wireTimestamp
    self.senderNodeName = senderNodeName
    self.isRead = isRead
    self.originMessageID = originMessageID
  }

  /// Immutable identity of the logical message. Everything except ``isRead``.
  ///
  /// Used to reject a save that reuses a fingerprint with different content.
  var immutableContent: CloudMessageCloudKitPayload {
    var copy = self
    copy.isRead = 0
    return copy
  }
}

/// Descriptions expose only non-sensitive shape. Message text, peer keys,
/// channel secrets, and node names never appear.
extension CloudMessageCloudKitPayload: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CloudMessageCloudKitPayload(v\(formatVersion), \(fingerprint), \(conversationKind), "
      + "\(direction), wireTimestamp: \(wireTimestamp), textBytes: \(text.utf8.count), "
      + "isRead: \(isRead != 0))"
  }

  public var debugDescription: String { description }
}

// MARK: - Errors

/// Why a portable record could not be mapped to or from the CloudKit schema.
///
/// No case carries message text, a peer key, a channel secret, or a node name.
public enum CloudMessageCloudKitSchemaError: Error, Equatable, Sendable {
  /// The record was written by a format this build does not understand. Never
  /// decoded as version 1.
  case unsupportedFormatVersion(Int64)
  /// The conversation discriminator is not one this build knows.
  case unknownConversationKind(String)
  /// The direction value is not one this build knows.
  case unknownDirection(String)
  /// A field the discriminator requires is missing.
  case missingField(String)
  /// A peer public key that is not the protocol's 32 bytes.
  case invalidPeerPublicKeyLength(Int)
  /// A channel slot outside `UInt8`.
  case channelSlotOutOfRange(Int64)
  /// A wire timestamp outside `UInt32`.
  case wireTimestampOutOfRange(Int64)
  /// An `originMessageID` that is not a well-formed UUID.
  case malformedOriginMessageID
  /// The stored fingerprint disagrees with the content it accompanies, or the
  /// record contradicts itself (outgoing without an origin id, incoming with
  /// one). Carries no payload.
  case fingerprintMismatch
}

// MARK: - Schema

/// Maps ``CloudMessageRecord`` to and from the CloudKit field set, and derives
/// the deterministic record name.
///
/// Pure and side-effect free: no CloudKit object, no network, no account.
public enum CloudMessageCloudKitSchema {
  /// CloudKit record type. Frozen — changing it orphans every existing record.
  public static let recordType = "CloudMessage"

  /// The custom zone all message history lives in.
  ///
  /// A custom zone rather than the default private zone because Sprint 2B needs
  /// `CKFetchRecordZoneChangesOperation`, which the default zone does not
  /// support, and because only custom zones report deleted record IDs during a
  /// change fetch. Choosing the default zone now would force a data migration
  /// the moment incremental sync arrives. Zone *lifecycle* is deliberately kept
  /// out of this type — see the store's `ensureZoneExists`.
  public static let zoneName = "CloudMessageHistory"

  /// Highest `formatVersion` this build can decode.
  public static let supportedFormatVersion = Int64(CloudMessageRecord.currentFormatVersion)

  // MARK: Record identity

  /// The CloudKit record name for a fingerprint.
  ///
  /// The fingerprint is used **directly**, with no second hash. It already
  /// satisfies every CloudKit record-name rule: it is ASCII, ~72 characters
  /// (limit 255), drawn only from `[a-z0-9-]` plus uppercase hex, and does not
  /// begin with `_`. It is also already deterministic, radio-independent, and
  /// free of any local UUID — exactly the properties a record name needs. Adding
  /// a hash on top would only obscure it.
  ///
  /// Same fingerprint → same record name → idempotent save and cross-device
  /// convergence.
  public static func recordName(for fingerprint: String) -> String {
    fingerprint
  }

  /// Whether a fingerprint is legal as a CloudKit record name.
  public static func isValidRecordName(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 255, !name.hasPrefix("_") else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
  }

  // MARK: Encoding

  /// Builds the CloudKit field set for a portable record.
  ///
  /// Validates the record against the existing CloudSync rules first, reusing
  /// ``CloudMessageImporter/validate(_:)`` rather than introducing a third
  /// fingerprint implementation. A record whose fingerprint disagrees with its
  /// own content never reaches CloudKit.
  public static func payload(for record: CloudMessageRecord) throws -> CloudMessageCloudKitPayload {
    do {
      try CloudMessageImporter.validate(record)
    } catch {
      throw CloudMessageCloudKitSchemaError.fingerprintMismatch
    }

    var payload = CloudMessageCloudKitPayload(
      formatVersion: Int64(record.formatVersion),
      fingerprint: record.fingerprint,
      conversationKind: "",
      direction: record.direction == .outgoing
        ? CloudMessageCloudKitPayload.Direction.outgoing.rawValue
        : CloudMessageCloudKitPayload.Direction.incoming.rawValue,
      text: record.text,
      wireTimestamp: Int64(record.wireTimestamp),
      senderNodeName: record.senderNodeName,
      isRead: record.isRead ? 1 : 0,
      originMessageID: record.originMessageID?.uuidString
    )

    switch record.conversation {
    case let .direct(peerPublicKey):
      payload.conversationKind = CloudMessageCloudKitPayload.ConversationKind.direct.rawValue
      payload.peerPublicKey = peerPublicKey
    case let .channelSecret(secret):
      payload.conversationKind = CloudMessageCloudKitPayload.ConversationKind.channelSecret.rawValue
      payload.channelSecret = secret
    case let .channelSlot(index):
      payload.conversationKind = CloudMessageCloudKitPayload.ConversationKind.channelSlot.rawValue
      payload.channelSlot = Int64(index)
    }
    return payload
  }

  // MARK: Decoding

  /// Rebuilds a portable record from a CloudKit field set.
  ///
  /// Every remote value is range-checked before narrowing. Remote data is
  /// untrusted: a malformed or hostile record must fail explicitly rather than
  /// produce a plausible-but-wrong history entry.
  public static func record(from payload: CloudMessageCloudKitPayload) throws -> CloudMessageRecord {
    guard payload.formatVersion == supportedFormatVersion else {
      throw CloudMessageCloudKitSchemaError.unsupportedFormatVersion(payload.formatVersion)
    }

    guard let kind = CloudMessageCloudKitPayload.ConversationKind(rawValue: payload.conversationKind) else {
      throw CloudMessageCloudKitSchemaError.unknownConversationKind(payload.conversationKind)
    }
    guard let direction = CloudMessageCloudKitPayload.Direction(rawValue: payload.direction) else {
      throw CloudMessageCloudKitSchemaError.unknownDirection(payload.direction)
    }

    let conversation: CloudConversationIdentity
    switch kind {
    case .direct:
      guard let key = payload.peerPublicKey else {
        throw CloudMessageCloudKitSchemaError.missingField(CloudMessageCloudKitPayload.Field.peerPublicKey)
      }
      guard key.count == ProtocolLimits.publicKeySize else {
        throw CloudMessageCloudKitSchemaError.invalidPeerPublicKeyLength(key.count)
      }
      conversation = .direct(peerPublicKey: key)

    case .channelSecret:
      guard let secret = payload.channelSecret else {
        throw CloudMessageCloudKitSchemaError.missingField(CloudMessageCloudKitPayload.Field.channelSecret)
      }
      // A secret that is empty or all-zero is by definition *not* stable
      // identity, so it could never have produced this discriminator.
      guard CloudMessageFingerprint.hasStableSecret(secret) else {
        throw CloudMessageCloudKitSchemaError.missingField(CloudMessageCloudKitPayload.Field.channelSecret)
      }
      conversation = .channelSecret(secret)

    case .channelSlot:
      guard let slot = payload.channelSlot else {
        throw CloudMessageCloudKitSchemaError.missingField(CloudMessageCloudKitPayload.Field.channelSlot)
      }
      guard let index = UInt8(exactly: slot) else {
        throw CloudMessageCloudKitSchemaError.channelSlotOutOfRange(slot)
      }
      conversation = .channelSlot(index)
    }

    guard let wireTimestamp = UInt32(exactly: payload.wireTimestamp) else {
      throw CloudMessageCloudKitSchemaError.wireTimestampOutOfRange(payload.wireTimestamp)
    }

    var originMessageID: UUID?
    if let raw = payload.originMessageID {
      guard let parsed = UUID(uuidString: raw) else {
        throw CloudMessageCloudKitSchemaError.malformedOriginMessageID
      }
      originMessageID = parsed
    }

    let record = CloudMessageRecord(
      formatVersion: Int(payload.formatVersion),
      fingerprint: payload.fingerprint,
      conversation: conversation,
      direction: direction == .outgoing ? .outgoing : .incoming,
      text: payload.text,
      wireTimestamp: wireTimestamp,
      senderNodeName: payload.senderNodeName,
      isRead: payload.isRead != 0,
      originMessageID: originMessageID
    )

    // Re-validate the reconstructed record against the fingerprint it claims,
    // so a tampered or corrupted remote record cannot enter local history.
    do {
      try CloudMessageImporter.validate(record)
    } catch {
      throw CloudMessageCloudKitSchemaError.fingerprintMismatch
    }
    return record
  }
}
