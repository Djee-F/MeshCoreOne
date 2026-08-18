import Foundation
@testable import MC1Services
import Testing

/// Proves the full cross-device cycle terminates.
///
/// The danger is a feedback loop: A writes a document, B imports it, B's import
/// looks like new local history, B re-uploads, A imports, and the two chase each
/// other forever. Prevention here is **structural** — ``CloudMessageImporter``
/// holds no reference to a session, an uploader, or an event stream, so an
/// applied record has no path back out — and **idempotent**: identity is the
/// fingerprint, so the only convergent write is a merge onto the same file.
///
/// Nothing below relies on a timing flag, a sleep, a "ignore the next event"
/// window, or a recursion guard. Those would all be ways of making a real loop
/// look quiet.
@Suite("Loop prevention")
struct CloudSyncLoopPreventionTests {
  /// Builds an installation whose session uploads through the shared folder,
  /// which is the production wiring.
  private func session(for installation: CloudSyncFx.Installation) async -> CloudMessageSyncSession {
    let session = CloudMessageSyncSession(
      store: installation.store,
      radioProvider: CloudSyncPersistedRadioProvider(store: installation.store)
    )
    await session.setUploader(installation.transport)
    return session
  }

  /// §8: A writes, B imports, B advances read state, A imports, both sides are
  /// hammered with hints — and the whole system comes to rest.
  @Test
  func `The full A to B to A cycle converges and stops`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let b = try await CloudSyncFx.makeInstallation(folder: folder)
    let aSession = await session(for: a)
    let bSession = await session(for: b)
    let (aContactA, _) = try await CloudSyncFx.addContacts(a)
    let (bContactA, bContactB) = try await CloudSyncFx.addContacts(b)
    let files = CloudSyncFx.files(folder)

    // 1. A records local history. One document appears.
    let local = MessageDTO.testDirectMessage(
      radioID: a.radioA, contactID: aContactA, text: "round trip",
      timestamp: CloudSyncFx.ts, direction: .incoming)
    try await a.store.saveMessage(local)
    await aSession.recordLocalMessage(local)
    #expect(files.loadAll().records.count == 1)

    // 2. B imports it. The import must not read as new local history on B.
    let bTriggersBefore = await bSession.processedTriggerCount
    await b.signal()
    #expect(await bSession.processedTriggerCount == bTriggersBefore,
            "an applied record never re-enters the local trigger path")
    #expect(files.loadAll().records.count == 1, "importing wrote nothing back")

    let importedOnB = try #require(
      try await b.store.fetchMessages(contactID: bContactA, limit: 10, offset: 0).first)

    // 3. B marks it read. That IS local action, so it uploads — but as a merge
    //    onto the same file identity, never as a second document.
    try await b.store.markMessageAsRead(id: importedOnB.id)
    await bSession.recordLocalRead(messageID: importedOnB.id)
    #expect(files.loadAll().records.count == 1, "same fingerprint, same file")
    #expect(files.loadAll().records.first?.isRead == true)

    // 4. A sees the read state.
    await a.signal()
    let onA = try await a.store.fetchMessages(contactID: aContactA, limit: 10, offset: 0)
    #expect(onA.count == 1)
    #expect(onA.first?.isRead == true)

    // 5. Hammer both sides. A live loop would keep minting documents or rows.
    for _ in 0..<5 {
      await a.signal(4)
      await b.signal(4)
    }

    #expect(files.loadAll().records.count == 1, "stable: no document was ever minted twice")
    #expect(try await a.store.fetchMessages(contactID: aContactA, limit: 50, offset: 0).count == 1)
    #expect(try await b.store.fetchMessages(contactID: bContactA, limit: 50, offset: 0).count == 1)
    #expect(try await b.store.fetchMessages(contactID: bContactB, limit: 50, offset: 0).count == 1)

    // The last passes on both sides did no work at all — the definition of rest.
    #expect(await a.transport.lastSummary.observationsInserted == 0)
    #expect(await b.transport.lastSummary.observationsInserted == 0)
    #expect(await a.transport.lastSummary.observationsUpdated == 0)
    #expect(await b.transport.lastSummary.observationsUpdated == 0)

    // And nothing anywhere turned into send work.
    for (store, radios) in [(a.store, [a.radioA, a.radioB]), (b.store, [b.radioA, b.radioB])] {
      for radio in radios {
        #expect(try await store.fetchPendingSends(radioID: radio).isEmpty)
      }
    }
  }

  /// Reconciliation drives no local triggers at all, however many times it runs.
  /// This is the property that makes the loop impossible rather than merely
  /// unlikely.
  @Test
  func `Reconciliation never feeds the local trigger path`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let aSession = await session(for: a)
    try await CloudSyncFx.addContacts(a)

    for index in 0..<4 {
      try CloudSyncFx.files(folder).save(
        CloudSyncFx.incomingDM(text: "m\(index)", timestamp: CloudSyncFx.ts + UInt32(index)))
    }
    for _ in 0..<5 { await a.signal(3) }

    #expect(await aSession.processedTriggerCount == 0)
    #expect(await aSession.skippedTriggerCount == 0)
    #expect(await aSession.failureCount == 0)
    // Exactly the four documents that were placed there. None written back.
    #expect(CloudSyncFx.files(folder).loadAll().records.count == 4)
  }
}

