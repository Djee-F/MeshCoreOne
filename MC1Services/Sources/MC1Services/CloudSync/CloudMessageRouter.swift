import Foundation

// MARK: - Read surface

/// The persistence surface multi-radio *planning* requires.
///
/// Every member is a read. There is no write method in scope, so planning
/// structurally cannot mutate the database — that is the whole point of
/// separating reconciliation from execution. Execution delegates to
/// ``CloudMessageImporter``, which owns the (deliberately tiny) write surface.
///
/// `PersistenceStore` already satisfies every requirement through its existing
/// public API, so the conformance below adds no implementation and touches no
/// upstream file.
public protocol CloudSyncMessageRouting: Actor {
  /// Full-key contact lookup, per radio. Eligibility for a DM conversation.
  func fetchContact(radioID: UUID, publicKey: Data) async throws -> ContactDTO?

  /// All channels for a radio, so a portable secret can be matched to whatever
  /// slot it occupies there.
  func fetchChannels(radioID: UUID) async throws -> [ChannelDTO]

  /// Outgoing observation lookup. `Message.id` is unique store-wide.
  func fetchMessage(id: UUID) async throws -> MessageDTO?

  func fetchDMMessageCandidates(
    radioID: UUID,
    contactID: UUID,
    timestampWindow: ClosedRange<UInt32>,
    limit: Int
  ) async throws -> [MessageDTO]

  func fetchChannelMessageCandidates(
    radioID: UUID,
    channelIndex: UInt8,
    timestampWindow: ClosedRange<UInt32>,
    limit: Int
  ) async throws -> [MessageDTO]
}

extension PersistenceStore: CloudSyncMessageRouting {}

// MARK: - Placement

/// Where a logical message would sit in one radio's local database.
///
/// Local placement, never portable identity — this never enters
/// ``CloudMessageRecord``.
public enum CloudLocalPlacement: Sendable, Equatable, Hashable {
  case direct(contactID: UUID)
  case channel(index: UInt8)
}

// MARK: - Ineligibility

/// Why a radio cannot host a logical message.
public enum CloudRadioIneligibilityReason: Sendable, Equatable, Hashable {
  /// No contact on this radio holds the record's peer public key.
  case noContactWithPeerKey

  /// No channel on this radio holds the record's secret. A matching *slot*
  /// number is explicitly not a substitute.
  case noChannelWithSecret

  /// The record carries only weak ``CloudConversationIdentity/channelSlot(_:)``
  /// identity and this radio holds no observation of it.
  ///
  /// Slot equality is **not** evidence that two radios mean the same channel, so
  /// the router refuses to fan a weak record out on that basis. This is a
  /// deliberate refusal, not a missing capability: a caller that has independent
  /// grounds to place the record on a specific radio can still do so through
  /// `CloudMessageImporter.import(_:into:)`, whose Sprint 1B slot fallback
  /// remains valid for an explicitly chosen radio.
  case weakSlotIdentityNotPropagated

  /// The record is outgoing and this radio does not hold the single observation.
  ///
  /// An outgoing message has exactly one author, and its portable identity *is*
  /// the originating `Message.id`. `Message.id` is `@Attribute(.unique)`
  /// **store-wide** — MC1 states "messageID is globally unique across all
  /// radios" (`MessagePersisting`) — so one local database can hold at most one
  /// row for an outgoing record no matter how many radios are otherwise
  /// eligible. Fan-out is therefore impossible rather than merely unwise, and
  /// the router never proposes it. Placing outgoing history on a deliberately
  /// chosen radio stays available through `CloudMessageImporter` directly.
  case outgoingNotFannedOut
}

// MARK: - Per-radio decision

/// What the router concluded about one radio.
public enum CloudRadioRoutingState: Sendable, Equatable, Hashable {
  /// This radio already holds an observation of the logical message.
  ///
  /// Several radios may report this for one fingerprint. That is correct: a
  /// mesh message genuinely received by two radios produces two legitimate
  /// local rows, and neither is a duplicate to be deleted or merged.
  case existingObservation(messageID: UUID, placement: CloudLocalPlacement)

  /// The conversation exists on this radio but the logical message does not, so
  /// importing history here is permitted.
  case eligibleMissing(placement: CloudLocalPlacement)

  /// Importing here is not permitted.
  case notEligible(CloudRadioIneligibilityReason)

  /// Whether ``CloudMessageRouter`` may import this record onto this radio.
  public var permitsImport: Bool {
    if case .eligibleMissing = self { return true }
    return false
  }

  /// The local row when one exists.
  public var existingMessageID: UUID? {
    if case let .existingObservation(messageID, _) = self { return messageID }
    return nil
  }
}

/// One radio's decision.
public struct CloudRadioRoutingDecision: Sendable, Equatable, Hashable {
  public let radioID: UUID
  public let state: CloudRadioRoutingState

  public init(radioID: UUID, state: CloudRadioRoutingState) {
    self.radioID = radioID
    self.state = state
  }
}

// MARK: - Plan

