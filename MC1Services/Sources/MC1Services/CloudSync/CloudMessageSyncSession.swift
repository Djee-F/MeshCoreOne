import Foundation

// MARK: - Radio participation

/// Supplies the radios whose local histories take part in synchronization.
///
/// Kept as a provider so the domain policy can change later without touching the
/// fingerprint, record, importer, or router layers.
public protocol CloudSyncRadioProviding: Sendable {
  /// The radios participating right now. Consulted per trigger, so the answer
  /// tracks radios being paired or removed without restarting the session.
  func participatingRadioIDs() async -> [UUID]
}

/// A provider that returns a fixed list. Test and preview seam.
public struct CloudSyncStaticRadioProvider: CloudSyncRadioProviding {
  private let radioIDs: [UUID]

  public init(radioIDs: [UUID]) {
    self.radioIDs = radioIDs
  }

  public func participatingRadioIDs() async -> [UUID] { radioIDs }
}

/// Device enumeration for the CloudSync domain policy.
///
/// Declared here rather than reusing `DevicePersisting` — which has no
/// enumeration member — and rather than adding one upstream. `fetchAllDevices()`
/// is already public on `PersistenceStore`, so the conformance below is empty and
/// touches no upstream file.
public protocol CloudSyncDeviceEnumerating: Actor {
  func fetchAllDevices() async throws -> [DeviceDTO]
}

extension PersistenceStore: CloudSyncDeviceEnumerating {}

/// The accepted Sprint 1F domain policy: **all locally known/persisted radios
/// participate in CloudSync history reconciliation.**
///
/// The domain is every distinct `radioID` across persisted `Device` rows.
/// Deliberately *not* filtered by `Device.isActive` and *not* filtered by BLE
/// connection state: each persisted radio is one local observation domain, and
/// history convergence has to keep working while a radio is offline or out of
/// range.
///
/// - Important: This says nothing about availability. A `Device` row means the
///   radio is *locally known*, not that it is connected, reachable, or even still
///   in the user's possession. It is a persistence-domain policy only.
///
/// A later sprint may make participation user-selectable; because the policy
/// lives behind ``CloudSyncRadioProviding``, doing so requires no change to the
/// fingerprint, record, importer, or router layers.
public struct CloudSyncPersistedRadioProvider: CloudSyncRadioProviding {
  private let store: any CloudSyncDeviceEnumerating

  public init(store: any CloudSyncDeviceEnumerating) {
    self.store = store
  }

  /// Distinct radio IDs across all persisted devices, sorted for determinism.
  ///
  /// A read failure yields an empty domain rather than throwing: the caller is a
  /// best-effort trigger path, and refusing to reconcile is always safer than
  /// reconciling against a partial domain.
  public func participatingRadioIDs() async -> [UUID] {
    guard let devices = try? await store.fetchAllDevices() else { return [] }
    // Two Device rows can share a radioID (for example a re-paired radio whose
    // surrogate id was re-minted), so de-duplicate before returning.
    return Set(devices.map(\.radioID)).sorted { $0.uuidString < $1.uuidString }
  }
}

// MARK: - Session