// MARK: - No-send invariant

/// Automatic synchronization must never become a transmitter.
///
/// `CloudMessageFolderTransport` and `CloudMessageSyncScheduler` hold no
/// `MessageService`, no `ChatSendQueueService`, no `PendingSend` mutator, and no
/// MeshCore session — there is no object graph through which a radio send could
/// be reached. These tests pin the observable consequence.
@Suite("Automatic reconciliation — no-send invariant")
struct CloudSyncNoSendTests {
  /// Imported history of every shape must leave the send queue untouched.
  @Test
  func `Automatic reconciliation creates no send work`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    try await CloudSyncFx.addContacts(a)
    try await CloudSyncFx.addChannels(a, slotA: 3, slotB: 5)

    let files = CloudSyncFx.files(folder)
    try files.save(CloudSyncFx.incomingDM(text: "incoming"))
    try files.save(CloudSyncFx.incomingDM(text: "read already", isRead: true, timestamp: CloudSyncFx.ts + 1))
    try files.save(CloudSyncFx.strongChannel(text: "channel"))
    try files.save(CloudSyncFx.weakChannel(slot: 9, text: "weak"))
    try files.save(CloudSyncFx.outgoing(text: "outgoing"))

    for _ in 0..<4 { await a.signal(3) }

    for radio in [a.radioA, a.radioB] {
      #expect(try await a.store.fetchPendingSends(radioID: radio).isEmpty)
    }
  }

  /// Imported rows are settled history, never work waiting to be transmitted.
  @Test
  func `Imported rows carry no pending send state`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contact, _) = try await CloudSyncFx.addContacts(a)
    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "settled"))

    await a.signal()

    let rows = try await a.store.fetchMessages(contactID: contact, limit: 10, offset: 0)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.status == .delivered, "settled history, not work waiting to be sent")
    #expect(row.status != .pending, "never queued for transmission")
    #expect(row.retryAttempt == 0, "no retry was scheduled")
    #expect(try await a.store.fetchPendingSends(radioID: a.radioA).isEmpty)

    // `sendCount` is 1 by schema default on every Message, so its value proves
    // nothing on its own. What matters is that repeated passes never move it —
    // a transmission would.
    let initialSendCount = row.sendCount
    for _ in 0..<4 { await a.signal(2) }
    let after = try #require(
      try await a.store.fetchMessages(contactID: contact, limit: 10, offset: 0).first)
    #expect(after.sendCount == initialSendCount)
    #expect(after.retryAttempt == 0)
    #expect(after.status == .delivered)
    #expect(try await a.store.fetchPendingSends(radioID: a.radioA).isEmpty)
  }

  /// A pre-existing send queued by the radio path must survive untouched: the
  /// hazard is not only creating send work, but disturbing it.
  @Test
  func `An existing pending send is left untouched`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let (contact, _) = try await CloudSyncFx.addContacts(a)

    let outgoing = MessageDTO.testDirectMessage(
      radioID: a.radioA, contactID: contact, text: "queued by the radio path",
      timestamp: CloudSyncFx.ts, direction: .outgoing, status: .pending)
    try await a.store.saveMessage(outgoing)
    let pending = PendingSendDTO(
      id: UUID(), radioID: a.radioA, messageID: outgoing.id, kind: .dm,
      contactID: contact, channelIndex: nil, isResend: false,
      messageText: outgoing.text, messageTimestamp: CloudSyncFx.ts,
      localNodeName: nil, sequence: 1, enqueuedAt: Date(timeIntervalSince1970: 1_712_000_000)
    )
    try await a.store.upsertPendingSend(pending)

    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "unrelated"))
    for _ in 0..<3 { await a.signal(2) }

    let queue = try await a.store.fetchPendingSends(radioID: a.radioA)
    #expect(queue.count == 1)
    #expect(queue.first?.id == pending.id)
    #expect(queue.first?.attemptCount == 0, "no retry counter was moved")
    #expect(queue.first?.messageID == outgoing.id)
  }
}
