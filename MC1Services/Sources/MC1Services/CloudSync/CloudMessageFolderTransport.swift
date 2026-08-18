import Foundation

// MARK: - Folder access

/// Supplies the user-selected synchronization folder, with platform access
/// already established.
///
/// An abstraction rather than a concrete URL for two reasons. On iOS the folder
/// is reachable only inside a security-scoped access bracket resolved from a
/// bookmark, and that machinery belongs to the app layer — `MC1Services` must
/// stay free of UIKit and document-picker concepts. And it makes the whole
/// transport testable against an ordinary temporary directory, with no Apple ID,
/// no iCloud, and no picker interaction.
public protocol CloudSyncFolderProviding: Sendable {
  /// The configured folder with access started, or `nil` when no folder is
  /// configured or access has been revoked.
  ///
  /// A successful call must be balanced by ``releaseFolder(_:)``.
  func acquireFolder() async -> URL?

  /// Balances a successful ``acquireFolder()``.
  func releaseFolder(_ url: URL) async
}

/// A provider backed by a plain directory, for tests and previews.
public struct CloudSyncStaticFolderProvider: CloudSyncFolderProviding {
  private let url: URL?

  public init(url: URL?) { self.url = url }

  public func acquireFolder() async -> URL? { url }
  public func releaseFolder(_: URL) async {}
}

// MARK: - Status and summary

/// Coarse, user-presentable transport state. Carries nothing sensitive.
public enum CloudMessageTransportStatus: Sendable, Equatable {
  /// No folder has been chosen.
  case notConfigured
  /// A folder is configured and reachable.
  case ready(lastReconciled: Date?)
  /// A folder is configured but could not be reached — permission revoked,
  /// provider offline, or the folder removed.
  case unavailable
}

/// Coarse outcome of one reconciliation pass. Deliberately counts only: no file
/// names, no message content, no identity material.
public struct CloudMessageReconciliationSummary: Sendable, Equatable {
  /// Message documents the directory scan considered.
  public var filesExamined = 0
  /// Documents that decoded and validated.
  public var validRecords = 0
  /// Documents rejected as malformed, mismatched, or unsupported.
  public var rejectedRecords = 0
  /// Local observations created across all participating radios.
  public var observationsInserted = 0
  /// Local observations whose portable state was merged (read-state upgrade).
  public var observationsUpdated = 0
  /// Local observations already present and unchanged.
  public var observationsUnchanged = 0
  /// Records that could not be reconciled locally (for example an unresolved
  /// contact on every radio).
  public var recordsFailed = 0

  /// Documents present in the folder whose contents have not downloaded yet.
  /// A download was requested for each; the next pass picks them up. Not a
  /// failure, so it deliberately does not affect ``isClean``.
  public var pendingDownloads = 0

  public init() {}

  /// Whether the pass completed without rejecting or failing anything.
  public var isClean: Bool { rejectedRecords == 0 && recordsFailed == 0 }
}

// MARK: - Transport

