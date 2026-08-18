import Foundation
import MC1Services
import OSLog

/// Remembers the folder the user chose for message-history synchronization, and
/// re-opens access to it on later launches.
///
/// # Why a bookmark
///
/// `.fileImporter` hands back a URL whose access is *security-scoped* and does
/// not survive relaunch. A bookmark is the system's supported way to reopen the
/// same location later without asking again. The alternative — storing a path —
/// does not work: the sandbox denies access to a path the user has not granted,
/// and iCloud Drive paths are not stable.
///
/// # Deliberately device-local
///
/// The bookmark is written to `UserDefaults` under a `com.pocketmesh.` key and is
/// **not** registered in `BackupUserDefaults`, whose allowlist is an explicit
/// property list. That is the intent, not an oversight: a bookmark encodes a
/// grant made by one user on one device, so carrying it into a restore on
/// another device would at best resolve to nothing and at worst point somewhere
/// the user never chose. A restored install asks for the folder again.
///
/// # Access discipline
///
/// `startAccessingSecurityScopedResource()` is reference-counted, so every
/// `acquireFolder()` must be paired with exactly one `releaseFolder(_:)`.
/// ``CloudMessageFolderTransport`` owns that pairing.
///
/// - Note: No iCloud entitlement, container, or account is involved. This works
///   with any folder the user can reach in the file picker — an iCloud Drive
///   folder is simply the one that syncs.
actor CloudSyncFolderBookmarkStore: CloudSyncFolderProviding {
  private static let logger = Logger(subsystem: "com.mc1", category: "CloudSyncFolder")

  /// Bookmark blob. Intentionally absent from `BackupUserDefaults`.
  static let bookmarkKey = "com.pocketmesh.cloudSyncFolderBookmark"

  /// Last known folder name, kept separately so the settings screen can label
  /// the row without resolving the bookmark and taking a security scope.
  static let folderNameKey = "com.pocketmesh.cloudSyncFolderName"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Configuration

  /// Whether a folder has been chosen. Says nothing about reachability.
  var isConfigured: Bool {
    defaults.data(forKey: Self.bookmarkKey) != nil
  }

  /// The chosen folder's display name, for the settings row.
  var folderName: String? {
    defaults.string(forKey: Self.folderNameKey)
  }

  /// Records the folder the user picked. Returns whether it could be stored.
  ///
  /// The picker's URL arrives security-scoped, so access is opened for the
  /// duration of bookmark creation and closed immediately afterwards.
  @discardableResult
  func remember(_ url: URL) -> Bool {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    // `.withSecurityScope` is macOS-only (`API_UNAVAILABLE(ios)`); on iOS a
    // plain bookmark of a picker-granted URL already carries the grant.
    guard let data = try? url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil
    ) else {
      Self.logger.error("Could not create a bookmark for the selected folder")
      return false
    }

    defaults.set(data, forKey: Self.bookmarkKey)
    defaults.set(url.lastPathComponent, forKey: Self.folderNameKey)
    return true
  }

  /// Forgets the folder.
  ///
  /// Drops this app's access only. Nothing in the folder is read, moved, or
  /// deleted — history already synchronized to other devices stays where it is,
  /// and local history is untouched.
  func forget() {
    defaults.removeObject(forKey: Self.bookmarkKey)
    defaults.removeObject(forKey: Self.folderNameKey)
  }

  // MARK: - CloudSyncFolderProviding

  func acquireFolder() async -> URL? {
    guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }

    var isStale = false
    guard let url = try? URL(
      resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale
    ) else {
      // Kept rather than cleared: an unresolvable bookmark is usually a folder
      // that is temporarily away (an unmounted provider, iCloud still starting),
      // and discarding the user's choice on a transient failure is worse than
      // reporting the folder as unavailable until it comes back.
      Self.logger.notice("Sync folder bookmark did not resolve; treating as unavailable")
      return nil
    }

    guard url.startAccessingSecurityScopedResource() else {
      Self.logger.notice("Sync folder resolved but access was refused")
      return nil
    }

    // Refreshing requires the scope to be held, so it happens here rather than
    // before the access call.
    if isStale, let refreshed = try? url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil
    ) {
      defaults.set(refreshed, forKey: Self.bookmarkKey)
      defaults.set(url.lastPathComponent, forKey: Self.folderNameKey)
    }

    return url
  }

  func releaseFolder(_ url: URL) async {
    url.stopAccessingSecurityScopedResource()
  }
}
