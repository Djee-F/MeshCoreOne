import Foundation
@testable import MC1Services
import Testing

// MARK: - Fixtures

private enum Fixture {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 11 })
  static let otherPeerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 77 })
  static let sharedSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 5 })
  static let otherSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 200 })
  static let publicSecret = Data(repeating: 0, count: ProtocolLimits.channelSecretSize)
  static let wireTimestamp: UInt32 = 1_704_067_200

  static func makeStore(radioID: UUID) async throws -> PersistenceStore {
    try await PersistenceStore.createTestDataStore(radioID: radioID)
  }

  @discardableResult
  static func saveContact(
    in store: PersistenceStore,
    radioID: UUID,
    publicKey: Data = Fixture.peerKey
  ) async throws -> ContactDTO {
    let contact = ContactDTO.testContact(id: UUID(), radioID: radioID, publicKey: publicKey)
    try await store.saveContact(contact)
    return contact
  }

  @discardableResult
  static func saveChannel(
    in store: PersistenceStore,
    radioID: UUID,
    index: UInt8,
    secret: Data
  ) async throws -> ChannelDTO {
    let channel = ChannelDTO.testChannel(radioID: radioID, index: index, secret: secret)
    try await store.saveChannel(channel)
    return channel
  }

  /// A well-formed record straight from the exporter, so tests exercise the real
  /// Sprint 1A output rather than a hand-built approximation.
  static func exportRecord(
    from store: PersistenceStore,
    message: MessageDTO
  ) async throws -> CloudMessageRecord {
    try await CloudMessageExporter(store: store).export(message)
  }

  static func context(_ radioID: UUID) -> CloudMessageImportContext {
    CloudMessageImportContext(targetRadioID: radioID)
  }
}

// MARK: - Incoming DM

@Suite("CloudMessageImporter — incoming direct messages")
struct CloudMessageImporterIncomingDMTests {
  /// Task 17A: the headline convergence proof. Two installs share only the peer
  /// public key; everything local differs.
  @Test
  func `Incoming DM converges across installs and lands on local identifiers`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    let contactA = try await Fixture.saveContact(in: storeA, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: storeB, radioID: radioB)
    #expect(contactA.id != contactB.id)

    let sourceMessage = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "meet at the ridge",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    let record = try await Fixture.exportRecord(from: storeA, message: sourceMessage)

    let outcome = try await CloudMessageImporter(store: storeB)
      .import(record, into: Fixture.context(radioB))
    #expect(outcome == .inserted(messageID: outcome.messageID))

    let imported = try await storeB.fetchMessages(contactID: contactB.id, limit: 10, offset: 0)
    #expect(imported.count == 1)
    let row = try #require(imported.first)

    // Local placement uses store B's identifiers, never store A's.
    #expect(row.radioID == radioB)
    #expect(row.contactID == contactB.id)
    #expect(row.id != sourceMessage.id)
    #expect(row.text == "meet at the ridge")
    #expect(row.direction == .incoming)

    // Re-exporting from B reproduces the same portable identity.
    let reExported = try await Fixture.exportRecord(from: storeB, message: row)
    #expect(reExported.fingerprint == record.fingerprint)
    #expect(reExported.conversation == record.conversation)

    // History import never creates send work.
    #expect(try await storeB.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// Task 16 (1–3): repeated import is idempotent.
  @Test
  func `Importing the same incoming DM twice inserts one row`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    let importer = CloudMessageImporter(store: store)

    let record = try await Fixture.exportRecord(
      from: store,
      message: MessageDTO.testDirectMessage(
        radioID: radioID, contactID: contact.id, text: "once",
        timestamp: Fixture.wireTimestamp, direction: .incoming
      )
    )

    let first = try await importer.import(record, into: Fixture.context(radioID))
    let second = try await importer.import(record, into: Fixture.context(radioID))

