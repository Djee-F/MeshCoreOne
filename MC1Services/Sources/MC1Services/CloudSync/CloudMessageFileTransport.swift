import Foundation

// MARK: - Errors

/// Why a message file could not be read or written.
///
/// Deliberately payload-free: no case carries message text, a peer key, a
/// channel secret, or a node name. This type is what callers log.
public enum CloudMessageFileTransportError: Error, Equatable, Sendable {
  /// The file name is not `<fingerprint>.json`, or the stem is not a legal
  /// fingerprint. Covers path traversal, conflict copies, and stray files.
  case invalidFileName
  /// The file's contents are not decodable JSON for this format.
  case malformedContent
  /// The record inside disagrees with the fingerprint in the file name, or with
  /// its own content. The file name is never trusted on its own.
  case fingerprintMismatch
  /// A record already exists under this fingerprint with different immutable
  /// content. The existing file is left untouched.
  case immutableContentConflict(fingerprint: String)
  /// The document is in iCloud but its contents have not reached this device
  /// yet. A download has been requested; a later pass will find it.
  case contentNotDownloaded
  /// The underlying filesystem operation failed. Deliberately opaque — a raw
  /// `NSError` description can embed the full path.
  case ioFailure
}

/// One file that failed to load, reported so a single corrupt record cannot
/// hide the rest of the history.
public struct CloudMessageFileLoadFailure: Sendable, Equatable {
  /// The file name only. Never the contents.
  public let fileName: String
  public let reason: CloudMessageFileTransportError

  public init(fileName: String, reason: CloudMessageFileTransportError) {
    self.fileName = fileName
    self.reason = reason
  }
}

/// Result of scanning the message directory.
public struct CloudMessageFileLoadResult: Sendable, Equatable {
  public let records: [CloudMessageRecord]
  public let failures: [CloudMessageFileLoadFailure]

  /// Documents present in the folder whose contents have not downloaded yet. A
  /// download was requested for each; they are not failures.
  public let pendingDownloads: Int

  public init(
    records: [CloudMessageRecord],
    failures: [CloudMessageFileLoadFailure],
    pendingDownloads: Int = 0
  ) {
    self.records = records
    self.failures = failures
    self.pendingDownloads = pendingDownloads
  }
}

// MARK: - Directory store

/// Stores portable message history as one JSON file per logical message inside a
/// user-selected directory.
///
/// # Why one file per message
///
/// The fingerprint becomes the file name, so identity and storage location are
/// the same fact. Two devices that independently observe one message write the
/// same path and converge instead of appending duplicates. A corrupted file
/// costs exactly one message rather than the whole history. And critically, no
/// SQLite or SwiftData database is ever placed in the synced directory —
/// **a live database must never be stored in iCloud Drive**; file-provider
/// materialisation and conflict copies would corrupt it. Only inert,
/// independently-replaceable JSON documents live here.
///
/// Append-only journals and single-file catalogues were both rejected: each
/// turns every device's write into a conflict on one shared file, which is the
/// failure mode iCloud Drive handles worst.
///
/// # What this type is not
///
/// It knows nothing about iCloud, UIKit, document pickers, or security scopes.
/// It is handed a plain directory `URL`. On iOS the app layer owns the
/// security-scoped bookmark and brackets calls with
/// `startAccessingSecurityScopedResource()`; keeping that out of here is what
/// lets the whole transport be tested against an ordinary temporary directory.
public struct CloudMessageDirectoryStore: Sendable {
  /// Subdirectory holding message documents, so the chosen folder can also carry
  /// future sibling content without the reader mistaking it for history.
  public static let messagesDirectoryName = "Messages"
  public static let fileExtension = "json"

  /// Conservative bound. Real fingerprints are ~72 characters; anything near a
  /// filesystem limit is not one of ours.
  static let maxFingerprintLength = 200

  private let root: URL

  /// - Parameter root: The user-selected sync folder. `Messages/` is created
  ///   beneath it on demand.
  public init(root: URL) {
    self.root = root
  }

  /// `FileManager.default` is used directly rather than injected: it is not
  /// `Sendable`, and Apple documents these operations as safe to call from
  /// multiple threads. Tests exercise real temporary directories, so nothing is
  /// lost by not stubbing it.
  private var fileManager: FileManager { .default }

  public var messagesDirectory: URL {
    root.appendingPathComponent(Self.messagesDirectoryName, isDirectory: true)
  }

  // MARK: File identity

  /// Whether a stem is a legal fingerprint for use as a file name.
  ///
  /// Enforces the charset rather than merely rejecting separators, so path
  /// traversal is impossible by construction: `/`, `\`, `..`, spaces, and every
  /// other separator fall outside `[A-Za-z0-9-]`. iCloud Drive conflict copies
  /// (`"…-ABC 2.json"`) contain a space and are therefore rejected here too,
  /// which is what keeps them from being read as genuine records.
  public static func isValidFingerprintFileStem(_ stem: String) -> Bool {
    guard !stem.isEmpty, stem.count <= maxFingerprintLength else { return false }
    guard stem.hasPrefix("\(CloudMessageFingerprint.scheme)-") else { return false }
    return stem.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }

