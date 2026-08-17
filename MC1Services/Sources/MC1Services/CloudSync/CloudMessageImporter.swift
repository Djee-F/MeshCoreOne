import Foundation

// MARK: - Write surface

/// The complete persistence surface CloudSync import requires.
///
/// Import is allowed to write **history**; it is never allowed to create **send
/// work**. That distinction is enforced structurally here rather than by
/// convention: the only two mutating members are ``saveMessage(_:)`` and
/// ``markMessageAsRead(id:)``. `upsertPendingSend`, `insertPendingSendAssigningSequence`,
/// `updateMessageStatus`, `updateMessageAck`, and every other send-machinery
/// mutator are deliberately absent, so no code path reachable from
/// ``CloudMessageImporter`` can enqueue a transmission. There is likewise no
/// route to `MessageService`, `ChatSendQueueService`, `MeshCoreSession`, or any
/// transport.
///
/// `PersistenceStore` already satisfies every requirement through its existing
/// public API, so the conformance below adds no implementation and touches no
/// upstream file.
public protocol CloudSyncMessageImporting: Actor {
  // MARK: Reads

  /// Resolves a portable DM peer to a local contact by **full** 32-byte public
  /// key. The peer's `Contact.id` differs per install and is never used.
  func fetchContact(radioID: UUID, publicKey: Data) async throws -> ContactDTO?

  /// All local channels for the radio, so a portable channel secret can be
  /// matched to whatever slot it occupies locally.
  func fetchChannels(radioID: UUID) async throws -> [ChannelDTO]

  /// Resolves a weak slot identity against the local slot map.
  func fetchChannel(radioID: UUID, index: UInt8) async throws -> ChannelDTO?

  /// Looks up a row by local id — used only for outgoing records, whose portable
  /// identity *is* the originating install's `Message.id`.
  func fetchMessage(id: UUID) async throws -> MessageDTO?

  /// Narrow candidate window for reconciling an incoming DM against existing
  /// local history.
  func fetchDMMessageCandidates(
    radioID: UUID,
    contactID: UUID,
    timestampWindow: ClosedRange<UInt32>,
    limit: Int
  ) async throws -> [MessageDTO]

  /// Narrow candidate window for reconciling an incoming channel message.
  func fetchChannelMessageCandidates(
    radioID: UUID,
    channelIndex: UInt8,
    timestampWindow: ClosedRange<UInt32>,
    limit: Int
  ) async throws -> [MessageDTO]

  // MARK: Writes — history only

  /// Inserts a history row. Cannot enqueue a send: `PendingSend` is a separate
  /// table with its own mutators, none of which are in this protocol.
  func saveMessage(_ dto: MessageDTO) async throws

  /// Monotonic read-state merge. Only ever writes `isRead = true`, so CloudSync
  /// can never turn a read message back into unread.
  func markMessageAsRead(id: UUID) async throws
}

extension PersistenceStore: CloudSyncMessageImporting {}

// MARK: - Import context

/// Local placement metadata the portable record deliberately does not carry.
///
/// `CloudMessageRecord` contains no `radioID` because a radio identifier is
/// local to an install and means nothing across devices. An imported `Message`
/// row nonetheless needs one, so the caller states it explicitly rather than
/// letting the importer infer it from a fingerprint, a public key, a channel
/// secret, or a fresh UUID.
///
/// This is placement, not identity: the same record imported into two stores
/// lands under two different `targetRadioID`s and still exports back to one
/// portable fingerprint.
public struct CloudMessageImportContext: Sendable, Equatable, Hashable {
  /// The local radio partition the imported history should belong to.
  public let targetRadioID: UUID

  public init(targetRadioID: UUID) {
    self.targetRadioID = targetRadioID
  }
}

// MARK: - Outcome

/// What importing a record actually did.
public enum CloudMessageImportOutcome: Sendable, Equatable, Hashable {
  /// A new history row was created.
  case inserted(messageID: UUID)