    guard case let .inserted(insertedID) = first else {
      Issue.record("expected .inserted, got \(first)")
      return
    }
    #expect(second == .alreadyPresent(messageID: insertedID))
    #expect(try await store.fetchMessages(contactID: contact.id, limit: 10, offset: 0).count == 1)
  }

  /// Task 16 (4–6): monotonic `isRead` merge, in all three interesting orders.
  @Test
  func `isRead merges monotonically and never reverts to unread`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)
    let importer = CloudMessageImporter(store: store)

    let unread = try await Fixture.exportRecord(
      from: store,
      message: MessageDTO.testDirectMessage(
        radioID: radioID, contactID: contact.id, text: "read me",
        timestamp: Fixture.wireTimestamp, direction: .incoming
      )
    )
    #expect(!unread.isRead)

    // false → local false
    let inserted = try await importer.import(unread, into: Fixture.context(radioID))
    let messageID = inserted.messageID
    #expect(try await store.fetchMessage(id: messageID)?.isRead == false)

    // cloud true over local false → upgrade
    let read = CloudMessageRecord(
      fingerprint: unread.fingerprint, conversation: unread.conversation,
      direction: unread.direction, text: unread.text, wireTimestamp: unread.wireTimestamp,
      senderNodeName: unread.senderNodeName, isRead: true, originMessageID: nil
    )
    #expect(try await importer.import(read, into: Fixture.context(radioID))
      == .updatedExisting(messageID: messageID))
    #expect(try await store.fetchMessage(id: messageID)?.isRead == true)

    // repeating the upgrade changes nothing
    #expect(try await importer.import(read, into: Fixture.context(radioID))
      == .alreadyPresent(messageID: messageID))

    // local true + cloud false stays true — CloudSync never un-reads
    #expect(try await importer.import(unread, into: Fixture.context(radioID))
      == .alreadyPresent(messageID: messageID))
    #expect(try await store.fetchMessage(id: messageID)?.isRead == true)

    #expect(try await store.fetchMessages(contactID: contact.id, limit: 10, offset: 0).count == 1)
  }

  /// Task 12: a record matching a message the radio already delivered locally
  /// must reconcile against that row rather than duplicating it — even though
  /// the local row predates CloudSync and stores no fingerprint.
  @Test
  func `Record matching a pre-existing local message does not duplicate it`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    // A message that arrived over the radio, saved the ordinary way.
    let local = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "already here",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(local)

    let record = try await Fixture.exportRecord(from: store, message: local)
    let outcome = try await CloudMessageImporter(store: store)
      .import(record, into: Fixture.context(radioID))

    #expect(outcome == .alreadyPresent(messageID: local.id))
    #expect(try await store.fetchMessages(contactID: contact.id, limit: 10, offset: 0).count == 1)
  }

  /// DOCUMENTED LIMITATION, pinned so it cannot be silently assumed fixed.
  ///
  /// Reconciliation narrows candidates with `fetchDMMessageCandidates`, which
  /// filters on `Message.timestamp`. When MC1 clock-corrects an incoming message
  /// (`SyncCoordinator.correctTimestampIfNeeded`), it writes the corrected value
  /// to `timestamp` and preserves the original in `senderTimestamp`. The record's
  /// `wireTimestamp` is the original, so the indexed window misses the local row
  /// and the import inserts a second copy.
  ///
  /// The two rows still share one portable fingerprint — identity converges, only
  /// the local *lookup* misses — so a stored fingerprint column (deliberately out
  /// of scope for this sprint) closes this properly. Correction only triggers for
  /// senders more than 5 minutes fast or 6 months slow, and the consequence is a
  /// visible duplicate rather than data loss.
  @Test
  func `Clock-corrected local message is not matched — known reconciliation gap`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    // What MC1 persists when the sender's clock was implausible: corrected
    // `timestamp`, original preserved in `senderTimestamp`.
    let corrected = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "skewed clock",
      timestamp: Fixture.wireTimestamp + 999_999, direction: .incoming
    ).copy {
      $0.timestampCorrected = true
      $0.senderTimestamp = Fixture.wireTimestamp
    }
    try await store.saveMessage(corrected)

    let record = try await Fixture.exportRecord(from: store, message: corrected)
    // Identity is derived from the original wire value, so it converges correctly.
    #expect(record.wireTimestamp == Fixture.wireTimestamp)

    let outcome = try await CloudMessageImporter(store: store)
      .import(record, into: Fixture.context(radioID))

    // The gap: a second row, despite representing the same logical message.
    #expect(outcome.messageID != corrected.id, "known gap: corrected rows are not found by wire timestamp")
    let rows = try await store.fetchMessages(contactID: contact.id, limit: 10, offset: 0)
    #expect(rows.count == 2, "documented duplicate; closed by a future stored-fingerprint column")

    // Both rows nonetheless export to one identity, so the model is sound.
    let fingerprints = try await withThrowingTaskGroup(of: String.self) { group -> Set<String> in
      for row in rows {
        group.addTask { try await Fixture.exportRecord(from: store, message: row).fingerprint }
      }
      return try await group.reduce(into: Set<String>()) { $0.insert($1) }
    }
    #expect(fingerprints == [record.fingerprint])
  }

  /// Task 8: local radioID is placement, not identity.
  @Test
  func `Same record imported into two stores uses each local radioID`() async throws {
    let sourceRadio = UUID()
    let radioB = UUID()
    let radioC = UUID()
    let sourceStore = try await Fixture.makeStore(radioID: sourceRadio)
    let storeB = try await Fixture.makeStore(radioID: radioB)
    let storeC = try await Fixture.makeStore(radioID: radioC)

    let sourceContact = try await Fixture.saveContact(in: sourceStore, radioID: sourceRadio)
    let contactB = try await Fixture.saveContact(in: storeB, radioID: radioB)
    let contactC = try await Fixture.saveContact(in: storeC, radioID: radioC)

    let record = try await Fixture.exportRecord(
      from: sourceStore,
      message: MessageDTO.testDirectMessage(
        radioID: sourceRadio, contactID: sourceContact.id, text: "fan out",
        timestamp: Fixture.wireTimestamp, direction: .incoming
      )
    )

    _ = try await CloudMessageImporter(store: storeB).import(record, into: Fixture.context(radioB))
    _ = try await CloudMessageImporter(store: storeC).import(record, into: Fixture.context(radioC))

    let rowB = try #require(try await storeB.fetchMessages(contactID: contactB.id, limit: 5, offset: 0).first)
    let rowC = try #require(try await storeC.fetchMessages(contactID: contactC.id, limit: 5, offset: 0).first)

    #expect(rowB.radioID == radioB)
    #expect(rowC.radioID == radioC)
    #expect(rowB.radioID != rowC.radioID)

    // Different local placement, one portable identity.
    let backB = try await Fixture.exportRecord(from: storeB, message: rowB)
    let backC = try await Fixture.exportRecord(from: storeC, message: rowC)
    #expect(backB.fingerprint == record.fingerprint)
    #expect(backC.fingerprint == record.fingerprint)
  }
}

