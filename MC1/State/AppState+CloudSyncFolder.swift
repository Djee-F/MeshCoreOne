import Foundation
import MC1Services

// MARK: - Message history synchronization (folder transport)

/// App-facing control of the folder leg of message-history synchronization.
///
/// Everything here is best-effort and non-throwing. History synchronization is a
/// convenience layered on top of MC1; it must never be able to fail a send,
/// block the UI, or lose a local row.
extension AppState {
  /// Attaches the transport to the session and publishes initial state.
  ///
  /// Called once during startup. Attaching is unconditional: with no folder
  /// chosen the transport is inert, so there is no configured/unconfigured
  /// branch to keep in step, and choosing a folder later needs no re-wiring.
  func startCloudSyncTransport() async {
    await cloudSyncSession.setUploader(cloudSyncTransport)
    await refreshCloudSyncStatus()
    await reconcileCloudSyncFolder()
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
  /// Guarded against overlap so a foreground bounce or an impatient tap cannot
  /// stack passes. The transport is an actor and would serialize them anyway;
  /// this keeps the spinner honest.
  func reconcileCloudSyncFolder() async {
    guard !isCloudSyncReconciling else { return }
    isCloudSyncReconciling = true
    defer { isCloudSyncReconciling = false }

    let summary = await cloudSyncTransport.reconcile()
    cloudSyncLastSummary = summary
    await refreshCloudSyncStatus()

    // New rows landed, so the conversation lists have to be told; they read
    // SwiftData directly and have no way to notice an actor's writes.
    if summary.observationsInserted > 0 || summary.observationsUpdated > 0 {
      services?.syncCoordinator.notifyConversationsChanged()
    }
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
    await refreshCloudSyncStatus()
    await reconcileCloudSyncFolder()
    return true
  }

  /// Stops using the folder.
  ///
  /// Drops this device's access only: nothing in the folder is deleted, and no
  /// local message history is touched. Other devices keep what they already have.
  func disconnectCloudSyncFolder() async {
    await cloudSyncFolderStore.forget()
    cloudSyncLastSummary = nil
    await refreshCloudSyncStatus()
  }
}