  /// The record already existed locally and nothing changed.
  case alreadyPresent(messageID: UUID)

  /// The record already existed and portable mutable state was merged into it —
  /// currently only an `isRead` upgrade from `false` to `true`.
  case updatedExisting(messageID: UUID)

  /// The local row this record maps to, whatever happened to it.
  public var messageID: UUID {
    switch self {
    case let .inserted(id), let .alreadyPresent(id), let .updatedExisting(id): id
    }
  }
}

// MARK: - Errors

/// Why a record could not be imported.
///
/// Every case is a refusal rather than a silent repair. A record whose identity
/// fields contradict each other cannot be reconciled safely, and guessing would
/// put a wrong row into a user's history permanently.
///
/// - Note: No case carries message text, a public key, or a channel secret.
///   These values end up in logs and crash reports.
public enum CloudMessageImportError: Error, Equatable, Sendable {
  /// The record was written by a format this build does not understand. Never
  /// treated as version 1 — see ``CloudMessageRecord/currentFormatVersion``.
  case unsupportedFormatVersion(Int)

  /// The supplied fingerprint does not match the one recomputed from the
  /// record's own portable fields, so the record is internally inconsistent or
  /// was tampered with. Deliberately carries no payload.
  case fingerprintMismatch

  /// An outgoing record carries no `originMessageID`, which *is* its identity.
  case missingOriginMessageID

  /// An incoming record carries an `originMessageID`. Incoming identity is
  /// content-derived and the originating install's local row id must never
  /// travel, so this is a contradiction rather than a harmless extra field.
  case unexpectedOriginMessageID

  /// A direct record's peer key is not the protocol's 32 bytes.
  case invalidPeerPublicKey(byteCount: Int)

  /// No local contact holds that peer public key on the target radio. The
  /// importer will not fabricate a contact: the record carries only a key, with
  /// no name, type, or flags, so any row it created would be an invention.
  case unresolvedContact

  /// No local channel holds that secret on the target radio. Strong channel
  /// identity is not silently downgraded to a slot guess.
  case unresolvedChannel

  /// A local row already occupies the outgoing record's `originMessageID` but is
  /// not that message. `Message.id` is `@Attribute(.unique)`, so inserting would
  /// upsert and destroy the existing row.
  case localIDCollision(messageID: UUID)
}

// MARK: - Importer

/// Merges portable ``CloudMessageRecord`` values into a local MC1 store.
///
/// # The one invariant that matters
///
/// Import writes **history**. It never creates **send work**. An imported
/// outgoing message is a record of something another installation already sent,
/// not a transmission this device owes. Accordingly the importer never creates a
/// `PendingSend`, never touches `ChatSendQueueService`, and stores outgoing
/// history in a terminal, non-actionable state.
///
/// # Identity
///
/// Reconciliation keys on the portable fingerprint, never on a foreign local
/// UUID. The fingerprint is **recomputed** from the record's own fields and
/// compared to the supplied value before anything is written, so an internally
/// inconsistent record is rejected rather than merged.
public struct CloudMessageImporter: Sendable {
  /// How many local rows to examine when reconciling an incoming record.
  /// Candidates are already narrowed to one conversation and one exact wire
  /// timestamp, so this bound is generous; it exists to keep a pathological
  /// same-second burst from unbounded work.
  static let candidateLimit = 50

  private let store: any CloudSyncMessageImporting

  public init(store: any CloudSyncMessageImporting) {
    self.store = store
  }