// MARK: - Channels

@Suite("CloudMessageImporter — channels")
struct CloudMessageImporterChannelTests {
  /// Task 17B: the same secret occupying different slots on two installs.
  @Test
  func `Strong channel resolves by secret and adopts the local slot`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    _ = try await Fixture.saveChannel(in: storeA, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    _ = try await Fixture.saveChannel(in: storeB, radioID: radioB, index: 7, secret: Fixture.sharedSecret)

    let record = try await Fixture.exportRecord(
      from: storeA,
      message: MessageDTO.testChannelMessage(
        radioID: radioA, channelIndex: 3, text: "net at 1900",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )
    #expect(record.conversation == .channelSecret(Fixture.sharedSecret))

    _ = try await CloudMessageImporter(store: storeB).import(record, into: Fixture.context(radioB))

    let rows = try await storeB.fetchMessages(radioID: radioB, channelIndex: 7, limit: 10, offset: 0)
    #expect(rows.count == 1)
    let row = try #require(rows.first)

    // Slot 7 locally, not the source install's slot 3.
    #expect(row.channelIndex == 7)
    #expect(row.radioID == radioB)
    #expect(row.senderNodeName == "Alice")
    #expect(try await storeB.fetchMessages(radioID: radioB, channelIndex: 3, limit: 10, offset: 0).isEmpty)

    let reExported = try await Fixture.exportRecord(from: storeB, message: row)
    #expect(reExported.fingerprint == record.fingerprint)
    #expect(reExported.conversation == record.conversation)
    #expect(try await storeB.fetchPendingSends(radioID: radioB).isEmpty)
  }

  @Test
  func `Importing the same channel message twice inserts one row`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    _ = try await Fixture.saveChannel(in: store, radioID: radioID, index: 2, secret: Fixture.sharedSecret)
    let importer = CloudMessageImporter(store: store)

    let record = try await Fixture.exportRecord(
      from: store,
      message: MessageDTO.testChannelMessage(
        radioID: radioID, channelIndex: 2, text: "twice",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )

    let first = try await importer.import(record, into: Fixture.context(radioID))
    let second = try await importer.import(record, into: Fixture.context(radioID))

    #expect(second == .alreadyPresent(messageID: first.messageID))
    #expect(try await store.fetchMessages(radioID: radioID, channelIndex: 2, limit: 10, offset: 0).count == 1)
  }

  /// Task 17C / Task 7: weak identity stays weak. A slot record is placed at the
  /// same local slot without inventing a Channel row or a secret.
  @Test
  func `Weak slot record imports as slot history with no Channel row invented`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    // Slot 6 is unknown on the source install, so the export is weak.
    let record = try await Fixture.exportRecord(
      from: storeA,
      message: MessageDTO.testChannelMessage(
        radioID: radioA, channelIndex: 6, text: "unresolved but worth keeping",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )
    #expect(record.conversation == .channelSlot(6))
    #expect(!record.conversation.isStrong)

    // Store B also has no channel at slot 6 — history is preserved anyway.
    #expect(try await storeB.fetchChannel(radioID: radioB, index: 6) == nil)
    _ = try await CloudMessageImporter(store: storeB).import(record, into: Fixture.context(radioB))

    let row = try #require(
      try await storeB.fetchMessages(radioID: radioB, channelIndex: 6, limit: 10, offset: 0).first
    )
    #expect(row.channelIndex == 6)
    #expect(row.radioID == radioB)

    // No Channel row was conjured, and no secret was invented.
    #expect(try await storeB.fetchChannel(radioID: radioB, index: 6) == nil)
    #expect(try await storeB.fetchChannels(radioID: radioB).isEmpty)

    // Identity stays the Sprint 0 slot fallback.
    let reExported = try await Fixture.exportRecord(from: storeB, message: row)
    #expect(reExported.conversation == .channelSlot(6))
    #expect(reExported.fingerprint == record.fingerprint)
    #expect(reExported.fingerprint == CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Data(), channelIndex: 6, senderNodeName: "Alice",
      wireTimestamp: Fixture.wireTimestamp, text: "unresolved but worth keeping"
    ))
    #expect(try await storeB.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// A weak slot record must not be upgraded just because the local slot happens
  /// to hold a secret-bearing channel — the record made no such claim.
  @Test
  func `Weak slot record is not upgraded to secret identity by a local channel`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    let record = try await Fixture.exportRecord(
      from: storeA,
      message: MessageDTO.testChannelMessage(
        radioID: radioA, channelIndex: 4, text: "weak",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )
    #expect(record.conversation == .channelSlot(4))

    // Store B *does* have a secret channel at slot 4.
    _ = try await Fixture.saveChannel(in: storeB, radioID: radioB, index: 4, secret: Fixture.sharedSecret)
    _ = try await CloudMessageImporter(store: storeB).import(record, into: Fixture.context(radioB))

    let row = try #require(
      try await storeB.fetchMessages(radioID: radioB, channelIndex: 4, limit: 10, offset: 0).first
    )
    #expect(row.channelIndex == 4)

    // DOCUMENTED ASYMMETRY: weak identity is not round-trip stable. The importer
    // never invented a secret — it placed the row at slot 4 and nothing more —
    // but re-exporting from B now resolves the local secret-bearing channel and
    // legitimately strengthens to `.channelSecret`. So the fingerprint changes on
    // the way back out. That is correct behaviour for a record that only ever
    // claimed "slot 4", and it is precisely why a future importer must not treat
    // a slot match as proof two installs mean the same conversation.
    let reExported = try await Fixture.exportRecord(from: storeB, message: row)
    #expect(reExported.conversation == .channelSecret(Fixture.sharedSecret))
    #expect(reExported.conversation.isStrong)
    #expect(reExported.fingerprint != record.fingerprint)
  }

  /// Task 18: strong identity is never silently downgraded to a slot guess.
  @Test
  func `Unresolvable channel secret fails explicitly`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    _ = try await Fixture.saveChannel(in: storeA, radioID: radioA, index: 1, secret: Fixture.sharedSecret)
    // Store B knows a different channel only.
    _ = try await Fixture.saveChannel(in: storeB, radioID: radioB, index: 1, secret: Fixture.otherSecret)

    let record = try await Fixture.exportRecord(
      from: storeA,
      message: MessageDTO.testChannelMessage(
        radioID: radioA, channelIndex: 1, text: "no home here",
        timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
      )
    )

    await #expect(throws: CloudMessageImportError.unresolvedChannel) {
      try await CloudMessageImporter(store: storeB).import(record, into: Fixture.context(radioB))
    }
    #expect(try await storeB.fetchMessages(radioID: radioB, channelIndex: 1, limit: 10, offset: 0).isEmpty)
  }
}

