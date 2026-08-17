import Foundation

// MARK: - Direction

/// Which side originated a synchronized history entry.
///
/// Deliberately a distinct type from `MessageDirection` with **string** raw
/// values. `MessageDirection` is an upstream MC1 type whose `Int` raw values are
/// an implementation detail; a portable format that may sit in a user's iCloud
/// database for years must not inherit that coupling.
public enum CloudMessageDirection: String, Sendable, Codable, Equatable, Hashable {
  case incoming
  case outgoing
}

// MARK: - Conversation identity

/// Portable identity of the conversation a history entry belongs to.
///
/// Local database identifiers are deliberately absent: `Contact.id`,
/// `Channel.id`, and `radioID` are minted per install and mean nothing on
/// another device.
///
/// The three cases are not equally strong, and the type says so rather than
/// hiding it behind optional fields:
///
/// - ``direct(peerPublicKey:)`` and ``channelSecret(_:)`` are **strong**:
///   cryptographic identity that two installs derive identically.
/// - ``channelSlot(_:)`` is **weak**: a bare slot index, used only where MeshCore
///   offers nothing better.
public enum CloudConversationIdentity: Sendable, Codable, Equatable, Hashable {
  /// A direct-message conversation, identified by the peer's 32-byte public key.
  case direct(peerPublicKey: Data)

  /// A channel identified by its 16-byte secret. Portable across installs and
  /// across the slot the channel happens to occupy locally.
  case channelSecret(Data)

  /// A channel identified only by its local slot index, because no stable
  /// secret was available.
  ///
  /// Two situations reach this case, and both are best-effort history
  /// preservation rather than identity claims:
  ///
  /// 1. The channel resolved but holds an empty or all-zero secret — the public
  ///    channel and unconfigured slots. Backup import draws the same line in
  ///    `channelHasStableSecret(_:)` and likewise reconciles such channels by slot.
  /// 2. No local `Channel` row exists for the slot at all. MC1 still persists
  ///    those messages: the firmware attributes zero-key group traffic to the
  ///    first empty slot, as
  ///    `SyncCoordinator.shouldPostChannelNotification(forResolvedChannel:)`
  ///    documents. Dropping that history would be worse than carrying it under
  ///    an honestly-labelled weak identity.
  ///
  /// - Warning: This is a **weak** identity and the weakness is real:
  ///   - a slot index is **not globally stable**;
  ///   - two installations using the same slot may mean entirely different
  ///     channels, and MeshCore offers nothing to tell them apart;
  ///   - a future importer **must** treat this as strictly weaker than
  ///     ``channelSecret(_:)`` and must not merge conversations on a slot match
  ///     alone — see ``isStrong``;
  ///   - a record in this case makes **no cryptographic claim** about channel
  ///     identity. No secret is invented to fill the gap; the record asserts only
  ///     "slot N on the originating install".
  ///
  ///   In practice slot 0 is conventionally the public channel, which is what
  ///   makes this useful at all. Any other slot reaching this case deserves
  ///   suspicion.
  case channelSlot(UInt8)

  /// Builds channel identity, choosing the strong form when the secret carries
  /// one. Single source of truth for the strong/weak decision, shared with
  /// ``CloudMessageFingerprint`` so identity and fingerprint can never disagree
  /// about the same channel.
  public static func channel(secret: Data, slotIndex: UInt8) -> CloudConversationIdentity {
    CloudMessageFingerprint.hasStableSecret(secret) ? .channelSecret(secret) : .channelSlot(slotIndex)
  }

  /// Whether this identity is cryptographically strong. A future importer should
  /// gate conversation merging on this.
  public var isStrong: Bool {
    switch self {
    case .direct, .channelSecret: true
    case .channelSlot: false
    }
  }

  // MARK: Codable

  /// Hand-written so the encoded form is an explicit, self-describing
  /// discriminator rather than Swift's synthesized enum layout. Renaming a case
  /// in Swift must not silently change bytes that already exist in someone's
  /// iCloud database.
  private enum CodingKeys: String, CodingKey {
    case kind
    case peerPublicKey
    case channelSecret
    case channelSlot
  }

  private enum Kind: String, Codable {
    case direct
    case channelSecret
    case channelSlot
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .direct(peerPublicKey):
      try container.encode(Kind.direct, forKey: .kind)
      try container.encode(peerPublicKey, forKey: .peerPublicKey)
    case let .channelSecret(secret):
      try container.encode(Kind.channelSecret, forKey: .kind)
      try container.encode(secret, forKey: .channelSecret)
    case let .channelSlot(index):
      try container.encode(Kind.channelSlot, forKey: .kind)
      try container.encode(index, forKey: .channelSlot)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .direct:
      self = .direct(peerPublicKey: try container.decode(Data.self, forKey: .peerPublicKey))
    case .channelSecret:
      self = .channelSecret(try container.decode(Data.self, forKey: .channelSecret))
    case .channelSlot:
      self = .channelSlot(try container.decode(UInt8.self, forKey: .channelSlot))
    }
  }
}

