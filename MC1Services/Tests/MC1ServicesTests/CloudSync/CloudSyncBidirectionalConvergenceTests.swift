import Foundation
@testable import MC1Services
import Testing

/// Two independent installations sharing one folder. This is how convergence
/// between devices is proven without owning two devices: separate stores,
/// separate radios, separate schedulers, one directory.
@Suite("Bidirectional convergence")
struct CloudSyncBidirectionalConvergenceTests {
  /// §7.A: a record written by one installation reconciles into every eligible
  /// radio of the other, as independent local observations.
  @Test
  func `A record written by A reaches every eligible radio on B`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let b = try await CloudSyncFx.makeInstallation(folder: folder)
    let (aContact, _) = try await CloudSyncFx.addContacts(a)
    let (bContactA, bContactB) = try await CloudSyncFx.addContacts(b)

    let local = MessageDTO.testDirectMessage(
      radioID: a.radioA, contactID: aContact, text: "hello from A",
      timestamp: CloudSyncFx.ts, direction: .incoming)
    try await a.store.saveMessage(local)
    #expect(await a.transport.uploadLocalMessage(local))

    await b.signal()

    let onA = try await b.store.fetchMessages(contactID: bContactA, limit: 10, offset: 0)
    let onB = try await b.store.fetchMessages(contactID: bContactB, limit: 10, offset: 0)
    #expect(onA.count == 1)
    #expect(onB.count == 1)
    #expect(onA.first?.text == "hello from A")
    #expect(onA.first?.radioID == b.radioA, "placed locally, not on the source radio")
    #expect(onA.first?.id != onB.first?.id, "independent observations")
    #expect(onA.first?.id != local.id)
  }

  /// §7.B: a strong channel identity maps to each radio's *own* local slot. A
  /// slot number must never cross an installation or a radio.
  @Test
  func `Strong channel records map to each radio's own slot`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let b = try await CloudSyncFx.makeInstallation(folder: folder)
    try await CloudSyncFx.addChannels(a, slotA: 3, slotB: 7)
    try await CloudSyncFx.addChannels(b, slotA: 11, slotB: 2)

    try CloudSyncFx.files(folder).save(CloudSyncFx.strongChannel(text: "net traffic"))
    await a.signal()
    await b.signal()

    #expect(try await a.store.fetchMessages(radioID: a.radioA, channelIndex: 3, limit: 5, offset: 0).count == 1)
    #expect(try await a.store.fetchMessages(radioID: a.radioB, channelIndex: 7, limit: 5, offset: 0).count == 1)
    #expect(try await b.store.fetchMessages(radioID: b.radioA, channelIndex: 11, limit: 5, offset: 0).count == 1)
    #expect(try await b.store.fetchMessages(radioID: b.radioB, channelIndex: 2, limit: 5, offset: 0).count == 1)

    // No slot from the other installation leaked in.
    #expect(try await b.store.fetchMessages(radioID: b.radioA, channelIndex: 3, limit: 5, offset: 0).isEmpty)
    #expect(try await b.store.fetchMessages(radioID: b.radioA, channelIndex: 7, limit: 5, offset: 0).isEmpty)
    #expect(try await a.store.fetchMessages(radioID: a.radioA, channelIndex: 11, limit: 5, offset: 0).isEmpty)
  }

  /// §7.C: a weak (slot-only) channel identity is not portable, so it is never
  /// fanned out to another radio or installation.
  @Test
  func `Weak channel records never propagate`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let b = try await CloudSyncFx.makeInstallation(folder: folder)
    try await CloudSyncFx.addChannels(a, slotA: 4, slotB: 4)

    try CloudSyncFx.files(folder).save(CloudSyncFx.weakChannel(slot: 4, text: "unconfigured"))
    await a.signal()
    await b.signal()

    for (store, radios) in [(a.store, [a.radioA, a.radioB]), (b.store, [b.radioA, b.radioB])] {
      for radio in radios {
        #expect(try await store.fetchMessages(radioID: radio, channelIndex: 4, limit: 5, offset: 0).isEmpty)
      }
    }
  }

  /// §7.D: an outgoing message has exactly one author, so remote outgoing
  /// history is never cloned onto a radio that did not send it.
  @Test
  func `Outgoing records are never cloned onto other radios`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let b = try await CloudSyncFx.makeInstallation(folder: folder)
    try await CloudSyncFx.addContacts(a)
    let (bContactA, bContactB) = try await CloudSyncFx.addContacts(b)

    let originID = UUID()
    try CloudSyncFx.files(folder).save(
      CloudSyncFx.outgoing(text: "sent by A", originMessageID: originID))
    await b.signal()

    #expect(try await b.store.fetchMessages(contactID: bContactA, limit: 10, offset: 0).isEmpty)
    #expect(try await b.store.fetchMessages(contactID: bContactB, limit: 10, offset: 0).isEmpty)
    #expect(try await b.store.fetchMessage(id: originID) == nil)
  }

  /// §7.E: read state converges upward only.
  @Test
  func `Read state propagates monotonically and never reverses`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let (aContact, _) = try await CloudSyncFx.addContacts(a)
    let files = CloudSyncFx.files(folder)

    try files.save(CloudSyncFx.incomingDM(text: "unread", isRead: false))
    await a.signal()
    var rows = try await a.store.fetchMessages(contactID: aContact, limit: 10, offset: 0)
    #expect(rows.first?.isRead == false)

    // Another installation marks it read.
    try files.save(CloudSyncFx.incomingDM(text: "unread", isRead: true))
    await a.signal()
    rows = try await a.store.fetchMessages(contactID: aContact, limit: 10, offset: 0)
    #expect(rows.count == 1)
    #expect(rows.first?.isRead == true)

    // A stale unread copy can never un-read it, in the folder or locally.
    try files.save(CloudSyncFx.incomingDM(text: "unread", isRead: false))
    #expect(files.loadAll().records.first?.isRead == true)
    await a.signal()
    rows = try await a.store.fetchMessages(contactID: aContact, limit: 10, offset: 0)
    #expect(rows.count == 1)
    #expect(rows.first?.isRead == true)
  }

  /// §7.F: the same fingerprint arriving over and over yields one local row per
  /// radio, forever.
  @Test
  func `A repeated fingerprint never duplicates local rows`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let (aContact, _) = try await CloudSyncFx.addContacts(a)
    try CloudSyncFx.files(folder).save(CloudSyncFx.incomingDM(text: "repeat"))

    for _ in 0..<6 { await a.signal(3) }
    await a.reconcile()

    #expect(try await a.store.fetchMessages(contactID: aContact, limit: 20, offset: 0).count == 1)
    #expect(CloudSyncFx.files(folder).loadAll().records.count == 1)
  }

  /// §7.G: two installations writing different messages at the same time end up
  /// with both messages on both sides.
  @Test
  func `Concurrent writes from both installations converge everywhere`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let b = try await CloudSyncFx.makeInstallation(folder: folder)
    let (aContact, _) = try await CloudSyncFx.addContacts(a)
    let (bContact, _) = try await CloudSyncFx.addContacts(b)

    let fromA = MessageDTO.testDirectMessage(
      radioID: a.radioA, contactID: aContact, text: "from A",
      timestamp: CloudSyncFx.ts, direction: .incoming)
    let fromB = MessageDTO.testDirectMessage(
      radioID: b.radioA, contactID: bContact, text: "from B",
      timestamp: CloudSyncFx.ts + 1, direction: .incoming)
    try await a.store.saveMessage(fromA)
    try await b.store.saveMessage(fromB)

    async let uploadA = a.transport.uploadLocalMessage(fromA)
    async let uploadB = b.transport.uploadLocalMessage(fromB)
    #expect(await uploadA)
    #expect(await uploadB)

    await a.signal()
    await b.signal()

    let aTexts = Set(try await a.store.fetchMessages(contactID: aContact, limit: 20, offset: 0).map(\.text))
    let bTexts = Set(try await b.store.fetchMessages(contactID: bContact, limit: 20, offset: 0).map(\.text))
    #expect(aTexts == ["from A", "from B"])
    #expect(bTexts == ["from A", "from B"])
    #expect(CloudSyncFx.files(folder).loadAll().records.count == 2)
  }

  /// §7.H: one real-world message heard by both installations is one logical
  /// record — but each installation keeps its own local observations.
  @Test
  func `One message observed by both installations converges to one record`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let b = try await CloudSyncFx.makeInstallation(folder: folder)
    let (aContactA, aContactB) = try await CloudSyncFx.addContacts(a)
    let (bContactA, _) = try await CloudSyncFx.addContacts(b)

    // Identical wire facts observed independently, so identical fingerprints.
    let heardByA = MessageDTO.testDirectMessage(
      radioID: a.radioA, contactID: aContactA, text: "broadcast",
      timestamp: CloudSyncFx.ts, direction: .incoming)
    let heardByB = MessageDTO.testDirectMessage(
      radioID: b.radioA, contactID: bContactA, text: "broadcast",
      timestamp: CloudSyncFx.ts, direction: .incoming)
    try await a.store.saveMessage(heardByA)
    try await b.store.saveMessage(heardByB)
    #expect(await a.transport.uploadLocalMessage(heardByA))
    #expect(await b.transport.uploadLocalMessage(heardByB))

    #expect(CloudSyncFx.files(folder).loadAll().records.count == 1, "one logical message")

    await a.signal()
    await b.signal()

    // A's own observation stays, and its second radio gains one.
    #expect(try await a.store.fetchMessages(contactID: aContactA, limit: 10, offset: 0).count == 1)
    #expect(try await a.store.fetchMessages(contactID: aContactB, limit: 10, offset: 0).count == 1)
    #expect(try await b.store.fetchMessages(contactID: bContactA, limit: 10, offset: 0).count == 1)
  }
}

