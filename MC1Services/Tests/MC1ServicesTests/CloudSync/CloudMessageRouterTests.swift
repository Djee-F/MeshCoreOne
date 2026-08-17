import Foundation
@testable import MC1Services
import Testing

// MARK: - Fixtures

private enum Fixture {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 13 })
  static let otherPeerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 90 })
  static let sharedSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 21 })
  static let otherSecret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 150 })
  static let wireTimestamp: UInt32 = 1_704_067_200

  /// One local database hosting two radios — the multi-radio case this sprint
  /// exists for.
  static func makeTwoRadioStore() async throws -> (store: PersistenceStore, radioA: UUID, radioB: UUID) {
    let radioA = UUID()
    let radioB = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioA)
    try await store.saveDevice(
      DeviceDTO.testDevice(
        id: radioB, radioID: radioB,
        publicKey: Data(repeating: 0x02, count: ProtocolLimits.publicKeySize)
      )
    )
    return (store, radioA, radioB)
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

  static func exportRecord(from store: PersistenceStore, message: MessageDTO) async throws -> CloudMessageRecord {
    try await CloudMessageExporter(store: store).export(message)
  }

  static func state(
    _ plan: CloudMessageRoutingPlan,
    _ radioID: UUID
  ) -> CloudRadioRoutingState? {
    plan.decisions.first { $0.radioID == radioID }?.state
  }
}

// MARK: - Direct messages

@Suite("CloudMessageRouter — direct messages")
struct CloudMessageRouterDirectTests {
  /// Matrix 1: one logical message legitimately observed by two radios. The
  /// router must report BOTH, not treat the second as corruption.
  @Test
  func `Two radios observing the same logical DM report two existing observations`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    // The same over-the-air message, independently received by each radio.
    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "heard twice",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "heard twice",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)
    #expect(onA.id != onB.id)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])

    #expect(plan.existingObservations.count == 2)
    #expect(Fixture.state(plan, radioA) == .existingObservation(
      messageID: onA.id, placement: .direct(contactID: contactA.id)
    ))
    #expect(Fixture.state(plan, radioB) == .existingObservation(
      messageID: onB.id, placement: .direct(contactID: contactB.id)
    ))
    #expect(plan.importableRadioIDs.isEmpty)

    // Both rows survive; neither was merged or deleted.
    #expect(try await store.fetchMessage(id: onA.id) != nil)
    #expect(try await store.fetchMessage(id: onB.id) != nil)
  }

  /// Matrix 2 + 4 + 5: present on A, missing on B. Differing `Contact.id` and
  /// `radioID` affect neither eligibility nor logical identity.
  @Test
  func `Message on one radio leaves the other eligible and missing`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)
    #expect(contactA.id != contactB.id)
    #expect(radioA != radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "only on A",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])

    #expect(Fixture.state(plan, radioA)?.existingMessageID == onA.id)
    #expect(Fixture.state(plan, radioB) == .eligibleMissing(placement: .direct(contactID: contactB.id)))
    #expect(plan.importableRadioIDs == [radioB])
  }

  /// Matrix 3: eligibility is contact membership by full public key.
  @Test
  func `Radio without the peer public key is not eligible`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    // Radio B knows a different peer only.
    try await Fixture.saveContact(in: store, radioID: radioB, publicKey: Fixture.otherPeerKey)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "stranger",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])

    #expect(Fixture.state(plan, radioB) == .notEligible(.noContactWithPeerKey))
    #expect(plan.importableRadioIDs.isEmpty)
  }

  /// Executing the plan imports into B only, using B's own local identifiers.
  @Test
  func `Executing a plan imports onto the missing radio with local placement`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "fan to B",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    let router = CloudMessageRouter(store: store)
    let plan = try await router.plan(for: record, across: [radioA, radioB])
    let results = try await router.execute(plan, of: record, using: CloudMessageImporter(store: store))

    // Radio A already had it, radio B received it.
    #expect(results.count == 2)
    #expect(results.first { $0.radioID == radioA }?.outcome == .alreadyPresent(messageID: onA.id))
    guard case .inserted = try #require(results.first { $0.radioID == radioB }?.outcome) else {
      Issue.record("expected an insert on radio B")
      return
    }

    let rowsB = try await store.fetchMessages(contactID: contactB.id, limit: 10, offset: 0)
    #expect(rowsB.count == 1)
    let rowB = try #require(rowsB.first)
    #expect(rowB.radioID == radioB)
    #expect(rowB.contactID == contactB.id)
    #expect(rowB.id != onA.id, "incoming observations keep independent local ids")

    // Re-planning now finds two observations of one logical message.
    let replan = try await router.plan(for: record, across: [radioA, radioB])
    #expect(replan.existingObservations.count == 2)
    #expect(replan.importableRadioIDs.isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }
}

