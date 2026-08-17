import CloudKit
import Foundation

// MARK: - Database abstraction

/// The narrow remote-database surface the message-history store needs.
///
/// Deliberately message-history-specific rather than a general cloud framework:
/// four operations, all keyed by record name, all trafficking in the `Sendable`
/// ``CloudMessageCloudKitPayload`` rather than `CKRecord`. That keeps the store's
/// semantics — idempotency, monotonic `isRead`, collision defence — testable
/// against an in-memory fake with no Apple ID, no network, and no CloudKit
/// object graph.
public protocol CloudMessageRemoteDatabase: Sendable {
  /// Creates the custom zone if absent. Idempotent.
  func ensureZoneExists() async throws

  /// The stored payload, or `nil` when no record exists under that name.
  func payload(forRecordName recordName: String) async throws -> CloudMessageCloudKitPayload?

  /// Writes the payload under its record name, replacing any existing record.
  func save(_ payload: CloudMessageCloudKitPayload) async throws

  /// Removes the record. Absent records are not an error.
  func delete(recordName: String) async throws
}

// MARK: - Errors

/// Failures the message-history store surfaces.
///
/// Deliberately narrow and payload-free. Raw `CKError` descriptions are never
/// propagated: they can embed record contents, and this type is what callers log.
public enum CloudMessageRemoteStoreError: Error, Equatable, Sendable {
  /// The record could not be mapped to or from the CloudKit schema.
  case schema(CloudMessageCloudKitSchemaError)

  /// A record already exists under this fingerprint with different immutable
  /// content. The existing record is left untouched.
  case immutableContentConflict(fingerprint: String)

  /// No iCloud account is available on this device.
  case accountUnavailable
  /// The network is unavailable.
  case networkUnavailable
  /// The user's iCloud storage quota is exhausted.
  case quotaExceeded
  /// The operation was not permitted (permission or zone access failure).
  case permissionFailure
  /// CloudKit failed for a reason this layer does not model. Carries only a
  /// coarse category, never the underlying description.
  case cloudKitFailure
}

// MARK: - Save outcome

/// What a save did remotely.
public enum CloudMessageSaveOutcome: Sendable, Equatable {
  /// No record existed; one was created.
  case created
  /// A record existed and was already identical, including read state.
  case unchanged
  /// A record existed and its read state was upgraded to read.
  case markedRead
}

// MARK: - Store

/// Reads and writes portable message history in the user's **private** CloudKit
/// database.
///
/// # Scope
///
/// Private database only. No public database, no shared database, no shared
/// zones, no sharing of any kind — message history is personal data and is never
/// published.
///
/// # What this type does not do
///
/// Nothing automatic. There is no subscription, no push handling, no background
/// task, no change token, no backfill, and no scan of the local message store.
/// It is called explicitly, one record at a time, and is not yet connected to
/// `CloudMessageSyncSession`.
///
/// # Concurrency honesty
///
/// The monotonic `isRead` merge is a client-side read-modify-write. It is **not**
/// atomic: two devices flipping the same record concurrently can interleave
/// between the fetch and the save. The merge is chosen so that interleaving is
/// harmless — the only mutable transition is `false → true`, so the worst case is
/// a redundant write, never a lost read. A genuinely atomic merge would need
/// server-side change tags and conflict retry, which belongs to a later sprint.
public struct CloudMessageCloudKitStore: Sendable {
  private let database: any CloudMessageRemoteDatabase

  public init(database: any CloudMessageRemoteDatabase) {
    self.database = database
  }

  /// Creates the message-history zone if needed. Idempotent; safe to call before
  /// any save.
  public func prepare() async throws {
    try await database.ensureZoneExists()
  }

