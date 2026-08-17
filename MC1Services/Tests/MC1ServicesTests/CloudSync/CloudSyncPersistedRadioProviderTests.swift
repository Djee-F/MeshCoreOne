import Foundation
@testable import MC1Services
import Testing

/// §14J: the accepted Sprint 1F domain policy — **all locally known/persisted
/// radios participate in CloudSync history reconciliation** — proven against the
/// real store rather than a stub.
@Suite("CloudSyncPersistedRadioProvider — domain policy")
struct CloudSyncPersistedRadioProviderTests {
  private func makeStore(radioID: UUID) async throws -> PersistenceStore {
    try await PersistenceStore.createTestDataStore(radioID: radioID)
  }

  /// Every persisted radio participates, regardless of `isActive`.
  @Test
  func `All persisted radios participate even when isActive differs`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let radioC = UUID()
    let store = try await makeStore(radioID: radioA)

    // B inactive, C active — the policy must not care.
    try await store.saveDevice(DeviceDTO.testDevice(
      id: radioB, radioID: radioB,
      publicKey: Data(repeating: 0x02, count: ProtocolLimits.publicKeySize),
      isActive: false
    ))
    try await store.saveDevice(DeviceDTO.testDevice(
      id: radioC, radioID: radioC,
      publicKey: Data(repeating: 0x03, count: ProtocolLimits.publicKeySize),
      isActive: true
    ))

    let domain = await CloudSyncPersistedRadioProvider(store: store).participatingRadioIDs()
    #expect(Set(domain) == Set([radioA, radioB, radioC]))
  }

  /// A radio being disconnected — which is not represented on the row at all —
  /// cannot remove it from the domain. `Device` rows persist across BLE drops,
  /// which is exactly why the policy keys on them.
  @Test
  func `Persisted radios remain in the domain regardless of connection state`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let store = try await makeStore(radioID: radioA)
    try await store.saveDevice(DeviceDTO.testDevice(
      id: radioB, radioID: radioB,
      publicKey: Data(repeating: 0x02, count: ProtocolLimits.publicKeySize),
      lastConnected: Date(timeIntervalSince1970: 0),
      isActive: false
    ))

    let domain = await CloudSyncPersistedRadioProvider(store: store).participatingRadioIDs()
    #expect(domain.count == 2)
    #expect(Set(domain) == Set([radioA, radioB]))
  }

  /// Two `Device` rows can share a `radioID` (a re-paired radio re-mints the
  /// surrogate `id` while `radioID` is the reconciliation key), so the domain
  /// must de-duplicate.
  @Test
  func `Duplicate device rows cannot produce duplicate radio IDs`() async throws {
    let radioA = UUID()
    let store = try await makeStore(radioID: radioA)
    // A second Device row for the same radio, distinct surrogate id.
    try await store.saveDevice(DeviceDTO.testDevice(
      id: UUID(), radioID: radioA,
      publicKey: Data(repeating: 0x09, count: ProtocolLimits.publicKeySize)
    ))

    let domain = await CloudSyncPersistedRadioProvider(store: store).participatingRadioIDs()
    #expect(domain == [radioA])
    #expect(Set(domain).count == domain.count)
  }

  /// Deterministic ordering, so a plan built from the domain is reproducible.
  @Test
  func `The domain is returned in a deterministic order`() async throws {
    let radioA = UUID()
    let store = try await makeStore(radioID: radioA)
    for seed in UInt8(2)...UInt8(6) {
      try await store.saveDevice(DeviceDTO.testDevice(
        id: UUID(), radioID: UUID(),
        publicKey: Data(repeating: seed, count: ProtocolLimits.publicKeySize)
      ))
    }

    let provider = CloudSyncPersistedRadioProvider(store: store)
    let first = await provider.participatingRadioIDs()
    let second = await provider.participatingRadioIDs()
    #expect(first == second)
    #expect(first == first.sorted { $0.uuidString < $1.uuidString })
  }

  /// An empty device table yields an empty domain — safe, not an error.
  @Test
  func `An empty device table yields an empty domain`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)

    let domain = await CloudSyncPersistedRadioProvider(store: store).participatingRadioIDs()
    #expect(domain.isEmpty)
  }

  /// Reading the domain must not mutate anything.
  @Test
  func `Reading the domain performs no mutation`() async throws {
    let radioA = UUID()
    let store = try await makeStore(radioID: radioA)
    let before = try await store.fetchAllDevices()

    let provider = CloudSyncPersistedRadioProvider(store: store)
    for _ in 0..<5 { _ = await provider.participatingRadioIDs() }

    #expect(try await store.fetchAllDevices().count == before.count)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
  }

  /// End-to-end: the session driven by the real domain policy reconciles across
  /// every persisted radio, with no explicit radio list supplied by the caller.
  @Test
  func `Session driven by the persisted domain reconciles across all radios`() async throws {
    let radioA = UUID()
    let radioB = UUID()
    let store = try await makeStore(radioID: radioA)
    try await store.saveDevice(DeviceDTO.testDevice(
      id: radioB, radioID: radioB,
      publicKey: Data(repeating: 0x02, count: ProtocolLimits.publicKeySize),
      isActive: false
    ))

    let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 41 })
    let contactA = ContactDTO.testContact(id: UUID(), radioID: radioA, publicKey: peerKey)
    let contactB = ContactDTO.testContact(id: UUID(), radioID: radioB, publicKey: peerKey)
    try await store.saveContact(contactA)
    try await store.saveContact(contactB)

    let received = MessageDTO.testDirectMessage(
      radioID: radioA, contactID: contactA.id, text: "domain wide",
      timestamp: 1_704_067_200, direction: .incoming
    )
    try await store.saveMessage(received)

    let session = CloudMessageSyncSession(
      store: store, radioProvider: CloudSyncPersistedRadioProvider(store: store)
    )
    await session.handle(.directMessageReceived(message: received, contact: contactA))

    // The inactive, disconnected radio B still received the observation.
    #expect(try await store.fetchMessages(contactID: contactB.id, limit: 10, offset: 0).count == 1)
    #expect(await session.processedTriggerCount == 1)
    #expect(try await store.fetchPendingSends(radioID: radioA).isEmpty)
    #expect(try await store.fetchPendingSends(radioID: radioB).isEmpty)
  }
}