/// Owns the lifetime of local-history synchronization: one long-lived object
/// that consumes MC1's incoming-message events and accepts explicit local-action
/// triggers from app call sites.
///
/// # Why this exists as its own type
///
/// The pieces below it (``CloudMessageSyncDriver``, ``CloudMessageSyncCoordinator``)
/// are stateless value types. Something has to own a subscription task, guarantee
/// it starts once, and survive radio reconnects — and that something must **not**
/// be `ServiceContainer`, which MC1 rebuilds and tears down on every BLE
/// connection (`ConnectionManager+Lifecycle.swift:679`, `ServiceContainer.tearDown()`).
/// Tying synchronization lifetime to one BLE connection would make history sync
/// stop when a radio goes out of range.
///
/// The correct scope is the one that owns the `ModelContainer` — app scope. This
/// type is that owner's collaborator, kept in MC1Services so it is unit-testable
/// without SwiftUI lifecycle machinery.
///
/// # Failure isolation
///
/// Every entry point is non-throwing. A CloudSync failure must never fail,
/// delay, or roll back a MeshCore send, and must never break MC1's event stream.
/// Failures are counted for diagnostics and otherwise dropped; nothing upstream
/// can observe them as an error.
///
/// # Loop safety
///
/// Only *local-origin* changes reach this type: MC1's radio-ingestion events, and
/// explicit calls from local action sites. `CloudMessageImporter` has no
/// reference to any event stream and no reference to this session, so a
/// cloud-applied change cannot re-enter. That is structural — there are no
/// suppression flags, delays, or timing heuristics anywhere in CloudSync.
public actor CloudMessageSyncSession {
  private let driver: CloudMessageSyncDriver
  private let radioProvider: any CloudSyncRadioProviding

  private var eventTask: Task<Void, Never>?

  /// Triggers that completed without throwing. Diagnostics only.
  public private(set) var processedTriggerCount: Int = 0

  /// Triggers that failed. Diagnostics only — a failure here is always
  /// non-fatal to the rest of MC1.
  public private(set) var failureCount: Int = 0

  /// Triggers that produced no work (for example a read trigger naming a row
  /// that no longer exists).
  public private(set) var skippedTriggerCount: Int = 0

  public init(store: any CloudSyncMessageStore, radioProvider: any CloudSyncRadioProviding) {
    driver = CloudMessageSyncDriver(store: store)
    self.radioProvider = radioProvider
  }

  // MARK: Subscription lifetime

  /// Whether an event subscription is currently running.
  public var isConsumingEvents: Bool { eventTask != nil }

  /// Begins consuming a `SyncDataEvent` stream.
  ///
  /// Idempotent: a second call while a subscription is live is ignored, so
  /// re-wiring on radio reconnect cannot create a duplicate subscriber. Call
  /// ``stop()`` first to deliberately replace the stream.
  ///
  /// The loop never terminates on a CloudSync failure — an error while handling
  /// one event must not stop the next event being processed.
  public func start(consuming events: AsyncStream<SyncDataEvent>) {
    guard eventTask == nil else { return }
    eventTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await handle(event)
      }
      await self?.clearFinishedTask()
    }
  }

  /// Cancels the subscription. Safe to call when none is running.
  public func stop() {
    eventTask?.cancel()
    eventTask = nil
  }

  private func clearFinishedTask() {
    eventTask = nil
  }

  // MARK: Event intake

  /// Handles one of MC1's data events. Non-history events are ignored.
  ///
  /// Public so a caller that already owns a stream can pump it directly, and so
  /// tests can drive the exact path production uses.
  public func handle(_ event: SyncDataEvent) async {
    guard let trigger = CloudMessageSyncTrigger.from(event) else { return }
    await run(trigger)
  }

  // MARK: Local action intake

  /// Reports that an outgoing message became local history.
  ///
  /// Call **after** the row is persisted and never in a way that gates the send:
  /// this method cannot throw, so a failure inside CloudSync is invisible to the
  /// send path by construction.
  ///
  /// - Important: Call this only for genuine new outgoing history — a user
  ///   composing a message. Do **not** call it for retries or resends (the
  ///   logical message already exists and its identity is unchanged), and do not
  ///   call it from reaction send paths: MC1 sends reactions through
  ///   `sendDirectMessage`/`sendChannelMessage`, which persist ordinary
  ///   `Message` rows that are row-level indistinguishable from chat messages.
  ///   The call site is the only reliable discriminator, so the filtering lives
  ///   there rather than in a text heuristic.
  public func recordLocalMessage(_ message: MessageDTO) async {
    await run(.messagePersisted(message))
  }

  /// Reports that a local action marked a message read.
  ///
  /// Call after the local mutation succeeds. Never called by
  /// `CloudMessageImporter`, which marks rows read through the store directly and
  /// has no reference to this session — so a cloud-applied read cannot re-enter.
  public func recordLocalRead(messageID: UUID) async {
    await run(.messageRead(messageID: messageID))
  }

  // MARK: Execution

  private func run(_ trigger: CloudMessageSyncTrigger) async {
    let radioIDs = await radioProvider.participatingRadioIDs()
    guard !radioIDs.isEmpty else {
      // No participating radios: nothing to reconcile against. Counted as
      // skipped rather than failed — an unconfigured domain is not an error.
      skippedTriggerCount += 1
      return
    }

    do {
      if try await driver.handle(trigger, across: radioIDs) == nil {
        skippedTriggerCount += 1
      } else {
        processedTriggerCount += 1
      }
    } catch {
      // Deliberately swallowed and un-logged: the error can carry no payload
      // worth surfacing here, and CloudSync failure is non-fatal to MC1 by
      // design. The counter is the diagnostic.
      failureCount += 1
    }
  }
}