// MARK: - Strong channels

@Suite("CloudMessageRouter — strong channels")
struct CloudMessageRouterStrongChannelTests {
  /// Matrix 6 + 8: same secret at different slots; placement follows the local slot.
  @Test
  func `Same secret at different slots is eligible on both radios`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 7, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "net at 1900",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    #expect(record.conversation == .channelSecret(Fixture.sharedSecret))

    let router = CloudMessageRouter(store: store)
    let plan = try await router.plan(for: record, across: [radioA, radioB])

    #expect(Fixture.state(plan, radioA)?.existingMessageID == onA.id)
    // B's placement is B's slot 7 — never A's slot 3.
    #expect(Fixture.state(plan, radioB) == .eligibleMissing(placement: .channel(index: 7)))

    try await router.execute(plan, of: record, using: CloudMessageImporter(store: store))

    let rowB = try #require(
      try await store.fetchMessages(radioID: radioB, channelIndex: 7, limit: 10, offset: 0).first
    )
    #expect(rowB.channelIndex == 7)
    #expect(rowB.radioID == radioB)
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 3, limit: 10, offset: 0).isEmpty)
  }

  /// Matrix 7: independently received on both radios, at different slots.
  @Test
  func `Same channel message received on both radios reports two observations`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 7, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "both heard it",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    let onB = MessageDTO.testChannelMessage(
      radioID: radioB, channelIndex: 7, text: "both heard it",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])

    #expect(plan.existingObservations.count == 2)
    #expect(Fixture.state(plan, radioA)?.existingMessageID == onA.id)
    #expect(Fixture.state(plan, radioB)?.existingMessageID == onB.id)
    #expect(plan.importableRadioIDs.isEmpty)
  }

  /// Matrix 9: a matching slot number with a different secret is not a match.
  @Test
  func `Same slot number with a different secret does not make a radio eligible`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 3, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 3, secret: Fixture.otherSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 3, text: "not yours",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])

    #expect(Fixture.state(plan, radioB) == .notEligible(.noChannelWithSecret))
    #expect(plan.importableRadioIDs.isEmpty)
  }
}

// MARK: - Weak channels

@Suite("CloudMessageRouter — weak channel slots")
struct CloudMessageRouterWeakChannelTests {
  /// Matrix 10 + 12: slot equality must never justify cross-radio propagation,
  /// and no secret is invented or upgraded.
  @Test
  func `Matching slot number alone does not make another radio eligible`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    // Neither radio has a Channel row at slot 4, so the export is weak.
    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 4, text: "weak identity",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    #expect(record.conversation == .channelSlot(4))
    #expect(!record.conversation.isStrong)

    let router = CloudMessageRouter(store: store)
    let plan = try await router.plan(for: record, across: [radioA, radioB])

    // Matrix 11: A's existing observation is still recognized.
    #expect(Fixture.state(plan, radioA)?.existingMessageID == onA.id)
    // Matrix 10: B is refused despite being able to host slot 4.
    #expect(Fixture.state(plan, radioB) == .notEligible(.weakSlotIdentityNotPropagated))
    #expect(plan.importableRadioIDs.isEmpty)

