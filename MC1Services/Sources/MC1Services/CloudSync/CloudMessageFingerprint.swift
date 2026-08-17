import CryptoKit
import Foundation

/// Deterministic, opaque identity for a logical MeshCore message, usable as a
/// CloudSync key across independent MC1 installations.
///
/// Every identifier MC1 persists on a `Message` row is minted locally —
/// `Message.id`, `Contact.id`, `Channel.id`, `Message.radioID` are all `UUID()`
/// values that differ between two installs holding the same message. Even
/// `Message.deduplicationKey` embeds `Contact.id` for DMs and the channel slot
/// for channel messages, which is why backup import must rewrite it
/// (`rewriteDMDeduplicationKey`, `rewriteChannelDeduplicationKey`).
///
/// Identity here splits by origin, mirroring `PersistenceStore.messageBackupKey(for:)`:
///
/// - **Incoming** messages are observed independently by each install, so they
///   need a *content* fingerprint over portable identities: `Contact.publicKey`,
///   `Channel.secret`, the wire timestamp, and the text.
/// - **Outgoing** messages have exactly one originating install, so that
///   install's `Message.id` *is* the identity — the same choice backup makes
///   with its `out-{uuid}` key.
///
/// Identity is **radio-independent**: the observing radio is not an input. The
/// same over-the-air message heard by two different radios converges to one
/// CloudSync identity. Which radio heard it, and its SNR/path/route metadata,
/// stay local MC1 concerns.
///
/// Output is `"cmf1-<kind>-<64 uppercase hex>"`. The digest is SHA-256 over
/// length-prefixed fields, so no message text, channel secret, public key, or
/// node name survives in recoverable form.
///
/// This type is additive and side-effect free. It does not read, change, or
/// replace `DeduplicationKey`, `Message.deduplicationKey`, `isDuplicateMessage`,
/// or any backup path.
public enum CloudMessageFingerprint {
  /// Scheme tag, embedded in every digest and prefixed to every output. Bump it
  /// if the field layout changes: fingerprints from different schemes must never
  /// compare equal, and stored keys stay self-identifying.
  static let scheme = "cmf1"

  // MARK: - Incoming

  /// Fingerprint for an **incoming** direct message.
  ///
  /// - Parameters:
  ///   - peerPublicKey: The sender's full 32-byte public key, from
  ///     `Contact.publicKey`. A `Message` row stores only `senderKeyPrefix`
  ///     (6 bytes), so the caller must join through `Contact`.
  ///   - wireTimestamp: The timestamp the sender put on the wire, which is what
  ///     two installs will agree on. MC1 rewrites `Message.timestamp` when the
  ///     sender's clock is implausible and preserves the original in
  ///     `Message.senderTimestamp` (`SyncCoordinator.correctTimestampIfNeeded`),
  ///     so integrations must pass `senderTimestamp ?? timestamp` — the same
  ///     choice `MessageDTO.reactionTimestamp` already makes. Passing the
  ///     corrected value instead would let two installs that corrected
  ///     differently disagree on identity.
  ///   - text: The message body. Hashed, never embedded.
  public static func incomingDirectMessage(
    peerPublicKey: Data,
    wireTimestamp: UInt32,
    text: String
  ) -> String {
    var writer = FieldWriter(kind: "dm")
    writer.append(peerPublicKey)
    writer.append(wireTimestamp)
    writer.append(text)
    return writer.fingerprint()
  }

  /// Fingerprint for an **incoming** channel message.
  ///
  /// Channel identity is the 16-byte `Channel.secret`, not the slot: the same
  /// channel may sit at different indexes on different radios, and backup import
  /// already relocates channels between slots for this reason. A channel with no
  /// stable secret — the public channel and unconfigured slots hold an empty or
  /// all-zero secret — falls back to slot identity, matching backup import's
  /// `channelHasStableSecret(_:)`. Without that fallback every install's
  /// empty-secret slots would hash alike and unrelated channels would collapse.
  ///
  /// - Important: The MeshCore channel wire format carries **no sender public
  ///   key**. `Parsers+Messaging.ChannelMessage.parse` decodes exactly
  ///   `channelIndex`, `pathLength`, `textType`, `senderTimestamp`, and the
  ///   payload. The only sender identity available is the self-asserted
  ///   `"NodeName: "` payload prefix, which is not unique — `MessageDTO` already
  ///   notes two users may share a name. Two distinct senders sharing a node
  ///   name, posting identical text in the same second on the same channel, are
  ///   therefore indistinguishable. That is a protocol limitation, not something
  ///   this layer can fix.
  ///
  /// - Parameters:
  ///   - channelSecret: `Channel.secret`.
  ///   - channelIndex: `Channel.index`, used **only** as fallback identity when
  ///     `channelSecret` is empty or all-zero.
  ///   - senderNodeName: The name parsed from the `"NodeName: text"` prefix, or
  ///     `nil` when the payload carried no prefix.
  ///   - wireTimestamp: As for ``incomingDirectMessage(peerPublicKey:wireTimestamp:text:)``.
  ///   - text: The body *after* the node-name prefix is stripped, matching what
  ///     `SyncCoordinator.parseChannelMessage(_:)` persists.
  public static func incomingChannelMessage(
    channelSecret: Data,
    channelIndex: UInt8,
    senderNodeName: String?,
    wireTimestamp: UInt32,
    text: String
  ) -> String {
    var writer = FieldWriter(kind: "ch")
    if hasStableSecret(channelSecret) {
      writer.append("secret")
      writer.append(channelSecret)
    } else {
      writer.append("slot")
      writer.append(channelIndex)
    }
    writer.appendOptional(senderNodeName)
    writer.append(wireTimestamp)
    writer.append(text)
    return writer.fingerprint()
  }