  /// `<fingerprint>.json`, or `nil` when the fingerprint is not a legal stem.
  public static func fileName(for fingerprint: String) -> String? {
    guard isValidFingerprintFileStem(fingerprint) else { return nil }
    return "\(fingerprint).\(fileExtension)"
  }

  // MARK: Serialization

  /// `.sortedKeys` so equivalent records serialise to identical bytes; without
  /// it `JSONEncoder` gives no key-order guarantee and two devices could write
  /// byte-different files for the same logical record.
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func encode(_ record: CloudMessageRecord) throws -> Data {
    do {
      try CloudMessageImporter.validate(record)
    } catch {
      throw CloudMessageFileTransportError.fingerprintMismatch
    }
    do {
      return try makeEncoder().encode(record)
    } catch {
      throw CloudMessageFileTransportError.malformedContent
    }
  }

  /// Decodes and fully validates untrusted file contents.
  ///
  /// The file name is never trusted on its own: a file named with a valid
  /// fingerprint whose body computes to a different one is rejected. Validation
  /// reuses ``CloudMessageImporter/validate(_:)`` rather than adding a second
  /// fingerprint implementation, and nothing is ever silently repaired.
  static func decode(_ data: Data, expectedFingerprint: String?) throws -> CloudMessageRecord {
    let record: CloudMessageRecord
    do {
      record = try JSONDecoder().decode(CloudMessageRecord.self, from: data)
    } catch {
      throw CloudMessageFileTransportError.malformedContent
    }
    if let expectedFingerprint, record.fingerprint != expectedFingerprint {
      throw CloudMessageFileTransportError.fingerprintMismatch
    }
    do {
      try CloudMessageImporter.validate(record)
    } catch {
      throw CloudMessageFileTransportError.fingerprintMismatch
    }
    return record
  }

  // MARK: iCloud materialization

  /// Whether the document's bytes are on this device, requesting a download when
  /// they are not.
  ///
  /// A document in iCloud Drive is listed by `contentsOfDirectory` under its real
  /// name long before its contents arrive. Reading one of those placeholders
  /// fails, and nothing else in the system fetches it on our behalf — so without
  /// this an untouched folder would look permanently empty on a fresh device,
  /// which is exactly the case this transport exists to serve.
  ///
  /// `startDownloadingUbiquitousItem` needs no iCloud entitlement, container, or
  /// account of our own: it acts on a URL the user already granted us.
  ///
  /// A file outside a ubiquity container reports no downloading status, so
  /// ordinary local folders — including the temporary directories tests use —
  /// are always treated as present.
  static func isReadable(_ url: URL) -> Bool {
    let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
      .ubiquitousItemDownloadingStatus
    guard let status else { return true }
    guard status != .current else { return true }

    // Not current: ask for the newer contents either way. `.notDownloaded` has
    // nothing to read yet; `.downloaded` means a readable but stale copy is
    // present, which is still worth importing now — a record is immutable apart
    // from read state, so a stale copy is never wrong, only behind.
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    return status != .notDownloaded
  }

  // MARK: Reading

  /// The record stored under a fingerprint, or `nil` when absent.
  public func read(fingerprint: String) throws -> CloudMessageRecord? {
    guard let name = Self.fileName(for: fingerprint) else {
      throw CloudMessageFileTransportError.invalidFileName
    }
    let url = messagesDirectory.appendingPathComponent(name, isDirectory: false)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    guard Self.isReadable(url) else {
      throw CloudMessageFileTransportError.contentNotDownloaded
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw CloudMessageFileTransportError.ioFailure
    }
    return try Self.decode(data, expectedFingerprint: fingerprint)
  }

  /// Loads every valid record, reporting per-file failures rather than aborting.
  ///
  /// Skips anything that is not a `<fingerprint>.json` document: dotfiles
  /// (`.DS_Store`, iCloud `.…​.icloud` placeholders), atomic-write temporaries,
  /// conflict copies, and unrelated files.
  public func loadAll() -> CloudMessageFileLoadResult {
    let directory = messagesDirectory
    guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
      return CloudMessageFileLoadResult(records: [], failures: [])
    }

    var records: [CloudMessageRecord] = []
    var failures: [CloudMessageFileLoadFailure] = []
    var pendingDownloads = 0

