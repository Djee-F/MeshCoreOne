import Foundation

// MARK: - Composed store

/// Everything CloudSync orchestration needs from persistence: the exporter's
/// reads, the router's reads, and the importer's two history writes.
///
/// A composition of the three protocols the previous sprints already defined
/// rather than a fourth protocol, so the coordinator gains no authority beyond
/// what those layers individually hold. In particular there is still no
/// `PendingSend` mutator, no `MessageService`, no `ChatSendQueueService`, no
/// `MeshCoreSession`, and no transport anywhere in scope.
public typealias CloudSyncMessageStore =
  CloudSyncMessageReading & CloudSyncMessageRouting & CloudSyncMessageImporting

// MARK: - Failure

/// Why one radio did not receive a record, when the others may have.
public enum CloudRadioSyncFailureReason: Sendable, Equatable {
  /// The importer refused the record for this radio.
  case importRejected(CloudMessageImportError)

  /// The persistence layer failed. Deliberately opaque: SwiftData error text can
  /// carry arbitrary payload, and CloudSync must not smuggle message content or
  /// key material into a result object that may be logged.
  case persistenceFailure
}

/// One radio's failure inside an otherwise-successful reconciliation.
public struct CloudRadioSyncFailure: Sendable, Equatable {
  public let radioID: UUID
  public let reason: CloudRadioSyncFailureReason

  public init(radioID: UUID, reason: CloudRadioSyncFailureReason) {
    self.radioID = radioID
    self.reason = reason
  }
}

// MARK: - Outcome

/// What one reconciliation did, across every radio it touched.
///
/// Composed from the existing Sprint 1C structures — ``CloudMessageRoutingPlan``
/// and ``CloudRadioImportResult`` — rather than restating them, so there is one
/// representation of a routing decision in the codebase.
public struct CloudMessageSyncOutcome: Sendable, Equatable {
  /// The portable record that was reconciled. For a local-message sync this is
  /// the exporter's output; for a remote sync it is the record as received.
  public let record: CloudMessageRecord

  /// The read-only plan the decision was based on.
  public let plan: CloudMessageRoutingPlan

  /// Per-radio import results, in plan order, for radios that were visited.
  public let imports: [CloudRadioImportResult]

  /// Radios that were visited but failed. Empty on a fully successful run.
  public let failures: [CloudRadioSyncFailure]

  public init(
    record: CloudMessageRecord,
    plan: CloudMessageRoutingPlan,
    imports: [CloudRadioImportResult],
    failures: [CloudRadioSyncFailure]
  ) {
    self.record = record
    self.plan = plan
    self.imports = imports
    self.failures = failures
  }

  /// The logical message's portable identity.
  public var fingerprint: String { record.fingerprint }

  /// Radios where a new local observation was created.
  public var insertedRadioIDs: [UUID] {
    imports.compactMap { if case .inserted = $0.outcome { $0.radioID } else { nil } }
  }

  /// Radios where an existing observation had portable state merged into it.
  public var updatedRadioIDs: [UUID] {
    imports.compactMap { if case .updatedExisting = $0.outcome { $0.radioID } else { nil } }
  }

  /// Radios that already held the message and needed no change.
  public var unchangedRadioIDs: [UUID] {
    imports.compactMap { if case .alreadyPresent = $0.outcome { $0.radioID } else { nil } }
  }

  /// Radios the router refused, paired with why.
  public var ineligible: [(radioID: UUID, reason: CloudRadioIneligibilityReason)] {
    plan.decisions.compactMap { decision in
      if case let .notEligible(reason) = decision.state {
        return (decision.radioID, reason)
      }
      return nil
    }
  }

  /// Whether every radio the plan visited succeeded.
  ///
  /// Note this describes *this run*, not global convergence: a caller that wants
  /// to know nothing is left to do should re-plan and check
  /// ``CloudMessageRoutingPlan/importableRadioIDs``.
  public var succeededEverywhere: Bool { failures.isEmpty }
}

// MARK: - Coordinator

/// Sequences the CloudSync primitives into a complete local synchronization
/// workflow, without knowing anything about a transport.
///
/// ```
///  local MessageDTO ──► CloudMessageExporter ──► CloudMessageRecord
///                                                      │
///                        [ a future transport lives here, outside this type ]
///                                                      │
///  CloudMessageRecord ──► CloudMessageRouter ──► plan ──► CloudMessageImporter
///                                                             │
///                                                    local observations
/// ```
///
/// # What this type adds
///
/// Policy and sequencing only. Export, eligibility, conversation resolution,
/// fingerprint validation, and the actual writes all remain in the Sprint
/// 1A/1B/1C primitives; nothing here reimplements them. The two policies this
/// layer genuinely owns are **which radios to consider** (supplied by the
/// caller) and **what to do when one radio fails** (continue, and report).
///
/// # Naming
///
/// Deliberately not `SyncCoordinator`: MC1 already has one for radio↔phone
/// synchronization, and confusing the two would be a real hazard given that one
/// of them touches the radio and this one must never do so.
///
/// # No transmission, ever
///
/// The store composition carries no `PendingSend` mutator and no send service,
/// so nothing reachable from here can queue a MeshCore transmission. Imported
/// outgoing history is historical data, never send work.
public struct CloudMessageSyncCoordinator: Sendable {
  private let exporter: CloudMessageExporter
  private let router: CloudMessageRouter
  private let importer: CloudMessageImporter