/// Owns the folder-backed remote history transport: uploads local history and
/// reconciles remote history into every participating local radio.
///
/// # Serialization
///
/// An actor, so the operations that can arrive close together — a local message
/// trigger, a local read trigger, app-activation reconciliation, and
/// folder-selection reconciliation — are serialized. Two writes can never race
/// on one fingerprint file, and two full-directory passes cannot overlap.
///
/// # Failure isolation
///
/// Every entry point is non-throwing. Synchronization is optional: a missing
/// folder, revoked permission, offline provider, unreadable file, or failed
/// write must never fail a MeshCore send, never delete local history, and never
/// surface as an error to the send path.
///
/// # No transmission, ever
///
/// It reconciles through the accepted ``CloudMessageSyncCoordinator`` and owns
/// no send capability: there is no `PendingSend` mutator, no `MessageService`,
/// no `ChatSendQueueService`, and no transport session in scope.
public actor CloudMessageFolderTransport: CloudMessageRecordUploading {
  private let folderProvider: any CloudSyncFolderProviding
  private let coordinator: CloudMessageSyncCoordinator
  private let radioProvider: any CloudSyncRadioProviding

  private var lastReconciled: Date?
  private var lastKnownStatus: CloudMessageTransportStatus = .notConfigured

  /// Most recent reconciliation result, for status display and tests.
  public private(set) var lastSummary = CloudMessageReconciliationSummary()

  public init(
    folderProvider: any CloudSyncFolderProviding,
    coordinator: CloudMessageSyncCoordinator,
    radioProvider: any CloudSyncRadioProviding
  ) {
    self.folderProvider = folderProvider
    self.coordinator = coordinator
    self.radioProvider = radioProvider
  }

  public var status: CloudMessageTransportStatus { lastKnownStatus }

  // MARK: Local history -> remote file

  /// Exports a locally-persisted row and writes it to the folder.
  ///
  /// - Important: Call only from the accepted Sprint 1F semantic trigger sites.
  ///   This must never be driven by a scan of the message table: outgoing
  ///   reaction rows are row-level indistinguishable from ordinary outgoing
  ///   messages, so the call site remains the only sound discriminator.
  ///
  /// - Returns: `true` when the record reached the folder. A `false` is
  ///   informational only — never an error the caller should act on.
  @discardableResult
  public func uploadLocalMessage(_ message: MessageDTO) async -> Bool {
    guard let record = try? await coordinator.exportRecord(for: message) else { return false }
    return await upload(record)
  }

  /// Writes an already-portable record to the folder, idempotently.
  ///
  /// Reuses ``CloudMessageDirectoryStore`` for naming, atomic writes, immutable
  /// collision defence, and the monotonic `isRead` merge.
  @discardableResult
  public func upload(_ record: CloudMessageRecord) async -> Bool {
    guard let folder = await folderProvider.acquireFolder() else {
      lastKnownStatus = .notConfigured
      return false
    }
    defer { Task { await folderProvider.releaseFolder(folder) } }

    do {
      try CloudMessageDirectoryStore(root: folder).save(record)
      lastKnownStatus = .ready(lastReconciled: lastReconciled)
      return true
    } catch {
      // Deliberately swallowed and un-logged: the error can embed a path, and a
      // transport failure is non-fatal by design.
      lastKnownStatus = .unavailable
      return false
    }
  }

  // MARK: Remote files -> local history

  /// Reads every valid document in the folder and reconciles it into all
  /// participating local radios through the accepted engine.
  ///
  /// One malformed document never aborts the pass — `loadAll()` reports failures
  /// per file — and one record that cannot be placed locally never blocks the
  /// rest.
  ///
  /// **Deletion is never propagated.** A document missing from the folder does
  /// not remove local history; this pass only imports.
  @discardableResult
  public func reconcile() async -> CloudMessageReconciliationSummary {
    var summary = CloudMessageReconciliationSummary()

    guard let folder = await folderProvider.acquireFolder() else {
      lastKnownStatus = .notConfigured
      lastSummary = summary
      return summary
    }
    defer { Task { await folderProvider.releaseFolder(folder) } }

    let radioIDs = await radioProvider.participatingRadioIDs()
    let loaded = CloudMessageDirectoryStore(root: folder).loadAll()

    summary.filesExamined = loaded.records.count + loaded.failures.count
    summary.validRecords = loaded.records.count
    summary.rejectedRecords = loaded.failures.count
    summary.pendingDownloads = loaded.pendingDownloads

    // No participating radios yet: the folder was still read successfully, so
    // report reachable rather than unavailable.
    guard !radioIDs.isEmpty else {
      lastReconciled = Date()
      lastKnownStatus = .ready(lastReconciled: lastReconciled)
      lastSummary = summary
      return summary
    }

    for record in loaded.records {
      do {
        let outcome = try await coordinator.synchronize(record, across: radioIDs)
        summary.observationsInserted += outcome.insertedRadioIDs.count
        summary.observationsUpdated += outcome.updatedRadioIDs.count
        summary.observationsUnchanged += outcome.unchangedRadioIDs.count
        if !outcome.failures.isEmpty { summary.recordsFailed += 1 }
      } catch {
        // A record that cannot be placed locally (malformed, or no radio holds
        // its conversation) is counted and skipped, never fatal.
        summary.recordsFailed += 1
      }
    }

    lastReconciled = Date()
    lastKnownStatus = .ready(lastReconciled: lastReconciled)
    lastSummary = summary
    return summary
  }

  /// Refreshes reachability without importing, for status display after a
  /// folder is chosen or forgotten.
  @discardableResult
  public func refreshStatus() async -> CloudMessageTransportStatus {
    guard let folder = await folderProvider.acquireFolder() else {
      lastKnownStatus = .notConfigured
      return lastKnownStatus
    }
    await folderProvider.releaseFolder(folder)
    lastKnownStatus = .ready(lastReconciled: lastReconciled)
    return lastKnownStatus
  }
}
