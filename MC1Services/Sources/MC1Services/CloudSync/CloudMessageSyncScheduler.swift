import Foundation

/// Turns "the folder may have changed" hints into reconciliation passes.
///
/// # Why this exists separately from the transport
///
/// ``CloudMessageFolderTransport`` knows how to do one pass. It has no opinion
/// about *when*. This actor owns the when: it consumes a monitor, collapses
/// bursts, guarantees passes never overlap, and re-checks while iCloud is still
/// delivering file contents. Keeping those concerns apart is what lets the
/// transport stay a pure, synchronous-feeling operation that tests can call
/// directly.
///
/// # One reconciliation path
///
/// Every route into synchronization — a monitor hint, the periodic floor, the
/// pending-download retry, app activation, and the user's Sync Now — ends at the
/// same `transport.reconcile()`, which ends at the accepted
/// ``CloudMessageSyncCoordinator``. There is no second import algorithm and no
/// incremental shortcut: a hint is only ever a reason to re-read the directory,
/// never a statement about what changed.
///
/// # Lifecycle honesty
///
/// Observation runs only while the app is active. iOS offers no guarantee that a
/// suspended app is woken for changes in a user-selected folder, and this sprint
/// adds no background modes and no `BGTaskScheduler`. The model is therefore:
/// active → automatic; suspended → nothing; next foreground → a full pass that
/// catches up. Because every pass re-reads the whole directory and importing is
/// idempotent, missing an arbitrary number of changes while suspended costs
/// latency and nothing else.
/// Notified after every reconciliation pass, automatic or manual.
///
/// Carries only the coarse summary — counts, never content — so an observer
/// cannot become a side channel for message text or identity material.
public typealias CloudMessageReconciliationObserving =
  @Sendable (CloudMessageReconciliationSummary) async -> Void