  public init(store: any CloudSyncMessageStore) {
    exporter = CloudMessageExporter(store: store)
    router = CloudMessageRouter(store: store)
    importer = CloudMessageImporter(store: store)
  }

  // MARK: Local message → portable record

  /// Exports a local row into the portable record a transport would carry.
  ///
  /// Read-only.
  public func exportRecord(for message: MessageDTO) async throws -> CloudMessageRecord {
    try await exporter.export(message)
  }

  // MARK: Planning (read-only)

  /// Plans reconciliation of an already-decoded record. Performs no writes.
  ///
  /// - Parameter radioIDs: see ``synchronize(_:across:)`` for why this is the
  ///   caller's decision.
  public func plan(
    for record: CloudMessageRecord,
    across radioIDs: [UUID]
  ) async throws -> CloudMessageRoutingPlan {
    try await router.plan(for: record, across: radioIDs)
  }

  /// Exports a local row and plans its reconciliation, without writing.
  public func plan(
    forLocalMessage message: MessageDTO,
    across radioIDs: [UUID]
  ) async throws -> (record: CloudMessageRecord, plan: CloudMessageRoutingPlan) {
    let record = try await exporter.export(message)
    return (record, try await router.plan(for: record, across: radioIDs))
  }

  // MARK: Execution

  /// Reconciles a **local** message across the given radios: export, plan, then
  /// apply.
  ///
  /// The message's own radio appears in the plan as an existing observation and
  /// is left untouched — the source row is never rewritten just because another
  /// radio gained a copy.
  @discardableResult
  public func synchronizeLocalMessage(
    _ message: MessageDTO,
    across radioIDs: [UUID]
  ) async throws -> CloudMessageSyncOutcome {
    try await synchronize(try await exporter.export(message), across: radioIDs)
  }

  /// Reconciles a record that arrived from elsewhere.
  ///
  /// **This is the seam a future transport calls.** A CloudKit (or any other)
  /// layer decodes its payload into a ``CloudMessageRecord`` and hands it here;
  /// nothing below this line knows or cares where the record came from.
  ///
  /// - Parameter radioIDs: The radios whose local history should participate.
  ///   Supplied explicitly and deliberately — see the type-level note and the
  ///   Sprint 1D report for why neither "currently connected" nor
  ///   `Device.isActive` is a correct substitute.
  ///
  /// - Throws: ``CloudMessageImportError`` if the record itself is invalid, which
  ///   is detected during planning and therefore **before any write**. Per-radio
  ///   failures do not throw; they are reported in
  ///   ``CloudMessageSyncOutcome/failures``.
  @discardableResult
  public func synchronize(
    _ record: CloudMessageRecord,
    across radioIDs: [UUID]
  ) async throws -> CloudMessageSyncOutcome {
    // Planning validates the record, so a malformed record fails here — before
    // any radio has been written to.
    let plan = try await router.plan(for: record, across: radioIDs)

    var imports: [CloudRadioImportResult] = []
    var failures: [CloudRadioSyncFailure] = []

    for decision in plan.decisions {
      switch decision.state {
      case .notEligible:
        // Refused by Sprint 1C policy: weak slot identity, an outgoing record on
        // a non-origin radio, or a conversation this radio does not have.
        continue

      case .existingObservation, .eligibleMissing:
        // Existing observations are still visited so a monotonic `isRead`
        // upgrade reaches every local copy; the importer leaves all other
        // radio-local metadata alone.
        do {
          let outcome = try await importer.import(
            record,
            into: CloudMessageImportContext(targetRadioID: decision.radioID)
          )
          imports.append(CloudRadioImportResult(radioID: decision.radioID, outcome: outcome))
        } catch let error as CloudMessageImportError {
          failures.append(
            CloudRadioSyncFailure(radioID: decision.radioID, reason: .importRejected(error))
          )
        } catch {
          // Deliberately opaque — see `CloudRadioSyncFailureReason`.
          failures.append(
            CloudRadioSyncFailure(radioID: decision.radioID, reason: .persistenceFailure)
          )
        }
      }
    }

    return CloudMessageSyncOutcome(
      record: record, plan: plan, imports: imports, failures: failures
    )
  }
}