  /// Stores a portable record, idempotently.
  ///
  /// - A record absent remotely is created.
  /// - A record already present with identical immutable content is left alone,
  ///   except that `isRead` may advance from `false` to `true`.
  /// - A record present with *different* immutable content is a fingerprint
  ///   collision and is rejected — the existing record is never overwritten.
  @discardableResult
  public func save(_ record: CloudMessageRecord) async throws -> CloudMessageSaveOutcome {
    let outgoing = try makePayload(record)
    let recordName = CloudMessageCloudKitSchema.recordName(for: record.fingerprint)

    guard let existing = try await fetchPayload(recordName: recordName) else {
      try await write(outgoing)
      return .created
    }

    // Same fingerprint must mean the same logical message. Anything else is a
    // collision, and silently overwriting would destroy real history.
    guard existing.immutableContent == outgoing.immutableContent else {
      throw CloudMessageRemoteStoreError.immutableContentConflict(fingerprint: record.fingerprint)
    }

    // Monotonic: read wins, and a stale unread upload can never un-read.
    let alreadyRead = existing.isRead != 0
    let becomingRead = outgoing.isRead != 0
    guard becomingRead, !alreadyRead else { return .unchanged }

    var merged = existing
    merged.isRead = 1
    try await write(merged)
    return .markedRead
  }

  /// Reads the portable record stored under a fingerprint.
  public func fetch(fingerprint: String) async throws -> CloudMessageRecord? {
    let recordName = CloudMessageCloudKitSchema.recordName(for: fingerprint)
    guard let payload = try await fetchPayload(recordName: recordName) else { return nil }
    do {
      return try CloudMessageCloudKitSchema.record(from: payload)
    } catch let error as CloudMessageCloudKitSchemaError {
      throw CloudMessageRemoteStoreError.schema(error)
    }
  }

  /// Removes the record stored under a fingerprint. Absent records are a no-op.
  public func delete(fingerprint: String) async throws {
    do {
      try await database.delete(recordName: CloudMessageCloudKitSchema.recordName(for: fingerprint))
    } catch {
      throw Self.mapped(error)
    }
  }

  // MARK: Private

  private func makePayload(_ record: CloudMessageRecord) throws -> CloudMessageCloudKitPayload {
    do {
      return try CloudMessageCloudKitSchema.payload(for: record)
    } catch let error as CloudMessageCloudKitSchemaError {
      throw CloudMessageRemoteStoreError.schema(error)
    }
  }

  private func fetchPayload(recordName: String) async throws -> CloudMessageCloudKitPayload? {
    do {
      return try await database.payload(forRecordName: recordName)
    } catch {
      throw Self.mapped(error)
    }
  }

  private func write(_ payload: CloudMessageCloudKitPayload) async throws {
    do {
      try await database.save(payload)
    } catch {
      throw Self.mapped(error)
    }
  }

  /// Collapses a CloudKit failure into this layer's narrow model, discarding the
  /// underlying description so record contents cannot leak into a caller's log.
  static func mapped(_ error: any Error) -> CloudMessageRemoteStoreError {
    if let known = error as? CloudMessageRemoteStoreError { return known }
    guard let ckError = error as? CKError else { return .cloudKitFailure }
    switch ckError.code {
    case .notAuthenticated: return .accountUnavailable
    case .networkUnavailable, .networkFailure, .serviceUnavailable: return .networkUnavailable
    case .quotaExceeded: return .quotaExceeded
    case .permissionFailure, .zoneNotFound, .userDeletedZone: return .permissionFailure
    default: return .cloudKitFailure
    }
  }
}

// MARK: - Production adapter

/// The real `CKDatabase`-backed implementation.
///
/// Compiled but never contacted by unit tests: constructing it does no I/O, and
/// every method is the first point that would touch the network. Tests exercise
/// the store against an in-memory fake instead.
///
/// - Important: This targets `CKContainer`'s **private** database exclusively.
///
/// - Note: Using this at runtime additionally requires the app to carry the
///   iCloud/CloudKit entitlement and a provisioned container. That capability is
///   not present in this repository today — see the Sprint 2A report. Absence of
///   the entitlement prevents *runtime* use, not compilation.
public struct CloudKitMessageDatabase: CloudMessageRemoteDatabase {
  private let database: CKDatabase
  private let zoneID: CKRecordZone.ID