  /// Imports one record into the local store.
  ///
  /// - Throws: ``CloudMessageImportError`` when the record is unsupported,
  ///   internally inconsistent, or cannot be placed in a local conversation.
  @discardableResult
  public func `import`(
    _ record: CloudMessageRecord,
    into context: CloudMessageImportContext
  ) async throws -> CloudMessageImportOutcome {
    // Validate the record on its own terms first, so a malformed record never
    // reaches the database.
    try Self.validateFormat(record)
    try Self.validateFingerprint(record)

    let placement = try await resolvePlacement(for: record, in: context)

    if let existing = try await findExistingMessage(for: record, placement: placement, in: context) {
      return try await mergeReadState(of: existing, from: record)
    }

    let dto = makeMessageDTO(for: record, placement: placement, in: context)
    try await store.saveMessage(dto)
    return .inserted(messageID: dto.id)
  }

  // MARK: - Record validation

  private static func validateFormat(_ record: CloudMessageRecord) throws {
    guard record.formatVersion == CloudMessageRecord.currentFormatVersion else {
      throw CloudMessageImportError.unsupportedFormatVersion(record.formatVersion)
    }
  }

  /// Recomputes identity from the record's portable fields and rejects any
  /// mismatch, so the conversation identity and the fingerprint can never
  /// disagree about what this record is.
  private static func validateFingerprint(_ record: CloudMessageRecord) throws {
    let expected: String

    switch record.direction {
    case .outgoing:
      guard let originMessageID = record.originMessageID else {
        throw CloudMessageImportError.missingOriginMessageID
      }
      expected = CloudMessageFingerprint.outgoing(originMessageID: originMessageID)

    case .incoming:
      // Incoming identity is content-derived; a foreign local row id has no
      // business travelling with it.
      guard record.originMessageID == nil else {
        throw CloudMessageImportError.unexpectedOriginMessageID
      }

      switch record.conversation {
      case let .direct(peerPublicKey):
        guard peerPublicKey.count == ProtocolLimits.publicKeySize else {
          throw CloudMessageImportError.invalidPeerPublicKey(byteCount: peerPublicKey.count)
        }
        expected = CloudMessageFingerprint.incomingDirectMessage(
          peerPublicKey: peerPublicKey,
          wireTimestamp: record.wireTimestamp,
          text: record.text
        )

      case let .channelSecret(secret):
        expected = CloudMessageFingerprint.incomingChannelMessage(
          channelSecret: secret,
          channelIndex: 0,
          senderNodeName: record.senderNodeName,
          wireTimestamp: record.wireTimestamp,
          text: record.text
        )

      case let .channelSlot(index):
        expected = CloudMessageFingerprint.incomingChannelMessage(
          channelSecret: Data(),
          channelIndex: index,
          senderNodeName: record.senderNodeName,
          wireTimestamp: record.wireTimestamp,
          text: record.text
        )
      }
    }

    guard expected == record.fingerprint else {
      throw CloudMessageImportError.fingerprintMismatch
    }
  }

  // MARK: - Local placement

  /// Where a record lands in the local database: a contact, or a channel slot.
  private enum LocalPlacement {
    case direct(contactID: UUID)
    case channel(index: UInt8)
  }

  private func resolvePlacement(
    for record: CloudMessageRecord,
    in context: CloudMessageImportContext
  ) async throws -> LocalPlacement {
    switch record.conversation {
    case let .direct(peerPublicKey):
      guard peerPublicKey.count == ProtocolLimits.publicKeySize else {
        throw CloudMessageImportError.invalidPeerPublicKey(byteCount: peerPublicKey.count)
      }
      // Full-key match only. Prefixes, names, and nicknames are not identity,
      // and the peer's `Contact.id` on the source install means nothing here.
      guard let contact = try await store.fetchContact(
        radioID: context.targetRadioID,
        publicKey: peerPublicKey
      ) else {
        throw CloudMessageImportError.unresolvedContact
      }
      return .direct(contactID: contact.id)

    case let .channelSecret(secret):
      // Strong identity: find whichever local slot holds this secret. The source
      // install's slot is irrelevant and is never read from the fingerprint.
      guard let channel = try await store.fetchChannels(radioID: context.targetRadioID)
        .first(where: { $0.secret == secret })
      else {
        throw CloudMessageImportError.unresolvedChannel
      }
      return .channel(index: channel.index)

    case let .channelSlot(index):
      // Weak identity: the record asserts only "slot N on the originating
      // install". Place it at the same local slot without upgrading it to a
      // secret, inventing a Channel row, or claiming the conversations match.
      //
      // A missing local Channel row is not a failure. MC1 itself persists
      // channel messages for slots it has no Channel for — `Message` carries a
      // bare `channelIndex` with no foreign key, and
      // `fetchMessages(radioID:channelIndex:)` reads it directly — so preserving
      // the history this way is consistent with existing behaviour rather than a
      // new invention.
      return .channel(index: index)
    }
  }