/// A deterministic, read-only reconciliation plan for one logical message across
/// several local radios.
///
/// Produced without mutating anything. Holding a plan lets a future
/// orchestration layer see the whole picture — which radios already observed the
/// message, which may receive it, which are refused and why — before any write
/// happens.
public struct CloudMessageRoutingPlan: Sendable, Equatable {
  /// The logical message this plan concerns.
  public let fingerprint: String

  /// One decision per requested radio, in the order the caller supplied them.
  public let decisions: [CloudRadioRoutingDecision]

  public init(fingerprint: String, decisions: [CloudRadioRoutingDecision]) {
    self.fingerprint = fingerprint
    self.decisions = decisions
  }

  /// Radios that already hold an observation. More than one is normal and
  /// correct for a message two radios both received.
  public var existingObservations: [CloudRadioRoutingDecision] {
    decisions.filter { $0.state.existingMessageID != nil }
  }

  /// Radios the record may be imported onto.
  public var importableRadioIDs: [UUID] {
    decisions.filter(\.state.permitsImport).map(\.radioID)
  }
}

// MARK: - Execution result

/// What executing a plan did on one radio.
public struct CloudRadioImportResult: Sendable, Equatable, Hashable {
  public let radioID: UUID
  public let outcome: CloudMessageImportOutcome

  public init(radioID: UUID, outcome: CloudMessageImportOutcome) {
    self.radioID = radioID
    self.outcome = outcome
  }
}

// MARK: - Router

/// Reconciles one portable ``CloudMessageRecord`` against several local radios.
///
/// # The distinction this type exists to preserve
///
/// A `CloudMessageRecord` is **one logical message**. A `Message` row is **one
/// local observation** belonging to **one radio**. A mesh message received by two
/// radios is two legitimate rows sharing one fingerprint. The router reports
/// that as two observations; it never collapses them, never moves a row between
/// radios, and never overwrites one radio's reception metadata with another's.
///
/// # Planning and execution are separate
///
/// ``plan(for:across:)`` only reads. ``execute(_:of:using:)`` performs writes
/// exclusively through ``CloudMessageImporter``, so Sprint 1B's import
/// semantics — conversation resolution, fingerprint validation, monotonic
/// `isRead`, inert outgoing status, no `PendingSend` — are reused rather than
/// reimplemented.
///
/// # No transmission, ever
///
/// Nothing here can cause a MeshCore transmission. Planning holds a read-only
/// store; execution holds an importer whose write surface is `saveMessage` and
/// `markMessageAsRead` and nothing else.
public struct CloudMessageRouter: Sendable {
  private let store: any CloudSyncMessageRouting

  public init(store: any CloudSyncMessageRouting) {
    self.store = store
  }

  // MARK: Planning

  /// Builds the reconciliation plan for `record` across `radioIDs`.
  ///
  /// Performs **no database mutation**.
  ///
  /// - Parameter radioIDs: The locally available radios to consider. Supplied by
  ///   the caller rather than discovered here: deciding which radios count as
  ///   available (paired, active, currently connected) is orchestration policy
  ///   that belongs to a later sprint, and hard-coding one interpretation now
  ///   would bake a guess into the reconciliation layer.
  /// - Throws: ``CloudMessageImportError`` when the record is malformed, so a
  ///   plan is never produced for a record that could not be imported anyway.
  public func plan(
    for record: CloudMessageRecord,
    across radioIDs: [UUID]
  ) async throws -> CloudMessageRoutingPlan {
    // One validation implementation, shared with the importer.
    try CloudMessageImporter.validate(record)

    var decisions: [CloudRadioRoutingDecision] = []
    decisions.reserveCapacity(radioIDs.count)
    for radioID in radioIDs {
      decisions.append(
        CloudRadioRoutingDecision(
          radioID: radioID,
          state: try await state(for: record, on: radioID)
        )
      )
    }
    return CloudMessageRoutingPlan(fingerprint: record.fingerprint, decisions: decisions)
  }

  private func state(
    for record: CloudMessageRecord,
    on radioID: UUID
  ) async throws -> CloudRadioRoutingState {
    guard record.direction == .incoming else {
      return try await outgoingState(for: record, on: radioID)
    }

    switch record.conversation {
    case let .direct(peerPublicKey):
      // Eligibility is full-key contact membership. Contact.id, name, nickname,
      // key prefix, and the source radioID are all irrelevant.
      guard let contact = try await store.fetchContact(radioID: radioID, publicKey: peerPublicKey) else {
        return .notEligible(.noContactWithPeerKey)
      }
      let placement = CloudLocalPlacement.direct(contactID: contact.id)
      if let existing = try await existingIncomingObservation(
        of: record, on: radioID, placement: placement
      ) {
        return .existingObservation(messageID: existing, placement: placement)
      }
      return .eligibleMissing(placement: placement)

    case let .channelSecret(secret):
      // Strong identity: match the secret, adopt whatever slot holds it here.
      // A matching slot number with a different secret is not a match.
      guard let channel = try await store.fetchChannels(radioID: radioID)
        .first(where: { $0.secret == secret })
      else {
        return .notEligible(.noChannelWithSecret)
      }
      let placement = CloudLocalPlacement.channel(index: channel.index)
      if let existing = try await existingIncomingObservation(
        of: record, on: radioID, placement: placement
      ) {
        return .existingObservation(messageID: existing, placement: placement)
      }
      return .eligibleMissing(placement: placement)

    case let .channelSlot(index):
      // Weak identity. Recognizing an observation already sitting at this slot is
      // safe — it asserts nothing new. Proposing an import is not: slot equality
      // is not evidence that two radios mean the same channel, so this case can
      // never become `.eligibleMissing`.
      let placement = CloudLocalPlacement.channel(index: index)
      if let existing = try await existingIncomingObservation(
        of: record, on: radioID, placement: placement
      ) {
        return .existingObservation(messageID: existing, placement: placement)
      }
      return .notEligible(.weakSlotIdentityNotPropagated)
    }
  }