    // Deterministic order so a scan is reproducible.
    for name in names.sorted() {
      guard !name.hasPrefix(".") else { continue }
      let url = URL(fileURLWithPath: name)
      guard url.pathExtension == Self.fileExtension else { continue }
      let stem = url.deletingPathExtension().lastPathComponent
      guard Self.isValidFingerprintFileStem(stem) else { continue }

      let fileURL = directory.appendingPathComponent(name, isDirectory: false)
      guard Self.isReadable(fileURL) else {
        // Not a failure: the contents are on their way and the next pass reads
        // them. Counting it as an error would make an ordinary first sync on a
        // new device look broken.
        pendingDownloads += 1
        continue
      }
      do {
        let data = try Data(contentsOf: fileURL)
        records.append(try Self.decode(data, expectedFingerprint: stem))
      } catch let error as CloudMessageFileTransportError {
        failures.append(CloudMessageFileLoadFailure(fileName: name, reason: error))
      } catch {
        failures.append(CloudMessageFileLoadFailure(fileName: name, reason: .ioFailure))
      }
    }
    return CloudMessageFileLoadResult(
      records: records, failures: failures, pendingDownloads: pendingDownloads
    )
  }

  // MARK: Writing

  /// Stores a record idempotently, merging read state monotonically.
  ///
  /// - absent → written, `.created`
  /// - present and identical → untouched, `.unchanged`
  /// - present and `isRead` advancing `false → true` → rewritten, `.markedRead`
  /// - present with different immutable content → rejected, existing file kept
  ///
  /// Writes are atomic (`Data.write(options: .atomic)`), which stages a
  /// temporary file and renames it into place, so a crash or an interrupted
  /// iCloud upload can never leave a half-written document that the reader would
  /// see. The staging file is created by Foundation and is filtered out by the
  /// reader's name rules regardless.
  @discardableResult
  public func save(_ record: CloudMessageRecord) throws -> CloudMessageSaveOutcome {
    guard let name = Self.fileName(for: record.fingerprint) else {
      throw CloudMessageFileTransportError.invalidFileName
    }
    let data = try Self.encode(record)

    do {
      try fileManager.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
    } catch {
      throw CloudMessageFileTransportError.ioFailure
    }
    let url = messagesDirectory.appendingPathComponent(name, isDirectory: false)

    if let existing = try read(fingerprint: record.fingerprint) {
      guard Self.immutableContent(existing) == Self.immutableContent(record) else {
        throw CloudMessageFileTransportError.immutableContentConflict(fingerprint: record.fingerprint)
      }
      // Monotonic: read wins, and a stale unread copy can never un-read.
      guard record.isRead, !existing.isRead else { return .unchanged }
      try Self.write(try Self.encode(Self.withRead(existing)), to: url)
      return .markedRead
    }

    try Self.write(data, to: url)
    return .created
  }

  /// Removes a record's file.
  ///
  /// Present for API completeness and test cleanup only. **Deletion is not
  /// propagated**: see the transport's deletion policy — remote message files are
  /// durable history, and removing one local observation must not erase the
  /// logical message for other radios or devices.
  public func delete(fingerprint: String) throws {
    guard let name = Self.fileName(for: fingerprint) else {
      throw CloudMessageFileTransportError.invalidFileName
    }
    let url = messagesDirectory.appendingPathComponent(name, isDirectory: false)
    guard fileManager.fileExists(atPath: url.path) else { return }
    do {
      try fileManager.removeItem(at: url)
    } catch {
      throw CloudMessageFileTransportError.ioFailure
    }
  }

  // MARK: Merge helpers

  /// The immutable identity of the logical message, for collision detection.
  ///
  /// `isRead` is mutable everywhere. For **outgoing** records `wireTimestamp` is
  /// also not identity: `resendDirectMessage(preserveTimestamp: false)` re-stamps
  /// `Message.timestamp` through `updateMessageTimestamp` while the fingerprint —
  /// the origin `Message.id` — is unchanged. Comparing it would make an ordinary
  /// resend look like a fingerprint collision. Incoming records keep the strict
  /// comparison, because their timestamp is hashed into the fingerprint and any
  /// difference really would be a forged or corrupted document.
  ///
  /// The stored record deliberately keeps the *first* wire timestamp written: it
  /// records when the message was originally sent, and a later local re-stamp is
  /// send-machinery state the portable format excludes everywhere else.
  static func immutableContent(_ record: CloudMessageRecord) -> CloudMessageRecord {
    let identityTimestamp: UInt32 = record.direction == .outgoing ? 0 : record.wireTimestamp
    return withRead(record, isRead: false, wireTimestamp: identityTimestamp)
  }

  static func withRead(
    _ record: CloudMessageRecord,
    isRead: Bool = true,
    wireTimestamp: UInt32? = nil
  ) -> CloudMessageRecord {
    CloudMessageRecord(
      formatVersion: record.formatVersion,
      fingerprint: record.fingerprint,
      conversation: record.conversation,
      direction: record.direction,
      text: record.text,
      wireTimestamp: wireTimestamp ?? record.wireTimestamp,
      senderNodeName: record.senderNodeName,
      isRead: isRead,
      originMessageID: record.originMessageID
    )
  }

  private static func write(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: [.atomic])
    } catch {
      throw CloudMessageFileTransportError.ioFailure
    }
  }
}