    // Executing the plan must not create anything on B.
    try await router.execute(plan, of: record, using: CloudMessageImporter(store: store))
    #expect(try await store.fetchMessages(radioID: radioB, channelIndex: 4, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchChannels(radioID: radioB).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// A radio that *does* hold a channel at the weak slot is still refused: the
  /// record asserted "slot 4 on the originating install", nothing more.
  @Test
  func `Weak record is refused even when the other radio has a channel at that slot`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 4, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 4, text: "still weak",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    #expect(record.conversation == .channelSlot(4))

    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])
    #expect(Fixture.state(plan, radioB) == .notEligible(.weakSlotIdentityNotPropagated))
  }

  /// Matrix 11: a weak record recognizes an observation already sitting at that
  /// slot on another radio — recognizing asserts nothing new — but still does not
  /// become importable there.
  @Test
  func `Weak record recognizes an existing observation without becoming importable`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()

    let onA = MessageDTO.testChannelMessage(
      radioID: radioA, channelIndex: 4, text: "seen on both",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    let onB = MessageDTO.testChannelMessage(
      radioID: radioB, channelIndex: 4, text: "seen on both",
      timestamp: Fixture.wireTimestamp, direction: .incoming, senderNodeName: "Alice"
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])

    #expect(plan.existingObservations.count == 2)
    #expect(plan.importableRadioIDs.isEmpty)
  }
}

// MARK: - Outgoing

@Suite("CloudMessageRouter — outgoing history")
struct CloudMessageRouterOutgoingTests {
  /// Matrix 13 + 14: an outgoing record is recognized on the radio that authored
  /// it and never fanned out. `Message.id` is unique store-wide, so a second row
  /// could not exist even if the router proposed one.
  @Test
  func `Outgoing record is recognized on its origin radio and never fanned out`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let sent = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "authored on A",
      timestamp: Fixture.wireTimestamp, direction: .outgoing, status: .delivered
    )
    try await store.saveMessage(sent)

    let record = try await Fixture.exportRecord(from: store, message: sent)
    #expect(record.originMessageID == sent.id)

    let router = CloudMessageRouter(store: store)
    let plan = try await router.plan(for: record, across: [radioA, radioB])

    #expect(Fixture.state(plan, radioA)?.existingMessageID == sent.id)
    // B has the same peer, yet is still refused — deliberately.
    #expect(Fixture.state(plan, radioB) == .notEligible(.outgoingNotFannedOut))
    #expect(plan.importableRadioIDs.isEmpty)

    try await router.execute(plan, of: record, using: CloudMessageImporter(store: store))

    // Nothing landed on B, and A's row is untouched.
    #expect(try await store.fetchMessages(contactID: contactB.id, limit: 10, offset: 0).isEmpty)
    #expect(try await store.fetchMessage(id: sent.id)?.radioID == radioA)
    #expect(try await store.fetchMessage(id: sent.id)?.status == .delivered)

    // Matrix 14: no send work anywhere.
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// An outgoing record with no local observation is refused everywhere rather
  /// than assigned to an arbitrarily chosen radio.
  @Test
  func `Outgoing record with no local observation is refused on every radio`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let foreignID = UUID()
    let record = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.outgoing(originMessageID: foreignID),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .outgoing, text: "from a third device",
      wireTimestamp: Fixture.wireTimestamp, senderNodeName: nil,
      isRead: false, originMessageID: foreignID
    )

    let router = CloudMessageRouter(store: store)
    let plan = try await router.plan(for: record, across: [radioA, radioB])

    #expect(Fixture.state(plan, radioA) == .notEligible(.outgoingNotFannedOut))
    #expect(Fixture.state(plan, radioB) == .notEligible(.outgoingNotFannedOut))
    #expect(plan.importableRadioIDs.isEmpty)

    try await router.execute(plan, of: record, using: CloudMessageImporter(store: store))
    #expect(try await store.fetchMessage(id: foreignID) == nil)
  }

  /// Matrix 15: outgoing history imported through the Sprint 1B path stays inert.
  @Test
  func `Outgoing history imported directly remains inert`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let sent = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "history",
      timestamp: Fixture.wireTimestamp, direction: .outgoing
    )
    let record = try await Fixture.exportRecord(from: store, message: sent)

    // The explicit Sprint 1B path remains available for a deliberately chosen radio.
    _ = try await CloudMessageImporter(store: store)
      .import(record, into: CloudMessageImportContext(targetRadioID: radioB))

    let originMessageID = try #require(record.originMessageID)
    let row = try #require(try await store.fetchMessage(id: originMessageID))
    #expect(row.direction == .outgoing)
    #expect(row.status == .sent)
    #expect(!row.isPending)
    #expect(row.ackCode == nil)
    #expect(row.retryAttempt == 0)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }
}

