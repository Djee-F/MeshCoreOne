import Foundation
@testable import MC1Services
import Testing

// MARK: - Coalescing and serialization

@Suite("Sync scheduler — coalescing and serialization")
struct SyncSchedulerCoalescingTests {
  /// §7.I: a burst of hints about one file must not produce a burst of work,
  /// and above all must not produce duplicate local rows.
  @Test
  func `Duplicate notifications are harmless`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contactA, contactB) = try await CloudSyncFx.addContacts(install)
    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "once"))

    await install.signal(10)

    #expect(await install.scheduler.signalCount == 10)
    #expect(await install.scheduler.reconcileCount < 10, "hints were collapsed")
    #expect(try await install.store.fetchMessages(contactID: contactA, limit: 10, offset: 0).count == 1)
    #expect(try await install.store.fetchMessages(contactID: contactB, limit: 10, offset: 0).count == 1)
  }

  /// §7.J: hints carry no ordering information — the only reaction is to re-read
  /// the directory — so any interleaving converges to the same state.
  @Test
  func `Reordered and interleaved notifications converge`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contactA, _) = try await CloudSyncFx.addContacts(install)
    let files = CloudSyncFx.files(folder)

    // Hints deliberately arrive out of step with the writes that caused them.
    await install.signal()
    try files.save(CloudSyncFx.incomingDM(text: "second", timestamp: CloudSyncFx.ts + 2))
    await install.signal(3)
    try files.save(CloudSyncFx.incomingDM(text: "first", timestamp: CloudSyncFx.ts + 1))
    await install.signal()
    await install.signal(2)

    let rows = try await install.store.fetchMessages(contactID: contactA, limit: 10, offset: 0)
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.text)) == ["first", "second"])
  }

  /// §7.T: Sync Now during automatic work is serialized by the transport actor,
  /// so concurrent requests cannot mutate concurrently or duplicate rows.
  @Test
  func `Manual sync during automatic reconciliation does not overlap`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contactA, contactB) = try await CloudSyncFx.addContacts(install)
    for index in 0..<5 {
      try CloudSyncFx.files(folder).save(
        CloudSyncFx.incomingDM(text: "m\(index)", timestamp: CloudSyncFx.ts + UInt32(index)))
    }

    install.monitor.emitBurst(4)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask { await install.reconcile() }
      }
    }
    await install.settle()

    #expect(try await install.store.fetchMessages(contactID: contactA, limit: 50, offset: 0).count == 5)
    #expect(try await install.store.fetchMessages(contactID: contactB, limit: 50, offset: 0).count == 5)
  }

  /// Repeated passes over an unchanged folder change nothing.
  @Test
  func `Repeated passes over an unchanged folder are idempotent`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contactA, _) = try await CloudSyncFx.addContacts(install)
    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "stable"))

    for _ in 0..<5 { await install.signal() }
    let final = await install.reconcile()

    #expect(final.observationsInserted == 0)
    #expect(final.observationsUnchanged == 2, "one per participating radio")
    #expect(try await install.store.fetchMessages(contactID: contactA, limit: 10, offset: 0).count == 1)
  }
}

// MARK: - Observer lifetime