// MARK: - Hostile documents

@Suite("Bidirectional convergence — hostile documents")
struct CloudSyncHostileDocumentTests {
  /// §7.L/M/N/O: one bad document must never poison the pass. Malformed JSON, a
  /// body disagreeing with its filename, an unsupported format version, and an
  /// iCloud conflict copy all coexist with a record that must still import.
  @Test
  func `Bad documents never block the good one`() async throws {
    let folder = try CloudSyncFx.tempRoot()
    let a = try await CloudSyncFx.makeInstallation(folder: folder)
    let (aContact, _) = try await CloudSyncFx.addContacts(a)
    let files = CloudSyncFx.files(folder)

    let good = CloudSyncFx.incomingDM(text: "survivor")
    try files.save(good)
    let directory = files.messagesDirectory

    // L: malformed JSON under an otherwise legal name.
    let malformed = CloudSyncFx.incomingDM(text: "malformed", timestamp: CloudSyncFx.ts + 1)
    try Data("{ not json".utf8).write(
      to: directory.appendingPathComponent(#require(CloudMessageDirectoryStore.fileName(for: malformed.fingerprint))))

    // M: a valid record stored under someone else's fingerprint.
    let impostorName = try #require(CloudMessageDirectoryStore.fileName(
      for: CloudSyncFx.incomingDM(text: "mismatch", timestamp: CloudSyncFx.ts + 2).fingerprint))
    try CloudMessageDirectoryStore.makeEncoder()
      .encode(CloudSyncFx.incomingDM(text: "different body", timestamp: CloudSyncFx.ts + 3))
      .write(to: directory.appendingPathComponent(impostorName))

    // N: an unsupported future format version.
    let future = CloudSyncFx.incomingDM(text: "future", timestamp: CloudSyncFx.ts + 4)
    try JSONEncoder().encode(CloudMessageRecord(
      formatVersion: 99, fingerprint: future.fingerprint, conversation: future.conversation,
      direction: .incoming, text: future.text, wireTimestamp: future.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )).write(to: directory.appendingPathComponent(#require(CloudMessageDirectoryStore.fileName(for: future.fingerprint))))

    // O: an iCloud conflict copy. Its name carries a space, so the filename
    // policy rejects it before it is ever read — it is not even examined.
    let conflictName = "\(good.fingerprint) 2.\(CloudMessageDirectoryStore.fileExtension)"
    try CloudMessageDirectoryStore.makeEncoder().encode(good)
      .write(to: directory.appendingPathComponent(conflictName))

    await a.signal()

    let summary = try #require(await a.transport.lastSummary)
    #expect(summary.validRecords == 1)
    #expect(summary.rejectedRecords == 3, "malformed, mismatched, unsupported")
    #expect(summary.filesExamined == 4, "the conflict copy is filtered by name, never examined")
    #expect(!summary.isClean)

    let rows = try await a.store.fetchMessages(contactID: aContact, limit: 20, offset: 0)
    #expect(rows.count == 1)
    #expect(rows.first?.text == "survivor")
  }
}