// MARK: - Read state

@Suite("CloudMessageRouter — read state")
struct CloudMessageRouterReadStateTests {
  /// Matrix 16 + 20: a read upgrade reaches every observation, and nothing else
  /// crosses between radios.
  @Test
  func `Read upgrade reaches both observations without copying radio-local metadata`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    // Two observations with deliberately different radio-local reception metadata.
    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "read me everywhere",
      timestamp: Fixture.wireTimestamp, direction: .incoming,
      pathLength: 3, snr: -7.25, heardRepeats: 2
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "read me everywhere",
      timestamp: Fixture.wireTimestamp, direction: .incoming,
      pathLength: 1, snr: 4.5, heardRepeats: 0
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let exported = try await Fixture.exportRecord(from: store, message: onA)
    let readRecord = CloudMessageRecord(
      fingerprint: exported.fingerprint, conversation: exported.conversation,
      direction: exported.direction, text: exported.text, wireTimestamp: exported.wireTimestamp,
      senderNodeName: exported.senderNodeName, isRead: true, originMessageID: nil
    )

    let router = CloudMessageRouter(store: store)
    let plan = try await router.plan(for: readRecord, across: [radioA, radioB])
    let results = try await router.execute(plan, of: readRecord, using: CloudMessageImporter(store: store))

    #expect(results.count == 2)
    #expect(results.allSatisfy { $0.outcome == .updatedExisting(messageID: $0.outcome.messageID) })

    let afterA = try #require(try await store.fetchMessage(id: onA.id))
    let afterB = try #require(try await store.fetchMessage(id: onB.id))
    #expect(afterA.isRead)
    #expect(afterB.isRead)