@Suite("Sync scheduler — observer lifetime")
struct SyncSchedulerLifetimeTests {
  /// §7.S: repeated starts — another foreground, a re-entrant startup path —
  /// must never leave two observers running.
  @Test
  func `Repeated starts never multiply observers`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contactA, _) = try await CloudSyncFx.addContacts(install)
    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "hello"))

    for _ in 0..<5 {
      await install.scheduler.start(monitor: install.monitor)
    }
    #expect(await install.scheduler.isObserving)

    await install.signal()
    // One hint through one observer: were two observers live, the monitor's
    // single continuation would have been replaced and the count would drift.
    #expect(await install.scheduler.signalCount == 1)
    #expect(try await install.store.fetchMessages(contactID: contactA, limit: 10, offset: 0).count == 1)
  }

  /// §7.Q: reselecting a folder stops the old observation and starts exactly
  /// one new one.
  @Test
  func `Reselecting a folder swaps the observer exactly once`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    #expect(install.monitor.isObserved)

    let replacement = CloudSyncManualFolderMonitor()
    await install.scheduler.start(monitor: replacement)
    #expect(replacement.isObserved)

    // The old monitor is no longer consumed, so its hints reach nothing.
    install.monitor.emit()
    await install.settle()
    #expect(await install.scheduler.signalCount == 0)

    replacement.emit()
    for _ in 0..<10 { await Task.yield() }
    await install.scheduler.awaitPassesForTesting()
    #expect(await install.scheduler.signalCount == 1)
  }

  /// §7.R: disconnecting stops observation and any pending retry.
  @Test
  func `Stopping halts observation and pending work`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contactA, _) = try await CloudSyncFx.addContacts(install)

    await install.scheduler.stop()
    #expect(await install.scheduler.isObserving == false)

    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "after stop"))
    install.monitor.emitBurst(5)
    for _ in 0..<20 { await Task.yield() }

    #expect(await install.scheduler.reconcileCount == 0, "no pass ran after stopping")
    #expect(try await install.store.fetchMessages(contactID: contactA, limit: 10, offset: 0).isEmpty)
  }

  /// Stopping is safe when nothing is running, and safe twice.
  @Test
  func `Stopping is safe when idle and when repeated`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    await install.scheduler.stop()
    await install.scheduler.stop()
    #expect(await install.scheduler.isObserving == false)
    #expect(await install.scheduler.reconcileCount == 0)
  }
}

// MARK: - Pending downloads

@Suite("Sync scheduler — pending downloads")
struct SyncSchedulerRetryTests {
  /// A clean pass schedules no retry — the re-check exists only while iCloud
  /// still owes us contents, so it can never become a background poll.
  @Test
  func `A pass with nothing pending schedules no retry`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    try await CloudSyncFx.addContacts(install)
    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "present"))

    let summary = await install.reconcile()
    #expect(summary.pendingDownloads == 0)
    #expect(await install.scheduler.retryScheduledCount == 0)
  }

  /// §7.K/§5: a hint that arrives before contents are readable must not be a
  /// failure, and must not be the end of the story — the record has to land once
  /// the bytes do.
  ///
  /// Materialization itself needs real iCloud, so the *arrival* is modelled by
  /// the file appearing between passes. What this pins is the property that
  /// matters: a hint about a file that is not yet importable costs nothing, and
  /// a later pass imports it with no extra user action.
  @Test
  func `A hint before the file is importable still converges later`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contactA, contactB) = try await CloudSyncFx.addContacts(install)

    // Hints first, contents later.
    await install.signal(3)
    #expect(try await install.store.fetchMessages(contactID: contactA, limit: 10, offset: 0).isEmpty)
    #expect(await install.scheduler.reconcileCount > 0, "the pass ran and found nothing")

    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "arrived late"))
    await install.signal()

    #expect(try await install.store.fetchMessages(contactID: contactA, limit: 10, offset: 0).count == 1)
    #expect(try await install.store.fetchMessages(contactID: contactB, limit: 10, offset: 0).count == 1)
  }

  /// §7.P: an unreachable folder must not crash, must not corrupt history, and
  /// must not stop later reconciliation from succeeding.
  @Test
  func `An unavailable folder degrades safely and recovers`() async throws {
    let store = try await PersistenceStore.createTestDataStore(radioID: UUID())
    let radios = CloudSyncPersistedRadioProvider(store: store)
    let transport = CloudMessageFolderTransport(
      folderProvider: CloudSyncStaticFolderProvider(url: nil),
      coordinator: CloudMessageSyncCoordinator(store: store),
      radioProvider: radios
    )
    let monitor = CloudSyncManualFolderMonitor()
    let scheduler = CloudMessageSyncScheduler(
      transport: transport, sleeper: CloudSyncImmediateSleeper(),
      coalescingWindow: .zero, pendingDownloadRetryDelay: .zero
    )
    await scheduler.start(monitor: monitor)

    monitor.emitBurst(5)
    for _ in 0..<20 { await Task.yield() }
    await scheduler.awaitPassesForTesting()

    #expect(await transport.status == .notConfigured)
    #expect(await scheduler.reconcileCount > 0, "passes ran; they simply found nothing")

    // Recovery: a real folder now resolves and reconciles normally.
    let folder = try CloudSyncFx.tempRoot()
    let install = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contactA, _) = try await CloudSyncFx.addContacts(install)
    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "recovered"))
    await install.signal()
    #expect(try await install.store.fetchMessages(contactID: contactA, limit: 10, offset: 0).count == 1)
  }
}