// MARK: - Record

/// A portable, transport-neutral history entry: the minimum another MC1
/// installation would need to place this message in the right conversation.
///
/// # What this is not
///
/// Not a SwiftData `@Model`, not a `CKRecord`, and not an instruction to
/// transmit anything. A record describes a message that **already happened**.
/// Nothing in CloudSync may feed a record into `MessageService`,
/// `ChatSendQueueService`, `PendingSend`, or `MeshCoreSession`.
///
/// # What it deliberately omits
///
/// Radio-reception metadata (`snr`, `pathLength`, `pathNodes`, `routeType`,
/// `regionScope`), send-machinery state (`status`, `ackCode`, `retryAttempt`,
/// `maxRetryAttempts`, `sendCount`, `heardRepeats`, `roundTripTime`), local
/// ordering (`createdAt`, `sortDate`), local identifiers (`radioID`,
/// `contactID`, `channelIndex`), and re-derivable caches (`reactionSummary`,
/// link-preview fields). None of it describes the logical message, and several
/// fields are actively dangerous to copy — a remote device must never believe it
/// owns the originating device's send state.
public struct CloudMessageRecord: Sendable, Codable, Equatable, Hashable {
  /// Current portable format version. Bump when fields are added or their
  /// meaning changes, so a future MC1 can recognize what it is reading without
  /// inferring it from Swift type layout.
  public static let currentFormatVersion = 1

  /// Format version this record was written under.
  public let formatVersion: Int

  /// CloudSync identity, from ``CloudMessageFingerprint``. Self-identifying: it
  /// carries its own scheme prefix (`cmf1-…`), so a future reader can tell
  /// whether it understands the scheme before trusting the value.
  public let fingerprint: String

  /// Which conversation this entry belongs to.
  public let conversation: CloudConversationIdentity

  public let direction: CloudMessageDirection

  /// Message body, as persisted by MC1 (for channel messages, after the
  /// `"NodeName: "` prefix is stripped).
  public let text: String

  /// The timestamp the sender put on the wire — `senderTimestamp ?? timestamp`,
  /// the uncorrected value both installs can agree on. See
  /// ``CloudMessageFingerprint/incomingDirectMessage(peerPublicKey:wireTimestamp:text:)``
  /// for why the clock-corrected value must not be used.
  public let wireTimestamp: UInt32

  /// Sender name parsed from a channel payload's `"NodeName: "` prefix. `nil`
  /// for direct messages, where the peer is identified by public key instead.
  public let senderNodeName: String?

  /// Whether the message has been read.
  ///
  /// The one mutable field carried in this version, because a user reading on
  /// one device expects the others to follow. Its conflict rule is deliberately
  /// simple and order-independent: **monotonic OR** — once read on any device it
  /// is read everywhere, and a record never flips it back to unread. That makes
  /// merging a join over a semilattice, so no conflict-resolution engine is
  /// needed, and it matches how backup import already refuses to un-block,
  /// un-mute, or un-favorite (`mergeBackupMetadata`).
  public let isRead: Bool

  /// For ``CloudMessageDirection/outgoing`` entries, the `Message.id` of the
  /// originating install — the value the fingerprint is derived from. `nil` for
  /// incoming entries, whose identity is content-derived and whose local
  /// `Message.id` is a local implementation detail that must never travel.
  public let originMessageID: UUID?

  public init(
    formatVersion: Int = CloudMessageRecord.currentFormatVersion,
    fingerprint: String,
    conversation: CloudConversationIdentity,
    direction: CloudMessageDirection,
    text: String,
    wireTimestamp: UInt32,
    senderNodeName: String?,
    isRead: Bool,
    originMessageID: UUID?
  ) {
    self.formatVersion = formatVersion
    self.fingerprint = fingerprint
    self.conversation = conversation
    self.direction = direction
    self.text = text
    self.wireTimestamp = wireTimestamp
    self.senderNodeName = senderNodeName
    self.isRead = isRead
    self.originMessageID = originMessageID
  }
}

// MARK: - Redacted descriptions

/// Descriptions omit the message body, peer public keys, and channel secrets so
/// a stray `print`, log line, or error dump cannot leak them. Slot indexes and
/// timestamps are not sensitive and stay readable for debugging.
extension CloudConversationIdentity: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    switch self {
    case .direct: "direct(peer: <redacted>)"
    case .channelSecret: "channelSecret(<redacted>)"
    case let .channelSlot(index): "channelSlot(\(index))"
    }
  }

  public var debugDescription: String { description }
}

extension CloudMessageRecord: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CloudMessageRecord(v\(formatVersion), \(fingerprint), \(conversation), \(direction.rawValue), "
      + "wireTimestamp: \(wireTimestamp), textBytes: \(text.utf8.count), isRead: \(isRead))"
  }

  public var debugDescription: String { description }
}
