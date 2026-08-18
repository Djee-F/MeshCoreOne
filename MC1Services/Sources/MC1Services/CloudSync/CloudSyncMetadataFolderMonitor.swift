import Foundation

/// Event-driven change detection for the user-selected folder, via
/// `NSMetadataQuery`.
///
/// # Why this scope, specifically
///
/// `NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope` (iOS 8+) is
/// documented as *"documents from outside the application's container that are
/// accessible without user interaction"*, and its results carry security-scoped
/// URLs. That is precisely this architecture: a folder the user picked in the
/// document browser, reopened from a bookmark, living in **their** iCloud Drive
/// rather than in an app ubiquity container.
///
/// The two sibling scopes are the wrong ones and are deliberately not used:
/// `NSMetadataQueryUbiquitousDocumentsScope` and `…UbiquitousDataScope` search
/// *the application's own* ubiquity container, which this app does not have, does
/// not want, and could not obtain without an iCloud entitlement and a paid
/// membership. Nothing here calls `url(forUbiquityContainerIdentifier:)`.
///
/// # Not trusted for correctness
///
/// Whether a file provider reports another device's changes promptly — or at all
/// — depends on the provider, the account, and the OS. This monitor is therefore
/// treated as an *accelerator*, never as the guarantee: it is composed with
/// ``CloudSyncPeriodicFolderMonitor`` and with the app's startup and foreground
/// passes, so convergence never depends on a notification arriving. A hint that
/// never comes costs latency; it cannot cost history.
///
/// # Materialization
///
/// Download-status changes are themselves query updates, so a document that
/// arrives as a placeholder and materialises later produces a hint at the moment
/// its contents become readable. That is the cheap path for
/// ``CloudMessageReconciliationSummary/pendingDownloads``; the scheduler's timed
/// re-check remains as the floor when no such hint arrives.
///
/// # Security scope
///
/// The query observes a security-scoped URL, so access is opened for the
/// observation's whole lifetime and closed exactly once when it ends — including
/// when the consuming task is cancelled. There is one acquire and one release
/// per observation, and no path that leaves a scope open.
public struct CloudSyncMetadataFolderMonitor: CloudSyncFolderChangeMonitoring {
  private let folderProvider: any CloudSyncFolderProviding

  public init(folderProvider: any CloudSyncFolderProviding) {
    self.folderProvider = folderProvider
  }

  public func changeSignals() -> AsyncStream<Void> {
    let folderProvider = folderProvider
    return AsyncStream { continuation in
      let query = MetadataQueryHolder()

      let starter = Task { @MainActor in
        await query.start(folderProvider: folderProvider) {
          continuation.yield(())
        }
      }

      continuation.onTermination = { _ in
        starter.cancel()
        Task { @MainActor in await query.stop() }
      }
    }
  }
}

// MARK: - Query holder

/// Owns the `NSMetadataQuery`, its notification observers, and the folder's
/// security-scoped access.
///
/// `@MainActor` because `NSMetadataQuery` is driven by a run loop and is
/// conventionally started and stopped on the main thread; results are delivered
/// to `operationQueue`. Neither `NSMetadataQuery` nor `NSObjectProtocol`
/// observers are `Sendable`, so confining them to one actor is also what makes
/// this type safe to reference from the stream's termination handler.
@MainActor
private final class MetadataQueryHolder {
  private var query: NSMetadataQuery?
  private var observers: [any NSObjectProtocol] = []
  private var scopedFolder: URL?
  private var folderProvider: (any CloudSyncFolderProviding)?

  /// `nonisolated` so the stream's (non-isolated) builder can create the holder
  /// and hand the same reference to both the start task and the termination
  /// handler. Every stored property starts empty, so no isolated state is
  /// touched here; all real work stays on the main actor.
  nonisolated init() {}

  func start(
    folderProvider: any CloudSyncFolderProviding,
    onChange: @escaping @Sendable () -> Void
  ) async {
    guard query == nil else { return }

    guard let folder = await folderProvider.acquireFolder() else { return }
    // Cancelled between acquiring and starting: release rather than leak.
    guard !Task.isCancelled else {
      await folderProvider.releaseFolder(folder)
      return
    }
    self.folderProvider = folderProvider
    scopedFolder = folder

    let messages = folder.appendingPathComponent(
      CloudMessageDirectoryStore.messagesDirectoryName, isDirectory: true
    )

    let query = NSMetadataQuery()
    // Documents the user granted us, outside any container of ours.
    query.searchScopes = [NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
    // Constrain to the chosen folder so the query never observes — or reports —
    // anything the user did not select.
    query.searchItems = [messages]
    query.predicate = NSPredicate(
      format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.\(CloudMessageDirectoryStore.fileExtension)"
    )
    // Watching download status is what turns "a placeholder materialised" into a
    // hint rather than a silent wait.
    query.valueListAttributes = [NSMetadataUbiquitousItemDownloadingStatusKey]

    let center = NotificationCenter.default
    // Both are hints with identical meaning here: re-read the directory. The
    // query's own result set is deliberately never consulted — reading it would
    // be a second, weaker source of truth than the directory itself.
    for name in [
      NSNotification.Name.NSMetadataQueryDidFinishGathering,
      NSNotification.Name.NSMetadataQueryDidUpdate,
    ] {
      observers.append(
        center.addObserver(forName: name, object: query, queue: nil) { _ in onChange() }
      )
    }

    self.query = query
    query.start()
  }

  func stop() async {
    query?.stop()
    query = nil

    let center = NotificationCenter.default
    for observer in observers { center.removeObserver(observer) }
    observers.removeAll()

    if let scopedFolder, let folderProvider {
      await folderProvider.releaseFolder(scopedFolder)
    }
    scopedFolder = nil
    folderProvider = nil
  }
}