// MARK: - Outgoing

@Suite("CloudMessageImporter — outgoing history")
struct CloudMessageImporterOutgoingTests {
  /// Outgoing identity travels as the origin row id, so the originating install
  /// recognizes its own row instead of duplicating it.
  @Test
  func `Originating install recognizes its own outgoing row`() async throws {
    let radioID = UUID()
    let store = try await Fixture.makeStore(radioID: radioID)
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    let sent = MessageDTO.testDirectMessage(
      radioID: radioID, contactID: contact.id, text: "on my way",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .delivered
    )
    try await store.saveMessage(sent)

    let record = try await Fixture.exportRecord(from: store, message: sent)
    #expect(record.originMessageID == sent.id)

    let outcome = try await CloudMessageImporter(store: store)
      .import(record, into: Fixture.context(radioID))
    #expect(outcome == .alreadyPresent(messageID: sent.id))
    #expect(try await store.fetchMessages(contactID: contact.id, limit: 10, offset: 0).count == 1)

    // The originating row's own status was not rewritten by import.
    #expect(try await store.fetchMessage(id: sent.id)?.status == .delivered)
  }

  /// Task 10 + 13: imported outgoing history is terminal and inert — never
  /// pending, sending, or retrying, and never accompanied by send work.
  @Test
  func `Imported outgoing history is terminal and creates no send work`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    let contactA = try await Fixture.saveContact(in: storeA, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: storeB, radioID: radioB)
    _ = try await Fixture.saveChannel(in: storeA, radioID: radioA, index: 1, secret: Fixture.sharedSecret)
    _ = try await Fixture.saveChannel(in: storeB, radioID: radioB, index: 5, secret: Fixture.sharedSecret)