  /// - Parameter container: The CloudKit container to use. The caller supplies
  ///   it so container identity stays a deployment decision rather than being
  ///   hard-coded here.
  public init(container: CKContainer) {
    database = container.privateCloudDatabase
    zoneID = CKRecordZone.ID(
      zoneName: CloudMessageCloudKitSchema.zoneName,
      ownerName: CKCurrentUserDefaultName
    )
  }

  public func ensureZoneExists() async throws {
    do {
      _ = try await database.save(CKRecordZone(zoneID: zoneID))
    } catch let error as CKError where error.code == .serverRecordChanged {
      // Zone already present — idempotent by design.
      return
    } catch {
      throw CloudMessageCloudKitStore.mapped(error)
    }
  }

  public func payload(forRecordName recordName: String) async throws -> CloudMessageCloudKitPayload? {
    let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    do {
      return Self.payload(from: try await database.record(for: id))
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    } catch {
      throw CloudMessageCloudKitStore.mapped(error)
    }
  }

  public func save(_ payload: CloudMessageCloudKitPayload) async throws {
    let id = CKRecord.ID(recordName: payload.fingerprint, zoneID: zoneID)
    let record = CKRecord(recordType: CloudMessageCloudKitSchema.recordType, recordID: id)
    Self.apply(payload, to: record)
    do {
      _ = try await database.save(record)
    } catch {
      throw CloudMessageCloudKitStore.mapped(error)
    }
  }

  public func delete(recordName: String) async throws {
    let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    do {
      _ = try await database.deleteRecord(withID: id)
    } catch let error as CKError where error.code == .unknownItem {
      return
    } catch {
      throw CloudMessageCloudKitStore.mapped(error)
    }
  }

  // MARK: CKRecord mapping

  /// Sensitive fields go through `encryptedValues`; the rest are plain.
  static func apply(_ payload: CloudMessageCloudKitPayload, to record: CKRecord) {
    typealias F = CloudMessageCloudKitPayload.Field
    record[F.formatVersion] = payload.formatVersion
    record[F.fingerprint] = payload.fingerprint
    record[F.conversationKind] = payload.conversationKind
    record[F.direction] = payload.direction
    record[F.wireTimestamp] = payload.wireTimestamp
    record[F.isRead] = payload.isRead
    if let slot = payload.channelSlot { record[F.channelSlot] = slot }
    if let originMessageID = payload.originMessageID { record[F.originMessageID] = originMessageID }

    record.encryptedValues[F.text] = payload.text
    if let key = payload.peerPublicKey { record.encryptedValues[F.peerPublicKey] = key }
    if let secret = payload.channelSecret { record.encryptedValues[F.channelSecret] = secret }
    // Absent key means nil; an empty string round-trips as "".
    if let name = payload.senderNodeName { record.encryptedValues[F.senderNodeName] = name }
  }

  static func payload(from record: CKRecord) -> CloudMessageCloudKitPayload {
    typealias F = CloudMessageCloudKitPayload.Field
    return CloudMessageCloudKitPayload(
      formatVersion: record[F.formatVersion] as? Int64 ?? -1,
      fingerprint: record[F.fingerprint] as? String ?? "",
      conversationKind: record[F.conversationKind] as? String ?? "",
      peerPublicKey: record.encryptedValues[F.peerPublicKey] as? Data,
      channelSecret: record.encryptedValues[F.channelSecret] as? Data,
      channelSlot: record[F.channelSlot] as? Int64,
      direction: record[F.direction] as? String ?? "",
      text: record.encryptedValues[F.text] as? String ?? "",
      wireTimestamp: record[F.wireTimestamp] as? Int64 ?? -1,
      senderNodeName: record.encryptedValues[F.senderNodeName] as? String,
      isRead: record[F.isRead] as? Int64 ?? 0,
      originMessageID: record[F.originMessageID] as? String
    )
  }
}