  // MARK: - Outgoing

  /// Fingerprint for a message **originated on this installation**.
  ///
  /// An outgoing message has exactly one author, so its origin `Message.id` is
  /// already a globally unique identity and no content hashing is needed. This
  /// is the same decision backup import makes with `"out-\(id.uuidString)"`
  /// (`PersistenceStore.messageBackupKey(for:)`), and it buys two properties
  /// content hashing cannot:
  ///
  /// - Two intentional sends with identical text and timestamp stay distinct.
  /// - A resend keeps its identity. `resendDirectMessage(preserveTimestamp: false)`
  ///   re-stamps `Message.timestamp` via `updateMessageTimestamp`, so a
  ///   content-derived key would change mid-life; keying on `Message.id` does not.
  ///
  /// The digest hides the raw UUID so every fingerprint has one shape and one
  /// length. A sync layer that needs the reverse mapping should persist the
  /// origin `Message.id` alongside the fingerprint rather than trying to invert it.
  ///
  /// - Parameter originMessageID: `Message.id` on the originating install.
  public static func outgoing(originMessageID: UUID) -> String {
    var writer = FieldWriter(kind: "out")
    writer.append(originMessageID.uuidString)
    return writer.fingerprint()
  }

  // MARK: - Channel secret validity

  /// Whether a channel secret carries stable cryptographic identity.
  ///
  /// Deliberately identical to backup import's `channelHasStableSecret(_:)` so a
  /// channel that backup treats as secret-identified is fingerprinted that way too.
  ///
  /// Internal rather than private so ``CloudConversationIdentity/channel(secret:slotIndex:)``
  /// shares this exact predicate. Two copies of the rule could drift, and a drift
  /// would make a record's conversation identity and its fingerprint disagree
  /// about the same channel.
  static func hasStableSecret(_ secret: Data) -> Bool {
    !secret.isEmpty && !secret.allSatisfy { $0 == 0 }
  }
}

// MARK: - Unambiguous field encoding

/// Accumulates length-prefixed fields and hashes them.
///
/// Each field is a 4-byte big-endian length followed by its bytes, so no two
/// distinct field sequences share a byte stream. Without the length prefix
/// `["ab", "c"]` and `["a", "bc"]` would hash alike, letting a crafted node name
/// forge another message's fingerprint.
private struct FieldWriter {
  private var buffer = Data()
  private let kind: String

  /// Seeds the buffer with the scheme and kind so fingerprints of different
  /// kinds can never collide even on otherwise identical fields.
  init(kind: String) {
    self.kind = kind
    append(CloudMessageFingerprint.scheme)
    append(kind)
  }

  mutating func append(_ bytes: Data) {
    var length = UInt32(bytes.count).bigEndian
    withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
    buffer.append(bytes)
  }

  mutating func append(_ string: String) {
    append(Data(string.utf8))
  }

  mutating func append(_ value: UInt8) {
    append(Data([value]))
  }

  mutating func append(_ value: UInt32) {
    var bigEndian = value.bigEndian
    var bytes = Data()
    withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
    append(bytes)
  }

  /// Writes a presence marker before the value so `nil` and `""` never alias.
  mutating func appendOptional(_ string: String?) {
    if let string {
      append(UInt8(1))
      append(string)
    } else {
      append(UInt8(0))
    }
  }

  /// `"<scheme>-<kind>-<64 uppercase hex>"`.
  func fingerprint() -> String {
    let digest = SHA256.hash(data: buffer).map { String(format: "%02X", $0) }.joined()
    return "\(CloudMessageFingerprint.scheme)-\(kind)-\(digest)"
  }
}