    let dmRecord = try await Fixture.exportRecord(
      from: storeA,
      message: MessageDTO.testDirectMessage(
        radioID: radioA, contactID: contactA.id, text: "dm history",
        timestamp: Fixture.wireTimestamp, direction: .outgoing
      )
    )
    let channelRecord = try await Fixture.exportRecord(
      from: storeA,
      message: MessageDTO.testChannelMessage(
        radioID: radioA, channelIndex: 1, text: "channel history",
        timestamp: Fixture.wireTimestamp, direction: .outgoing, senderNodeName: "Me"
      )
    )

    let importer = CloudMessageImporter(store: storeB)
    _ = try await importer.import(dmRecord, into: Fixture.context(radioB))
    _ = try await importer.import(channelRecord, into: Fixture.context(radioB))

    let dmRow = try #require(try await storeB.fetchMessages(contactID: contactB.id, limit: 5, offset: 0).first)
    let channelRow = try #require(
      try await storeB.fetchMessages(radioID: radioB, channelIndex: 5, limit: 5, offset: 0).first
    )

    for row in [dmRow, channelRow] {
      #expect(row.direction == .outgoing)
      #expect(row.status == .sent, "imported outgoing history must be terminal")
      #expect(!row.isPending)
      #expect(row.status != .pending && row.status != .sending && row.status != .retrying)
      // No send telemetry was fabricated.
      #expect(row.ackCode == nil)
      #expect(row.roundTripTime == nil)
      #expect(row.retryAttempt == 0)
      #expect(row.maxRetryAttempts == 0)
      #expect(row.heardRepeats == 0)
      #expect(row.sendCount == 1)
    }
    // The channel message adopted store B's slot.
    #expect(channelRow.channelIndex == 5)

    // THE release-blocking invariant.
    #expect(try await storeB.fetchPendingSends(radioID: radioB).isEmpty)
    #expect(try await storeB.hasPendingSend(messageID: dmRow.id) == false)
    #expect(try await storeB.hasPendingSend(messageID: channelRow.id) == false)
  }

  @Test
  func `Importing outgoing history twice inserts one row`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)
    let contactA = try await Fixture.saveContact(in: storeA, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: storeB, radioID: radioB)

    let record = try await Fixture.exportRecord(
      from: storeA,
      message: MessageDTO.testDirectMessage(
        radioID: radioA, contactID: contactA.id, text: "idempotent",
        timestamp: Fixture.wireTimestamp, direction: .outgoing
      )
    )

    let importer = CloudMessageImporter(store: storeB)
    let first = try await importer.import(record, into: Fixture.context(radioB))
    let second = try await importer.import(record, into: Fixture.context(radioB))

    // Origin id is preserved as the local id, so identity is exact.
    #expect(first == .inserted(messageID: try #require(record.originMessageID)))
    #expect(second == .alreadyPresent(messageID: try #require(record.originMessageID)))
    #expect(try await storeB.fetchMessages(contactID: contactB.id, limit: 10, offset: 0).count == 1)
  }
}

