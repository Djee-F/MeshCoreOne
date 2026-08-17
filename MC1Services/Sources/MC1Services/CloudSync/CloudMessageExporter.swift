import Foundation

// MARK: - Read surface

/// The complete persistence surface CloudSync export requires: two lookups,
/// both read-only.
///
/// Declared here rather than reusing `ContactPersisting` / `ChannelPersisting`
/// because those protocols also carry `saveContact`, `deleteContact`,
/// `saveChannel`, `deleteChannel`, and the unread-count mutators. Depending on
/// them would hand the exporter write access it must never use. This protocol is
/// the structural proof of Sprint 1A's read-only rule: there is no write method
/// in scope for the exporter to call, and no route from here to
/// `MessageService`, `ChatSendQueueService`, `PendingSend`, `MeshCoreSession`,
/// or any transport.
///
/// `PersistenceStore` already satisfies both requirements through its existing
/// public conformances, so the conformance below adds no implementation and
/// touches no upstream file.
public protocol CloudSyncMessageReading: Actor {
  /// Resolves a direct message's peer. From `ContactPersisting`.
  func fetchContact(id: UUID) async throws -> ContactDTO?

  /// Resolves a channel message's channel. From `ChannelPersisting`.
  func fetchChannel(radioID: UUID, index: UInt8) async throws -> ChannelDTO?
}

extension PersistenceStore: CloudSyncMessageReading {}

// MARK: - Errors

/// Why a `MessageDTO` could not be turned into a portable record.
///
/// Every case is a refusal to emit a record rather than a silent fallback. A
/// malformed record would be indistinguishable from a real history entry once it
/// reached another device, so ambiguity fails loudly here instead.
public enum CloudMessageExportError: Error, Equatable, Sendable {
  /// Neither `contactID` nor `channelIndex` was set, so the message belongs to
  /// no conversation.
  case missingConversation(messageID: UUID)

  /// Both `contactID` and `channelIndex` were set. MC1 treats these as mutually
  /// exclusive (`Message.isChannelMessage` is `channelIndex != nil`), so a row
  /// carrying both is corrupt and its conversation cannot be determined.
  case ambiguousConversation(messageID: UUID)

  /// The referenced contact row is gone, so the peer public key — the whole
  /// basis of portable DM identity — cannot be resolved.
  case contactNotFound(contactID: UUID)

  /// The contact's public key is not the protocol's 32 bytes, so it cannot serve
  /// as cryptographic identity.
  case invalidPeerPublicKey(contactID: UUID, byteCount: Int)
}

// MARK: - Exporter

/// Converts MC1 history rows into portable ``CloudMessageRecord`` values.
///
/// Read-only by construction: it holds a ``CloudSyncMessageReading`` and nothing
/// else, performs no writes, and produces a value. Exporting a message has no
/// effect on the MC1 database and cannot cause a MeshCore transmission.
///
/// Identity follows the accepted Sprint 0 model:
///
/// - **Incoming** entries get a content fingerprint over portable identities, so
///   two installs that independently received the same packet converge.
/// - **Outgoing** entries get an origin fingerprint over the local `Message.id`,
///   because an outgoing message has exactly one author. This keeps two
///   deliberate identical sends distinct, and keeps a resend stable even though
///   `resendDirectMessage` re-stamps `Message.timestamp`.
public struct CloudMessageExporter: Sendable {
  private let store: any CloudSyncMessageReading

  public init(store: any CloudSyncMessageReading) {
    self.store = store
  }

  /// Builds the portable record for one history row.
  ///
  /// - Throws: ``CloudMessageExportError`` when the row's conversation cannot be
  ///   resolved unambiguously. Never throws for a well-formed row.
  public func export(_ message: MessageDTO) async throws -> CloudMessageRecord {
    let conversation = try await resolveConversation(for: message)
    let direction: CloudMessageDirection = message.isOutgoing ? .outgoing : .incoming

    // The uncorrected sender clock value, which is what two installs agree on.
    // `MessageDTO.reactionTimestamp` is exactly `senderTimestamp ?? timestamp`;
    // reusing it keeps CloudSync aligned with the choice MC1 already makes for
    // reaction matching rather than restating the rule.
    let wireTimestamp = message.reactionTimestamp

    let fingerprint = fingerprint(
      for: message,
      conversation: conversation,
      wireTimestamp: wireTimestamp
    )

    return CloudMessageRecord(
      fingerprint: fingerprint,
      conversation: conversation,
      direction: direction,
      text: message.text,
      wireTimestamp: wireTimestamp,
      senderNodeName: message.senderNodeName,
      isRead: message.isRead,
      originMessageID: message.isOutgoing ? message.id : nil
    )
  }

  // MARK: Conversation resolution

  private func resolveConversation(for message: MessageDTO) async throws -> CloudConversationIdentity {
    switch (message.contactID, message.channelIndex) {
    case let (contactID?, nil):
      guard let contact = try await store.fetchContact(id: contactID) else {
        throw CloudMessageExportError.contactNotFound(contactID: contactID)
      }
      guard contact.publicKey.count == ProtocolLimits.publicKeySize else {
        throw CloudMessageExportError.invalidPeerPublicKey(
          contactID: contactID,
          byteCount: contact.publicKey.count
        )
      }
      return .direct(peerPublicKey: contact.publicKey)

    case let (nil, channelIndex?):
      // No local Channel row for this slot — MC1 persists such messages because
      // the firmware attributes zero-key group traffic to the first empty slot
      // (`SyncCoordinator.shouldPostChannelNotification(forResolvedChannel:)`).
      // Fall back to the same weak slot identity an empty-secret channel gets,
      // rather than refusing to export. Losing history because a Channel row is
      // missing is worse than carrying an honestly-labelled weak identity, and
      // no secret is invented here: the record says "slot N", nothing more.
      guard let channel = try await store.fetchChannel(
        radioID: message.radioID,
        index: channelIndex
      ) else {
        return .channelSlot(channelIndex)
      }
      return .channel(secret: channel.secret, slotIndex: channel.index)

    case (nil, nil):
      throw CloudMessageExportError.missingConversation(messageID: message.id)

    case (_?, _?):
      throw CloudMessageExportError.ambiguousConversation(messageID: message.id)
    }
  }

  // MARK: Fingerprinting

  private func fingerprint(
    for message: MessageDTO,
    conversation: CloudConversationIdentity,
    wireTimestamp: UInt32
  ) -> String {
    // One author, so the origin row id is the identity — regardless of which
    // kind of conversation it lives in.
    guard !message.isOutgoing else {
      return CloudMessageFingerprint.outgoing(originMessageID: message.id)
    }

    switch conversation {
    case let .direct(peerPublicKey):
      return CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: peerPublicKey,
        wireTimestamp: wireTimestamp,
        text: message.text
      )

    case let .channelSecret(secret):
      // Slot is irrelevant once a stable secret exists; pass 0 to make that
      // explicit rather than threading an index the fingerprint will ignore.
      return CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: secret,
        channelIndex: 0,
        senderNodeName: message.senderNodeName,
        wireTimestamp: wireTimestamp,
        text: message.text
      )

    case let .channelSlot(index):
      // No stable secret: the fingerprint falls back to slot identity on the
      // same predicate that produced this case.
      return CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Data(),
        channelIndex: index,
        senderNodeName: message.senderNodeName,
        wireTimestamp: wireTimestamp,
        text: message.text
      )
    }
  }
}