    // Matrix 20: radio-local reception metadata is untouched and un-crossed.
    #expect(afterA.pathLength == 3)
    #expect(afterA.snr == -7.25)
    #expect(afterA.heardRepeats == 2)
    #expect(afterB.pathLength == 1)
    #expect(afterB.snr == 4.5)
    #expect(afterB.heardRepeats == 0)
    #expect(afterA.radioID == radioA)
    #expect(afterB.radioID == radioB)
    #expect(afterA.contactID == contactA.id)
    #expect(afterB.contactID == contactB.id)
  }

  /// Matrix 17: monotonic — a cloud record can never un-read an observation.
  @Test
  func `Cloud isRead false never un-reads an observation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "already read",
      timestamp: Fixture.wireTimestamp, direction: .incoming, isRead: true
    )
    let onB = MessageDTO.testDirectMessage(
      radioID: radioB, contactID: contactB.id, text: "already read",
      timestamp: Fixture.wireTimestamp, direction: .incoming, isRead: true
    )
    try await store.saveMessage(onA)
    try await store.saveMessage(onB)

    let unreadRecord = try await Fixture.exportRecord(
      from: store,
      message: onA.copy { $0.isRead = false }
    )
    #expect(!unreadRecord.isRead)

    let router = CloudMessageRouter(store: store)
    let plan = try await router.plan(for: unreadRecord, across: [radioA, radioB])
    let results = try await router.execute(plan, of: unreadRecord, using: CloudMessageImporter(store: store))

    #expect(results.allSatisfy { $0.outcome == .alreadyPresent(messageID: $0.outcome.messageID) })
    #expect(try await store.fetchMessage(id: onA.id)?.isRead == true)
    #expect(try await store.fetchMessage(id: onB.id)?.isRead == true)
  }
}

// MARK: - Safety

@Suite("CloudMessageRouter — safety")
struct CloudMessageRouterSafetyTests {
  /// Matrix 22: planning is pure. Nothing in the database moves.
  @Test
  func `Planning performs no database mutation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    let contactB = try await Fixture.saveContact(in: store, radioID: radioB)
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 1, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 5, secret: Fixture.sharedSecret)

    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "untouched",
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)
    let record = try await Fixture.exportRecord(from: store, message: onA)

    let messagesBefore = try await store.fetchMessages(contactID: contactA.id, limit: 50, offset: 0)
    let contactsABefore = try await store.fetchContacts(radioID: radioA)
    let contactsBBefore = try await store.fetchContacts(radioID: radioB)
    let channelsBefore = try await store.fetchChannels(radioID: radioB)

    // Plan repeatedly — still no writes.
    let router = CloudMessageRouter(store: store)
    for _ in 0..<3 {
      _ = try await router.plan(for: record, across: [radioA, radioB])
    }

    #expect(try await store.fetchMessages(contactID: contactA.id, limit: 50, offset: 0) == messagesBefore)
    #expect(try await store.fetchMessages(contactID: contactB.id, limit: 50, offset: 0).isEmpty)
    #expect(try await store.fetchContacts(radioID: radioA) == contactsABefore)
    #expect(try await store.fetchContacts(radioID: radioB) == contactsBBefore)
    #expect(try await store.fetchChannels(radioID: radioB) == channelsBefore)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }

  /// Matrix 18 + 19: no record shape, planned or executed across radios, creates
  /// send work. `ChatSendQueueService.hydrate()` draws work solely from
  /// `PendingSend`, so an empty outbox is proof no transmission can follow.
  @Test
  func `No record shape creates send work across radios`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)
    try await Fixture.saveChannel(in: store, radioID: radioA, index: 1, secret: Fixture.sharedSecret)
    try await Fixture.saveChannel(in: store, radioID: radioB, index: 6, secret: Fixture.sharedSecret)

    var sources: [MessageDTO] = []
    for direction in [MessageDirection.incoming, .outgoing] {
      sources.append(MessageDTO.testDirectMessage(
        radioID: radioA, contactID: contactA.id, text: "dm \(direction)",
        timestamp: Fixture.wireTimestamp, direction: direction
      ))
      sources.append(MessageDTO.testChannelMessage(
        radioID: radioA, channelIndex: 1, text: "ch \(direction)",
        timestamp: Fixture.wireTimestamp, direction: direction, senderNodeName: "Alice"
      ))
    }
    for message in sources {
      try await store.saveMessage(message)
    }

    let router = CloudMessageRouter(store: store)
    let importer = CloudMessageImporter(store: store)
    for message in sources {
      let record = try await Fixture.exportRecord(from: store, message: message)
      let plan = try await router.plan(for: record, across: [radioA, radioB])
      try await router.execute(plan, of: record, using: importer)
    }

    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
    for message in sources {
      #expect(try await store.hasPendingSend(messageID: message.id) == false)
    }
  }

  /// Matrix 21: planning refuses a malformed record through the importer's own
  /// validation, so a plan is never produced for something that could not execute.
  @Test
  func `Malformed records are rejected during planning by the shared validation`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    try await Fixture.saveContact(in: store, radioID: radioA)
    let router = CloudMessageRouter(store: store)

    let honest = CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Fixture.peerKey, wireTimestamp: Fixture.wireTimestamp, text: "hi"
      ),
      conversation: .direct(peerPublicKey: Fixture.peerKey),
      direction: .incoming, text: "hi", wireTimestamp: Fixture.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )

    // Unsupported version.
    let futureVersion = CloudMessageRecord(
      formatVersion: 99, fingerprint: honest.fingerprint, conversation: honest.conversation,
      direction: .incoming, text: honest.text, wireTimestamp: honest.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )
    await #expect(throws: CloudMessageImportError.unsupportedFormatVersion(99)) {
      try await router.plan(for: futureVersion, across: [radioA, radioB])
    }

    // Fingerprint disagreeing with the record's own fields.
    let tampered = CloudMessageRecord(
      fingerprint: honest.fingerprint, conversation: honest.conversation,
      direction: .incoming, text: "different text", wireTimestamp: honest.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: nil
    )
    await #expect(throws: CloudMessageImportError.fingerprintMismatch) {
      try await router.plan(for: tampered, across: [radioA, radioB])
    }

    // Incoming record carrying a foreign local row id.
    let contradictory = CloudMessageRecord(
      fingerprint: honest.fingerprint, conversation: honest.conversation,
      direction: .incoming, text: honest.text, wireTimestamp: honest.wireTimestamp,
      senderNodeName: nil, isRead: false, originMessageID: UUID()
    )
    await #expect(throws: CloudMessageImportError.unexpectedOriginMessageID) {
      try await router.plan(for: contradictory, across: [radioA, radioB])
    }
  }

  /// Descriptions are what reach logs. Portable identity material must not.
  @Test
  func `Routing descriptions redact identity material`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    let secretText = "RENDEZVOUS AT GRID 44821"
    let onA = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: secretText,
      timestamp: Fixture.wireTimestamp, direction: .incoming
    )
    try await store.saveMessage(onA)

    let record = try await Fixture.exportRecord(from: store, message: onA)
    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])

    let rendered = plan.description + plan.decisions.map(\.state.description).joined()
    #expect(!rendered.contains(secretText))
    #expect(!rendered.contains("44821"))
    #expect(!rendered.contains(Fixture.peerKey.uppercaseHexString().prefix(8)))
    #expect(!rendered.contains(Fixture.sharedSecret.uppercaseHexString().prefix(8)))
    #expect(CloudLocalPlacement.direct(contactID: UUID()).description == "direct(contact: <local>)")
    #expect(CloudLocalPlacement.channel(index: 7).description == "channel(slot: 7)")
  }
}