// MARK: - Malformed and contradictory records

@Suite("CloudMessageImporter — malformed records")
struct CloudMessageImporterValidationTests {
  private func store() async throws -> (PersistenceStore, UUID) {
    let radioID = UUID()
    return (try await Fixture.makeStore(radioID: radioID), radioID)
  }

  private func directRecord(
    isRead: Bool = false,
    peerKey: Data = Fixture.peerKey,
    text: String = "hello"
  ) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: peerKey, wireTimestamp: Fixture.wireTimestamp, text: text
      ),
      conversation: .direct(peerPublicKey: peerKey),
      direction: .incoming, text: text, wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: isRead, originMessageID: nil
    )
  }

  @Test
  func `Unsupported format version is rejected and never treated as version 1`() async throws {
    let (store, radioID) = try await store()
    try await Fixture.saveContact(in: store, radioID: radioID)

    for version in [0, 2, 999] {
      let base = directRecord()
      let record = CloudMessageRecord(
        formatVersion: version, fingerprint: base.fingerprint, conversation: base.conversation,
        direction: base.direction, text: base.text, wireTimestamp: base.wireTimestamp,
        senderNodeName: base.senderNodeName, isRead: base.isRead, originMessageID: nil
      )
      await #expect(throws: CloudMessageImportError.unsupportedFormatVersion(version)) {
        try await CloudMessageImporter(store: store).import(record, into: Fixture.context(radioID))
      }
    }
  }

  @Test
  func `Fingerprint that disagrees with the record's own fields is rejected`() async throws {
    let (store, radioID) = try await store()
    try await Fixture.saveContact(in: store, radioID: radioID)

    let honest = directRecord()
    // Same fingerprint, different text: internally inconsistent.
    let tampered = CloudMessageRecord(
      fingerprint: honest.fingerprint, conversation: honest.conversation,
      direction: .incoming, text: "something else entirely",
      wireTimestamp: honest.wireTimestamp, senderNodeName: nil,
      isRead: false, originMessageID: nil
    )

    await #expect(throws: CloudMessageImportError.fingerprintMismatch) {
      try await CloudMessageImporter(store: store).import(tampered, into: Fixture.context(radioID))
    }
  }

  @Test
  func `Malformed peer public key is rejected`() async throws {
    let (store, radioID) = try await store()
    let shortKey = Data([0x01, 0x02, 0x03])
    let record = directRecord(peerKey: shortKey)

    await #expect(throws: CloudMessageImportError.invalidPeerPublicKey(byteCount: 3)) {
      try await CloudMessageImporter(store: store).import(record, into: Fixture.context(radioID))
    }
  }

  /// No contact is fabricated from a bare public key.
  @Test
  func `Unresolvable DM contact is rejected and no contact is invented`() async throws {
    let (store, radioID) = try await store()
    try await Fixture.saveContact(in: store, radioID: radioID, publicKey: Fixture.otherPeerKey)

    await #expect(throws: CloudMessageImportError.unresolvedContact) {
      try await CloudMessageImporter(store: store).import(
        directRecord(), into: Fixture.context(radioID)
      )
    }
    #expect(try await store.fetchContacts(radioID: radioID).count == 1)
    #expect(try await store.fetchContact(radioID: radioID, publicKey: Fixture.peerKey) == nil)
  }

  @Test
  func `Outgoing record without an origin message id is rejected`() async throws {
    let (store, radioID) = try await store()
    let record = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.outgoing(originMessageID: UUID()),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .outgoing, text: "orphan", wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )

    await #expect(throws: CloudMessageImportError.missingOriginMessageID) {
      try await CloudMessageImporter(store: store).import(record, into: Fixture.context(radioID))
    }
  }

  /// Incoming identity is content-derived; a foreign local row id travelling
  /// with it is a contradiction, not a harmless extra.
  @Test
  func `Incoming record carrying an origin message id is rejected`() async throws {
    let (store, radioID) = try await store()
    let base = directRecord()
    let contradictory = CloudMessageRecord(
      fingerprint: base.fingerprint, conversation: base.conversation,
      direction: .incoming, text: base.text, wireTimestamp: base.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: UUID()
    )

    await #expect(throws: CloudMessageImportError.unexpectedOriginMessageID) {
      try await CloudMessageImporter(store: store).import(contradictory, into: Fixture.context(radioID))
    }
  }

  /// `Message.id` is `@Attribute(.unique)`, so a blind insert would upsert an
  /// unrelated row away. Reconciliation refuses instead.
  @Test
  func `Origin id colliding with an unrelated local row is rejected`() async throws {
    let (store, radioID) = try await store()
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    // An unrelated incoming row already occupies this UUID.
    let collidingID = UUID()
    try await store.saveMessage(MessageDTO.testDirectMessage(
      id: collidingID, radioID: radioID, contactID: contact.id, text: "unrelated",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    ))

    let record = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.outgoing(originMessageID: collidingID),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .outgoing, text: "collision", wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: collidingID
    )

    await #expect(throws: CloudMessageImportError.localIDCollision(messageID: collidingID)) {
      try await CloudMessageImporter(store: store).import(record, into: Fixture.context(radioID))
    }
    // The unrelated row survived untouched.
    #expect(try await store.fetchMessage(id: collidingID)?.text == "unrelated")
  }

  /// Nothing is written when validation fails.
  @Test
  func `Rejected records leave the database untouched`() async throws {
    let (store, radioID) = try await store()
    let contact = try await Fixture.saveContact(in: store, radioID: radioID)

    let base = directRecord()
    let bad = CloudMessageRecord(
      formatVersion: 99, fingerprint: base.fingerprint, conversation: base.conversation,
      direction: base.direction, text: base.text, wireTimestamp: base.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )

    _ = try? await CloudMessageImporter(store: store).import(bad, into: Fixture.context(radioID))

    #expect(try await store.fetchMessages(contactID: contact.id, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioID).isEmpty)
  }
}

