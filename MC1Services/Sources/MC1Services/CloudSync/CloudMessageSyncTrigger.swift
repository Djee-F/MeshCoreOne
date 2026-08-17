import Foundation

// MARK: - Trigger

/// A **local-origin** history change worth handing to CloudSync.
///
/// # Why "local-origin" is in the name of the game
///
/// The dangerous failure mode for this layer is a feedback loop:
///
/// ```
/// cloud import ──► persistence ──► event ──► export ──► cloud import ──► …
/// ```
///
/// This type exists only to carry changes that a *local* actor caused — the
/// radio delivering a packet, the user composing a message, the user marking
/// something read. A change applied by ``CloudMessageImporter`` must never
/// become a trigger.
///
/// That property is **structural**, not a runtime check: `CloudMessageImporter`
/// holds a ``CloudSyncMessageImporting`` store and nothing else, and CloudSync
/// contains no reference to `SyncCoordinator`, `EventBroadcaster`, or any MC1
/// event stream (references in CloudSync are documentation only). There is
/// therefore no code path by which an import can produce a `SyncDataEvent`, a
/// `MessageStatusEvent`, or a value of this type. No flags, delays, timestamp
/// heuristics, or "ignore the next event" logic are used or needed.
public enum CloudMessageSyncTrigger: Sendable, Equatable {
  /// A message became local history on this device: received over the radio,
  /// or composed by the user.
  ///
  /// Carries the persisted `MessageDTO`, so the row is known to exist and can
  /// be exported without a second fetch.
  case messagePersisted(MessageDTO)

  /// A local action marked a message read.
  ///
  /// Carries only the id: read state is reconciled by re-exporting the current
  /// row, so a stale snapshot of the message would be actively unhelpful.
  case messageRead(messageID: UUID)

  // MARK: Adapting MC1's existing events

  /// Translates one of MC1's existing post-persistence data events into a
  /// trigger, or `nil` when the event is not about message history.
  ///
  /// Incoming messages need **no new upstream event**: `SyncCoordinator` already
  /// broadcasts `.directMessageReceived` and `.channelMessageReceived` *after*
  /// `saveMessage` (`SyncCoordinator+MessageHandlers.swift:254` then `:286`;
  /// `SyncCoordinator+HandlerHelpers.swift:152`), and both carry the full
  /// `MessageDTO`. Both are emitted only from the radio-ingestion path, so a
  /// cloud import can never produce one.
  ///
  /// Duplicate delivery is harmless: reconciliation is idempotent, and the same
  /// logical message arriving on two radios legitimately produces two events
  /// that converge on one fingerprint.
  public static func from(_ event: SyncDataEvent) -> CloudMessageSyncTrigger? {
    switch event {
    case let .directMessageReceived(message, _):
      .messagePersisted(message)
    case let .channelMessageReceived(message, _):
      .messagePersisted(message)
    case .contactsChanged, .conversationsChanged, .roomMessageReceived, .reactionReceived:
      // Room messages use a separate model with its own dedup key and are out of
      // scope; reactions and list-refresh signals are not message history.
      nil
    }
  }
}

/// Descriptions carry identifiers and sizes, never message text.
extension CloudMessageSyncTrigger: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    switch self {
    case let .messagePersisted(message):
      "messagePersisted(id: \(message.id), direction: \(message.isOutgoing ? "outgoing" : "incoming"), "
        + "textBytes: \(message.text.utf8.count))"
    case let .messageRead(messageID):
      "messageRead(id: \(messageID))"
    }
  }

  public var debugDescription: String { description }
}

// MARK: - Driver

/// Turns local-origin triggers into CloudSync reconciliation.
///
/// A thin translation layer: it owns no algorithm of its own. Eligibility,
/// conversation resolution, fingerprinting, and every write stay in
/// ``CloudMessageSyncCoordinator`` and the primitives beneath it.
///
/// # What it deliberately does not do
///
/// - It does not decide which radios participate — the caller passes them, per
///   the policy accepted in Sprints 1C/1D.
/// - It does not subscribe to anything. Wiring a `SyncCoordinator.dataEvents()`
///   stream (or any other source) to this driver belongs to the app layer, so
///   this type stays testable and free of application lifetime concerns.
/// - It never touches the send path. A CloudSync failure here cannot fail,
///   delay, or roll back a radio transmission, because the send workflow does
///   not await this driver at all.
public struct CloudMessageSyncDriver: Sendable {
  private let coordinator: CloudMessageSyncCoordinator
  private let store: any CloudSyncMessageStore

  public init(store: any CloudSyncMessageStore) {
    self.store = store
    coordinator = CloudMessageSyncCoordinator(store: store)
  }

  /// Handles one local-origin trigger.
  ///
  /// - Returns: The reconciliation outcome, or `nil` when there was nothing to
  ///   do — currently only when a ``CloudMessageSyncTrigger/messageRead(messageID:)``
  ///   names a row that no longer exists, which is a benign race rather than an
  ///   error.
  /// - Throws: ``CloudMessageExportError`` if the row cannot be exported (for
  ///   example its contact was deleted), or ``CloudMessageImportError`` if the
  ///   record is malformed. Both surface before any write.
  @discardableResult
  public func handle(
    _ trigger: CloudMessageSyncTrigger,
    across radioIDs: [UUID]
  ) async throws -> CloudMessageSyncOutcome? {
    switch trigger {
    case let .messagePersisted(message):
      return try await coordinator.synchronizeLocalMessage(message, across: radioIDs)

    case let .messageRead(messageID):
      // Re-read rather than trusting a snapshot: the whole point of this trigger
      // is that `isRead` just changed, and the current row is the truth.
      guard let message = try await store.fetchMessage(id: messageID) else {
        return nil
      }
      return try await coordinator.synchronizeLocalMessage(message, across: radioIDs)
    }
  }

  /// Convenience for a caller already holding one of MC1's data events.
  ///
  /// Returns `nil` for events that are not message history, so a subscriber can
  /// forward its whole stream without filtering first.
  @discardableResult
  public func handle(
    _ event: SyncDataEvent,
    across radioIDs: [UUID]
  ) async throws -> CloudMessageSyncOutcome? {
    guard let trigger = CloudMessageSyncTrigger.from(event) else { return nil }
    return try await handle(trigger, across: radioIDs)
  }
}