  // MARK: - Reconciliation against existing local history

  private func findExistingMessage(
    for record: CloudMessageRecord,
    placement: LocalPlacement,
    in context: CloudMessageImportContext
  ) async throws -> MessageDTO? {
    switch record.direction {
    case .outgoing:
      // Outgoing identity is the origin row id, so the lookup is exact — on the
      // originating install this finds the very row the record was exported
      // from, and on any other install it finds a previous import.
      guard let originMessageID = record.originMessageID,
            let existing = try await store.fetchMessage(id: originMessageID)
      else { return nil }

      // `Message.id` is unique store-wide. A row under that id that is not an
      // outgoing message is a genuine UUID collision, and inserting would upsert
      // it away.
      guard existing.direction == .outgoing else {
        throw CloudMessageImportError.localIDCollision(messageID: originMessageID)
      }
      return existing

    case .incoming:
      // Content-derived identity: narrow to this conversation at this exact wire
      // timestamp, then recompute each candidate's fingerprint under the same
      // rules the exporter uses.
      let window = record.wireTimestamp...record.wireTimestamp
      let candidates: [MessageDTO] = switch placement {
      case let .direct(contactID):
        try await store.fetchDMMessageCandidates(
          radioID: context.targetRadioID,
          contactID: contactID,
          timestampWindow: window,
          limit: Self.candidateLimit
        )
      case let .channel(index):
        try await store.fetchChannelMessageCandidates(
          radioID: context.targetRadioID,
          channelIndex: index,
          timestampWindow: window,
          limit: Self.candidateLimit
        )
      }

      return candidates.first { candidate in
        guard !candidate.isOutgoing else { return false }
        return Self.incomingFingerprint(for: candidate, conversation: record.conversation)
          == record.fingerprint
      }
    }
  }