// MARK: - No-send invariant

@Suite("CloudMessageImporter — no-send invariant")
struct CloudMessageImporterNoSendTests {
  /// Task 15: all four record shapes, one assertion — importing history never
  /// creates send work.
  @Test
  func `No record shape creates a PendingSend`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let storeA = try await Fixture.makeStore(radioID: radioA)
    let storeB = try await Fixture.makeStore(radioID: radioB)

    let contactA = try await Fixture.saveContact(in: storeA, radioID: radioA)
    _ = try await Fixture.saveContact(in: storeB, radioID: radioB)
    _ = try await Fixture.saveChannel(in: storeA, radioID: radioA, index: 1, secret: Fixture.sharedSecret)
    _ = try await Fixture.saveChannel(in: storeB, radioID: radioB, index: 1, secret: Fixture.sharedSecret)

    var records: [CloudMessageRecord] = []
    for direction in [MessageDirection.incoming, .outgoing] {
      records.append(try await Fixture.exportRecord(
        from: storeA,
        message: MessageDTO.testDirectMessage(
          radioID: radioA, contactID: contactA.id, text: "dm \(direction)",
          timestamp: Fixture.wireTimestamp, direction: direction
        )
      ))
      records.append(try await Fixture.exportRecord(
        from: storeA,
        message: MessageDTO.testChannelMessage(
          radioID: radioA, channelIndex: 1, text: "ch \(direction)",
          timestamp: Fixture.wireTimestamp, direction: direction, senderNodeName: "Alice"
        )
      ))
    }
    #expect(records.count == 4)

    let importer = CloudMessageImporter(store: storeB)
    for record in records {
      _ = try await importer.import(record, into: Fixture.context(radioB))
    }

    // Observable proof: the outbox is empty, so nothing can be drained onto the
    // radio by `ChatSendQueueService.hydrate()`, which reads only PendingSend rows.
    #expect(try await storeB.fetchPendingSends(radioID: radioB).isEmpty)
    #expect(try await storeA.fetchPendingSends(radioID: radioA).isEmpty)
  }
}