  /// Outgoing records are recognized, never fanned out. See
  /// ``CloudRadioIneligibilityReason/outgoingNotFannedOut`` for why the store-wide
  /// uniqueness of `Message.id` makes this the only coherent behaviour.
  private func outgoingState(
    for record: CloudMessageRecord,
    on radioID: UUID
  ) async throws -> CloudRadioRoutingState {
    guard let originMessageID = record.originMessageID,
          let existing = try await store.fetchMessage(id: originMessageID),
          existing.direction == .outgoing,
          existing.radioID == radioID
    else {
      return .notEligible(.outgoingNotFannedOut)
    }

    let placement: CloudLocalPlacement = if let channelIndex = existing.channelIndex {
      .channel(index: channelIndex)
    } else if let contactID = existing.contactID {
      .direct(contactID: contactID)
    } else {
      // A row with neither is malformed local state; report the observation
      // without inventing a placement it does not have.
      .channel(index: 0)
    }
    return .existingObservation(messageID: existing.id, placement: placement)
  }

  /// Finds an incoming observation of `record` on one radio, using the importer's
  /// fingerprint recomputation so router and importer can never disagree.
  private func existingIncomingObservation(
    of record: CloudMessageRecord,
    on radioID: UUID,
    placement: CloudLocalPlacement
  ) async throws -> UUID? {
    let window = record.wireTimestamp...record.wireTimestamp
    let candidates: [MessageDTO] = switch placement {
    case let .direct(contactID):
      try await store.fetchDMMessageCandidates(
        radioID: radioID,
        contactID: contactID,
        timestampWindow: window,
        limit: CloudMessageImporter.candidateLimit
      )
    case let .channel(index):
      try await store.fetchChannelMessageCandidates(
        radioID: radioID,
        channelIndex: index,
        timestampWindow: window,
        limit: CloudMessageImporter.candidateLimit
      )
    }

    return candidates.first { candidate in
      guard !candidate.isOutgoing else { return false }
      return CloudMessageImporter.incomingFingerprint(
        for: candidate,
        conversation: record.conversation
      ) == record.fingerprint
    }?.id
  }

  // MARK: Execution

  /// Applies a plan by delegating every write to ``CloudMessageImporter``.
  ///
  /// Radios marked ``CloudRadioRoutingState/notEligible(_:)`` are skipped, so a
  /// weak-slot record never fans out and an outgoing record never multiplies.
  /// Radios with an existing observation are still passed to the importer so a
  /// monotonic `isRead` upgrade reaches every local copy; the importer leaves all
  /// other radio-local metadata untouched.
  ///
  /// - Returns: One result per radio actually visited, in plan order.
  @discardableResult
  public func execute(
    _ plan: CloudMessageRoutingPlan,
    of record: CloudMessageRecord,
    using importer: CloudMessageImporter
  ) async throws -> [CloudRadioImportResult] {
    var results: [CloudRadioImportResult] = []
    for decision in plan.decisions {
      switch decision.state {
      case .notEligible:
        continue
      case .existingObservation, .eligibleMissing:
        let outcome = try await importer.import(
          record,
          into: CloudMessageImportContext(targetRadioID: decision.radioID)
        )
        results.append(CloudRadioImportResult(radioID: decision.radioID, outcome: outcome))
      }
    }
    return results
  }
}

// MARK: - Redacted descriptions

/// Routing types describe local placement, which is not secret, but they must not
/// echo portable identity material. Peer public keys and channel secrets never
/// appear here, and neither does message text.
extension CloudLocalPlacement: CustomStringConvertible {
  public var description: String {
    switch self {
    case .direct: "direct(contact: <local>)"
    case let .channel(index): "channel(slot: \(index))"
    }
  }
}

extension CloudRadioRoutingState: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .existingObservation(_, placement): "existingObservation(\(placement))"
    case let .eligibleMissing(placement): "eligibleMissing(\(placement))"
    case let .notEligible(reason): "notEligible(\(reason))"
    }
  }
}

extension CloudMessageRoutingPlan: CustomStringConvertible {
  public var description: String {
    "CloudMessageRoutingPlan(\(fingerprint), radios: \(decisions.count), "
      + "existing: \(existingObservations.count), importable: \(importableRadioIDs.count))"
  }
}