  /// Recomputes a local row's cloud fingerprint under the record's conversation
  /// identity, mirroring `CloudMessageExporter` exactly.
  private static func incomingFingerprint(
    for candidate: MessageDTO,
    conversation: CloudConversationIdentity
  ) -> String {
    switch conversation {
    case let .direct(peerPublicKey):
      CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: peerPublicKey,
        wireTimestamp: candidate.reactionTimestamp,
        text: candidate.text
      )
    case let .channelSecret(secret):
      CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: secret,
        channelIndex: 0,
        senderNodeName: candidate.senderNodeName,
        wireTimestamp: candidate.reactionTimestamp,
        text: candidate.text
      )
    case let .channelSlot(index):
      CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Data(),
        channelIndex: index,
        senderNodeName: candidate.senderNodeName,
        wireTimestamp: candidate.reactionTimestamp,
        text: candidate.text
      )
    }
  }

  // MARK: - Mutable state merge

  /// Monotonic OR: a record may turn unread into read, never the reverse.
  private func mergeReadState(
    of existing: MessageDTO,
    from record: CloudMessageRecord
  ) async throws -> CloudMessageImportOutcome {
    guard record.isRead, !existing.isRead else {
      return .alreadyPresent(messageID: existing.id)
    }
    try await store.markMessageAsRead(id: existing.id)
    return .updatedExisting(messageID: existing.id)
  }

  // MARK: - Row construction

  /// Builds the local row for a newly imported record.
  ///
  /// Portable fields come from the record. Every local, runtime, and derived
  /// field is set to a safe inert value rather than copied or guessed, so
  /// imported history can never look like it is mid-flight:
  ///
  /// - `status` is terminal. Incoming uses `.delivered`, matching what
  ///   `SyncCoordinator` persists for live incoming messages. Outgoing uses
  ///   `.sent` — the weakest truthful claim, since the record asserts the origin
  ///   composed and dispatched the message but carries no delivery evidence.
  ///   `.pending`, `.sending`, and `.retrying` are excluded because they imply
  ///   active send ownership; `.sent` is inert here because send work is driven
  ///   solely by `PendingSend` rows (`ChatSendQueueService.hydrate`) and ACK
  ///   expiry runs off the in-memory `pendingAcks` table, which an imported row
  ///   never enters.
  /// - `ackCode`, `roundTripTime`, `retryAttempt`, `maxRetryAttempts`,
  ///   `heardRepeats` stay empty: send telemetry belongs to the originating
  ///   device.
  /// - `pathLength`, `pathNodes`, `snr`, `routeType`, `regionScope`,
  ///   `senderKeyPrefix` stay empty: this device received no packet, so
  ///   populating reception metadata would be fabrication.
  /// - `deduplicationKey` stays `nil` on purpose. It is MC1's *live-radio* dedup
  ///   key; leaving it unset guarantees cloud import cannot suppress a message
  ///   the radio later delivers for real. The cost is a possible visible
  ///   duplicate if the same message also arrives live, which is strictly safer
  ///   than the alternative failure mode of silently dropping live traffic.
  /// - `containsSelfMention` stays `false`: it derives from the local node name,
  ///   which is per-radio and may differ from the originating install's.
  /// - `replyToID`, `reactionSummary`, and link previews stay empty — deferred.
  private func makeMessageDTO(
    for record: CloudMessageRecord,
    placement: LocalPlacement,
    in context: CloudMessageImportContext
  ) -> MessageDTO {
    let contactID: UUID?
    let channelIndex: UInt8?
    switch placement {
    case let .direct(id):
      contactID = id
      channelIndex = nil
    case let .channel(index):
      contactID = nil
      channelIndex = index
    }

    // Outgoing history keeps the originating install's row id as its local id:
    // it is already globally unique, it makes re-import idempotent, and it lets
    // the originating device recognize its own row. Incoming history has no
    // portable id, so a fresh local one is minted.
    let localID = record.originMessageID ?? UUID()

    // The record carries no local ordering, so both dates derive from the wire
    // timestamp. Deterministic (re-importing yields identical values) and
    // ordered by the sender's clock. Limitation: MC1's live path sets
    // `createdAt`/`sortDate` from local receive time precisely because sender
    // clocks skew, so imported history can sort oddly against locally received
    // history when a sender's clock is wrong.
    let wireDate = Date(timeIntervalSince1970: TimeInterval(record.wireTimestamp))

    return MessageDTO(
      id: localID,
      radioID: context.targetRadioID,
      contactID: contactID,
      channelIndex: channelIndex,
      text: record.text,
      timestamp: record.wireTimestamp,
      createdAt: wireDate,
      sortDate: wireDate,
      direction: record.direction == .outgoing ? .outgoing : .incoming,
      status: record.direction == .outgoing ? .sent : .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      pathNodes: nil,
      senderKeyPrefix: nil,
      senderNodeName: record.senderNodeName,
      isRead: record.isRead,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      sendCount: 1,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      deduplicationKey: nil,
      linkPreviewURL: nil,
      linkPreviewTitle: nil,
      linkPreviewImageData: nil,
      linkPreviewIconData: nil,
      linkPreviewFetched: false,
      containsSelfMention: false,
      mentionSeen: false,
      timestampCorrected: false,
      senderTimestamp: nil,
      reactionSummary: nil,
      routeType: nil,
      regionScope: nil
    )
  }
}
