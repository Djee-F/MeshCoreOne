import Foundation
import MC1Services

// MARK: - Message history synchronization (folder transport)

/// App-facing control of the folder leg of message-history synchronization.
///
/// Everything here is best-effort and non-throwing. History synchronization is a
/// convenience layered on top of MC1; it must never be able to fail a send,
/// block the UI, or lose a local row.
///
/// # Lifecycle model
///
/// While the app is **active**, a folder-change monitor reconciles automatically.
/// While it is **suspended**, nothing runs — iOS makes no promise to wake an app
/// for changes in a user-selected folder, and this app requests no background
/// modes and schedules no background tasks. On the **next foreground** a full
/// pass catches up. Because every pass re-reads the whole directory and
/// importing is idempotent, time spent suspended costs latency only.
extension AppState {
  /// Attaches the transport to the session, starts change observation, and
  /// publishes initial state.
  ///
  /// Called once during startup. Attaching is unconditional: with no folder
  /// chosen the transport is inert and the monitor produces nothing, so there is
  /// no configured/unconfigured branch to keep in step.
  func startCloudSyncTransport() async {
    await cloudSyncSession.setUploader(cloudSyncTransport)
    await installCloudSyncObserver()
    await startCloudSyncMonitoring()
    await refreshCloudSyncStatus()
    await reconcileCloudSyncFolder()
  }

  /// Routes every reconciliation pass — automatic or manual — back into
  /// main-actor state.
  ///
  /// Automatic passes do not originate here, so without this the conversation
  /// lists would not learn that history arrived.
  private func installCloudSyncObserver() async {
    await cloudSyncScheduler.setObserver { [weak self] summary in
      await self?.applyCloudSyncPass(summary)
    }
  }

  /// Begins (or restarts) folder-change observation.
  ///
  /// `start(monitor:)` cancels any previous observation first, so repeated
  /// calls — reselecting a folder, another activation — can never leave two
  /// observers running.
  private func startCloudSyncMonitoring() async {
    // Nothing to watch without a folder, and the periodic floor would otherwise
    // wake the app every few minutes forever to discover that. Selecting a
    // folder calls back here, so this is not a state to get stuck in.
    guard await cloudSyncFolderStore.isConfigured else {
      await cloudSyncScheduler.stop()
      return
    }

    // An event-driven monitor for immediacy, composed with a deliberately slow
    // periodic floor so convergence never depends on a notification arriving.
    let monitor = CloudSyncCompositeFolderMonitor([
      CloudSyncMetadataFolderMonitor(folderProvider: cloudSyncFolderStore),
      CloudSyncPeriodicFolderMonitor(),
    ])
    await cloudSyncScheduler.start(monitor: monitor)
  }

  /// Applies one pass's outcome to observable state.
  func applyCloudSyncPass(_ summary: CloudMessageReconciliationSummary) async {
    cloudSyncLastSummary = summary
    await refreshCloudSyncStatus()

    // New rows landed, so the conversation lists have to be told; they read
    // SwiftData directly and have no way to notice an actor's writes.
    if summary.observationsInserted > 0 || summary.observationsUpdated > 0 {
      services?.syncCoordinator.notifyConversationsChanged()
    }
  }

  /// Re-reads the transport's view of the folder into main-actor state.
  func refreshCloudSyncStatus() async {
    let status = await cloudSyncTransport.refreshStatus()
    let name = await cloudSyncFolderStore.folderName
    cloudSyncStatus = status
    cloudSyncFolderName = name
  }

  /// Pulls whatever other devices have written into the folder.
  ///
  /// Runs through the scheduler rather than the transport directly, so the
  /// user's Sync Now and any in-flight automatic pass share one funnel and one
  /// serialization point. The flag drives the spinner only; overlap is already
  /// impossible because the transport is an actor.
  func reconcileCloudSyncFolder() async {
    guard !isCloudSyncReconciling else { return }
    isCloudSyncReconciling = true
    defer { isCloudSyncReconciling = false }

    await cloudSyncScheduler.reconcileNow()
  }

  /// Records the folder the user picked in the file importer.
  ///
  /// - Returns: Whether the choice could be stored.
  @discardableResult
  func selectCloudSyncFolder(_ url: URL) async -> Bool {
    guard await cloudSyncFolderStore.remember(url) else {
      await refreshCloudSyncStatus()
      return false
    }
    // The previous observation watched the previous folder; restart so exactly
    // one observer exists and it is watching the folder now in use.
    await startCloudSyncMonitoring()
    await refreshCloudSyncStatus()
    await reconcileCloudSyncFolder()
    return true
  }

  /// Stops using the folder.
  ///
  /// Drops this device's access only: nothing in the folder is deleted, and no
  /// local message history is touched. Other devices keep what they already
  /// have. Stopping the scheduler also cancels any pending download re-check and
  /// releases the monitor's security-scoped access.
  func disconnectCloudSyncFolder() async {
    await cloudSyncScheduler.stop()
    await cloudSyncFolderStore.forget()
    cloudSyncLastSummary = nil
    await refreshCloudSyncStatus()
  }
}