// MARK: - Known limitation

@Suite("CloudMessageRouter — known limitations")
struct CloudMessageRouterLimitationTests {
  /// Matrix 23: the Sprint 1B clock-correction gap, re-verified at the router level.
  ///
  /// Observation detection narrows candidates on `Message.timestamp`, while
  /// portable identity uses `senderTimestamp ?? timestamp`. A clock-corrected row
  /// therefore escapes the window, and the router reports the radio as
  /// `eligibleMissing` rather than `existingObservation` — leading to a duplicate
  /// if the plan is executed.
  ///
  /// The router does not make this worse: it uses exactly the importer's
  /// detection, so both layers miss and recover identically, and the resulting
  /// rows still share one fingerprint. A stored fingerprint column closes it
  /// properly; adding a SwiftData field is out of scope for this sprint.
  @Test
  func `Clock-corrected observation is not detected — known gap, unchanged by routing`() async throws {
    let (store, radioA, radioB) = try await Fixture.makeTwoRadioStore()
    let contactA = try await Fixture.saveContact(in: store, radioID: radioA)
    try await Fixture.saveContact(in: store, radioID: radioB)

    // What MC1 persists when the sender's clock was implausible.
    let corrected = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "skewed clock",
      timestamp: Fixture.wireTimestamp + 999_999, direction: .incoming
    ).copy {
      $0.timestampCorrected = true
      $0.senderTimestamp = Fixture.wireTimestamp
    }
    try await store.saveMessage(corrected)

    let record = try await Fixture.exportRecord(from: store, message: corrected)
    #expect(record.wireTimestamp == Fixture.wireTimestamp)

    let plan = try await CloudMessageRouter(store: store).plan(for: record, across: [radioA, radioB])

    // The gap: radio A holds the message but is not recognized as holding it.
    #expect(
      Fixture.state(plan, radioA)?.existingMessageID == nil,
      "known gap: corrected rows escape the wire-timestamp candidate window"
    )
    #expect(plan.importableRadioIDs.contains(radioA))
  }
}
