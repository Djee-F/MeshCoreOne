import Foundation

// MARK: - Delay injection

/// Injectable delay, so coalescing and retry timing are deterministic in tests.
///
/// Without this the scheduler's behaviour could only be observed by waiting real
/// wall-clock time, which is exactly the kind of timing race that makes a suite
/// flaky. Production uses ``CloudSyncTaskSleeper``; tests use
/// ``CloudSyncImmediateSleeper``.
public protocol CloudSyncSleeping: Sendable {
  /// Suspends for `duration`, or throws `CancellationError` if cancelled.
  func sleep(for duration: Duration) async throws
}

/// Real time.
public struct CloudSyncTaskSleeper: CloudSyncSleeping {
  public init() {}

  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

/// No time at all. Preserves cancellation semantics so cancellation paths are
/// still exercised.
public struct CloudSyncImmediateSleeper: CloudSyncSleeping {
  public init() {}

  public func sleep(for _: Duration) async throws {
    try Task.checkCancellation()
  }
}

// MARK: - Change monitoring

/// Detects that the selected folder *may* have changed.
///
/// # Deliberately contentless
///
/// The stream element is `Void`. A monitor cannot leak message text, a
/// fingerprint, a radio ID, a peer key, or a channel secret, because it has
/// nothing to leak — that is structural, not a matter of discipline. It also
/// keeps the contract honest: filesystem and iCloud notifications are *hints*,
/// never a trustworthy statement about which logical message changed, so the
/// only sound reaction is to re-read the directory.
///
/// # Lifetime is the stream's lifetime
///
/// Observation starts when the returned stream is first consumed and stops when
/// the consuming task is cancelled or the stream is dropped. Expressing it this
/// way — rather than as `start()`/`stop()` bookkeeping — is what makes duplicate
/// observers structurally impossible: one consuming task means one observer.
///
/// A monitor never imports anything. Reconciliation belongs to
/// ``CloudMessageFolderTransport`` and the accepted
/// ``CloudMessageSyncCoordinator``, and there is exactly one such path.
public protocol CloudSyncFolderChangeMonitoring: Sendable {
  /// A stream of "the folder may have changed" hints.
  func changeSignals() -> AsyncStream<Void>
}

// MARK: - Periodic monitor

/// Emits a hint on a fixed, deliberately slow interval.
///
/// This is the correctness floor, not the primary mechanism. Event delivery for
/// a user-selected external folder depends on the file provider actually
/// reporting changes; when it does not — provider offline, query yielding
/// nothing on this OS/account configuration — a slow tick still converges both
/// installations. It is the reason automatic sync cannot silently stop working.
///
/// The interval is intentionally coarse. A full pass re-reads the directory, so
/// frequent polling would cost real work for a folder that usually has not
/// changed; immediacy is the metadata monitor's job.
public struct CloudSyncPeriodicFolderMonitor: CloudSyncFolderChangeMonitoring {
  /// Conservative default. Foreground activation and the metadata monitor
  /// provide immediacy; this only guarantees eventual convergence.
  public static let defaultInterval: Duration = .seconds(300)

  private let interval: Duration
  private let sleeper: any CloudSyncSleeping

  public init(
    interval: Duration = defaultInterval,
    sleeper: any CloudSyncSleeping = CloudSyncTaskSleeper()
  ) {
    self.interval = interval
    self.sleeper = sleeper
  }

  public func changeSignals() -> AsyncStream<Void> {
    let interval = interval
    let sleeper = sleeper
    return AsyncStream { continuation in
      let task = Task {
        // Sleeps first: startup and foreground reconciliation already cover
        // "just became active", so an immediate tick would only duplicate them.
        while !Task.isCancelled {
          do {
            try await sleeper.sleep(for: interval)
          } catch {
            break
          }
          guard !Task.isCancelled else { break }
          continuation.yield(())
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

// MARK: - Composite monitor

/// Merges several monitors into one stream.
///
/// Used so an event-driven monitor and the periodic floor can run together
/// without the scheduler learning about either. Duplicate hints across monitors
/// are expected and harmless: the scheduler coalesces, and reconciliation is
/// idempotent.
public struct CloudSyncCompositeFolderMonitor: CloudSyncFolderChangeMonitoring {
  private let monitors: [any CloudSyncFolderChangeMonitoring]

  public init(_ monitors: [any CloudSyncFolderChangeMonitoring]) {
    self.monitors = monitors
  }

  public func changeSignals() -> AsyncStream<Void> {
    let monitors = monitors
    return AsyncStream { continuation in
      let parent = Task {
        await withTaskGroup(of: Void.self) { group in
          for monitor in monitors {
            group.addTask {
              for await _ in monitor.changeSignals() {
                continuation.yield(())
              }
            }
          }
        }
        continuation.finish()
      }
      // Cancelling the parent cancels the group, which terminates every child
      // stream and therefore every underlying observer.
      continuation.onTermination = { _ in parent.cancel() }
    }
  }
}

// MARK: - Test seam

/// A monitor driven by explicit calls, for deterministic tests.
///
/// Lets a test reproduce burst notifications, reordered notifications, and
/// notifications that arrive before a file is readable, with no timers, no
/// iCloud, and no real filesystem events.
public final class CloudSyncManualFolderMonitor: CloudSyncFolderChangeMonitoring, @unchecked Sendable {
  // `NSLock` rather than an actor so `emit()` stays synchronous and a test can
  // deliver a burst without interleaving suspension points, and rather than
  // `Mutex` so this file introduces no import the rest of the package lacks.
  private let lock = NSLock()
  private var continuation: AsyncStream<Void>.Continuation?

  public init() {}

  public func changeSignals() -> AsyncStream<Void> {
    AsyncStream { continuation in
      lock.withLock { self.continuation = continuation }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        lock.withLock { self.continuation = nil }
      }
    }
  }

  /// Emits one hint. Ignored when nothing is observing.
  public func emit() {
    lock.withLock { continuation }?.yield(())
  }

  /// Emits `count` hints back to back, reproducing a notification burst.
  public func emitBurst(_ count: Int) {
    for _ in 0..<count { emit() }
  }

  /// Whether a consumer is currently observing.
  public var isObserved: Bool {
    lock.withLock { continuation != nil }
  }
}