public actor CloudMessageSyncScheduler {
  /// Window used to collapse a burst of hints into one pass. iCloud commonly
  /// reports a multi-file change as several notifications in quick succession.
  public static let defaultCoalescingWindow: Duration = .seconds(2)

  /// Delay before re-checking while documents are still downloading. Long
  /// enough that it can never become a busy-loop against the file provider.
  public static let defaultPendingDownloadRetryDelay: Duration = .seconds(20)

  private let transport: CloudMessageFolderTransport
  private let sleeper: any CloudSyncSleeping
  private let coalescingWindow: Duration
  private let pendingDownloadRetryDelay: Duration

  private var observationTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var passTask: Task<Void, Never>?
  private var observer: CloudMessageReconciliationObserving?

  private var isRunning = false
  /// Identifies the current observation. Bumped on every `start`, so hints from
  /// a superseded monitor are discarded by identity rather than by hoping
  /// cancellation wins a race — an `AsyncStream` can still deliver a value that
  /// was buffered before its consuming task was cancelled.
  private var observationEpoch = 0
  private var isReconciling = false
  /// A hint arrived while a pass was in flight, so one more pass is owed.
  private var isDirty = false

  // Diagnostics only. Counts, never content.
  public private(set) var reconcileCount = 0
  public private(set) var signalCount = 0
  public private(set) var retryScheduledCount = 0

  public init(
    transport: CloudMessageFolderTransport,
    sleeper: any CloudSyncSleeping = CloudSyncTaskSleeper(),
    coalescingWindow: Duration = defaultCoalescingWindow,
    pendingDownloadRetryDelay: Duration = defaultPendingDownloadRetryDelay
  ) {
    self.transport = transport
    self.sleeper = sleeper
    self.coalescingWindow = coalescingWindow
    self.pendingDownloadRetryDelay = pendingDownloadRetryDelay
  }

  /// Whether a monitor is currently being observed.
  public var isObserving: Bool { observationTask != nil }

  /// Installs the pass observer. Pass `nil` to remove it.
  ///
  /// Needed because automatic passes do not originate in the app layer: without
  /// this, history imported by a monitor hint would land in the database with no
  /// one told to refresh the conversation lists.
  public func setObserver(_ observer: CloudMessageReconciliationObserving?) {
    self.observer = observer
  }

  // MARK: - Lifetime

  /// Begins observing a monitor.
  ///
  /// Idempotent by replacement: an existing observation is cancelled first, so
  /// repeated calls — reselecting a folder, another foreground transition, a
  /// re-entrant startup path — can never leave two observers running. Exactly
  /// one observation task exists at any moment.
  public func start(monitor: any CloudSyncFolderChangeMonitoring) {
    stop()
    isRunning = true
    observationEpoch += 1
    let epoch = observationEpoch
    // Created here rather than inside the task so observation is established the
    // moment `start` returns. Building it in the task would leave a scheduling
    // gap in which hints are silently dropped.
    let signals = monitor.changeSignals()
    observationTask = Task { [weak self] in
      // `weak` so a discarded scheduler cannot be kept alive by its own
      // observation task, and so the stream drains rather than dangling.
      for await _ in signals {
        guard let self else { return }
        await self.handleSignal(epoch: epoch)
      }
    }
  }

  /// Stops observing and cancels any pending retry.
  ///
  /// Safe to call when nothing is running. After this the scheduler performs no
  /// further work until ``start(monitor:)`` is called again — which is what
  /// disconnecting the folder relies on.
  public func stop() {
    isRunning = false
    isDirty = false
    observationTask?.cancel()
    observationTask = nil
    retryTask?.cancel()
    retryTask = nil
  }

  // MARK: - Signals

  /// Records a hint and starts a pass if one is not already running.
  ///
  /// Ten hints for one file produce one pass — or two, when they straddle a pass
  /// already in flight — and never ten. Duplicate and out-of-order hints are
  /// therefore harmless by construction: order carries no meaning when the only
  /// reaction is to re-read everything.
  ///
  /// - Important: This **claims** the pass synchronously and then runs it in a
  ///   detached task, rather than awaiting it. Awaiting would defeat the whole
  ///   mechanism: the observation loop consumes hints one at a time, so a hint
  ///   that waited for its own reconciliation would let the next hint start a
  ///   fresh pass, and a burst of ten would produce ten passes instead of being
  ///   collapsed into one. Returning immediately is what lets the rest of the
  ///   burst land on the `isReconciling` guard below.
  public func handleSignal() {
    handleSignal(epoch: observationEpoch)
  }

  /// Handles a hint that claims to come from observation `epoch`.
  ///
  /// A hint from a superseded observation is dropped and not counted: after the
  /// folder is reselected or syncing is stopped, the previous monitor speaks for
  /// a folder this scheduler is no longer watching.
  private func handleSignal(epoch: Int) {
    guard epoch == observationEpoch else { return }
    signalCount += 1
    guard isRunning else { return }
    guard !isReconciling else {
      isDirty = true
      return
    }
    isReconciling = true
    passTask = Task { [weak self] in
      await self?.runCoalescedPasses()
    }
  }

  // MARK: - Reconciliation

  /// Runs a pass immediately, bypassing the coalescing window.
  ///
  /// This is the user's Sync Now and the app's activation pass. It does not skip
  /// serialization: `transport` is an actor, so this pass and any automatic pass
  /// are ordered with respect to each other and can never mutate concurrently.
  @discardableResult
  public func reconcileNow() async -> CloudMessageReconciliationSummary {
    let summary = await performPass()
    return summary
  }

  /// Runs passes until no hint arrived during the last one.
  ///
  /// The caller has already set `isReconciling`, which is what makes the claim
  /// atomic with respect to the hints still arriving behind it.
  private func runCoalescedPasses() async {
    defer {
      isReconciling = false
      passTask = nil
    }

    // Collapse the burst before doing any work. Hints arriving during this
    // window are absorbed by the `isReconciling` guard in `handleSignal()`.
    try? await sleeper.sleep(for: coalescingWindow)

    repeat {
      isDirty = false
      guard isRunning else { return }
      _ = await performPass()
    } while isDirty
  }

  /// One full pass through the accepted transport, plus retry bookkeeping.
  private func performPass() async -> CloudMessageReconciliationSummary {
    let summary = await transport.reconcile()
    reconcileCount += 1
    scheduleRetry(after: summary)
    await observer?(summary)
    return summary
  }

  // MARK: - Pending downloads

  /// Schedules at most one delayed re-check while iCloud is still delivering
  /// file contents.
  ///
  /// The transport has already asked for those downloads; this only arranges to
  /// look again once. Any previously scheduled retry is cancelled first, so a
  /// long stream of partially-downloaded passes produces one outstanding retry,
  /// never a growing pile, and never a tight loop against the file provider.
  private func scheduleRetry(after summary: CloudMessageReconciliationSummary) {
    retryTask?.cancel()
    retryTask = nil

    guard isRunning, summary.pendingDownloads > 0 else { return }
    retryScheduledCount += 1

    let delay = pendingDownloadRetryDelay
    let sleeper = sleeper
    retryTask = Task { [weak self] in
      do {
        try await sleeper.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      await self.handleSignal()
    }
  }

  /// Awaits any in-flight pass, for deterministic tests.
  ///
  /// Terminates because a pass clears `isReconciling` and `passTask` as it
  /// finishes; a hint that arrives during the pass is absorbed by `isDirty` and
  /// handled by that same pass's loop rather than by a new task.
  func awaitPassesForTesting() async {
    while isReconciling, let task = passTask {
      await task.value
    }
  }

  /// Awaits the currently scheduled retry, for deterministic tests.
  ///
  /// Production never calls this: the retry is fire-and-forget by design, and
  /// nothing in the app should ever block on iCloud delivering bytes.
  func awaitPendingRetryForTesting() async {
    await retryTask?.value
  }
}
