import Foundation
@testable import MC1Services

/// Shared fixtures for the Sprint 2D automatic-synchronization suites.
///
/// Everything here works against an ordinary temporary directory. No Apple ID,
/// no iCloud Drive, no network, no paid membership, no document picker, and no
/// real `NSMetadataQuery` event is required by any test that uses it.
enum CloudSyncFx {
  static let peerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 31 })
  static let otherPeerKey = Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ 131 })
  static let secret = Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &+ 17 })
  static let ts: UInt32 = 1_712_000_000

  static func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mc1-2d-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func files(_ root: URL) -> CloudMessageDirectoryStore {
    CloudMessageDirectoryStore(root: root)
  }

  // MARK: - Installations

  /// One installation: an independent store with two persisted radios, its own
  /// transport onto a shared folder, and its own scheduler.
  ///
  /// Two of these over one folder is the whole point — it is how a test proves
  /// convergence between devices without owning two devices.
  struct Installation {
    let store: PersistenceStore
    let radioA: UUID
    let radioB: UUID
    let transport: CloudMessageFolderTransport
    let scheduler: CloudMessageSyncScheduler
    let monitor: CloudSyncManualFolderMonitor

    /// Reconciles and waits for the pass to finish.
    @discardableResult
    func reconcile() async -> CloudMessageReconciliationSummary {
      await scheduler.reconcileNow()
    }

    /// Delivers `count` folder-change hints and waits for the work they cause.
    func signal(_ count: Int = 1) async {
      monitor.emitBurst(count)
      await settle()
    }

    /// Waits until no pass is in flight.
    func settle() async {
      // Give the observation task room to consume the emitted hints before
      // asking the scheduler whether it is busy; without this the check could
      // run before the first hint has been picked up at all.
      for _ in 0..<10 { await Task.yield() }
      await scheduler.awaitPassesForTesting()
    }
  }

  static func makeInstallation(folder: URL) async throws -> Installation {
    let radioA = UUID()
    let radioB = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioA)
    try await store.saveDevice(DeviceDTO.testDevice(
      id: radioB, radioID: radioB,
      publicKey: Data(repeating: 0x5A, count: ProtocolLimits.publicKeySize)
    ))

    let radios = CloudSyncPersistedRadioProvider(store: store)
    let transport = CloudMessageFolderTransport(
      folderProvider: CloudSyncStaticFolderProvider(url: folder),
      coordinator: CloudMessageSyncCoordinator(store: store),
      radioProvider: radios
    )
    let monitor = CloudSyncManualFolderMonitor()
    let scheduler = CloudMessageSyncScheduler(
      transport: transport,
      // Injected so coalescing and retry never depend on wall-clock timing.
      sleeper: CloudSyncImmediateSleeper(),
      coalescingWindow: .zero,
      pendingDownloadRetryDelay: .zero
    )
    await scheduler.start(monitor: monitor)

    return Installation(
      store: store, radioA: radioA, radioB: radioB,
      transport: transport, scheduler: scheduler, monitor: monitor
    )
  }

  // MARK: - Conversation setup

  /// Gives both of an installation's radios a contact for `peerPublicKey`.
  @discardableResult
  static func addContacts(
    _ installation: Installation, publicKey: Data = peerKey
  ) async throws -> (UUID, UUID) {
    let a = ContactDTO.testContact(id: UUID(), radioID: installation.radioA, publicKey: publicKey)
    let b = ContactDTO.testContact(id: UUID(), radioID: installation.radioB, publicKey: publicKey)
    try await installation.store.saveContact(a)
    try await installation.store.saveContact(b)
    return (a.id, b.id)
  }

  /// Gives an installation's two radios the same channel secret in *different*
  /// local slots, which is what proves slot numbers never cross radios.
  static func addChannels(
    _ installation: Installation, slotA: UInt8, slotB: UInt8, secret: Data = secret
  ) async throws {
    try await installation.store.saveChannel(
      ChannelDTO.testChannel(radioID: installation.radioA, index: slotA, secret: secret))
    try await installation.store.saveChannel(
      ChannelDTO.testChannel(radioID: installation.radioB, index: slotB, secret: secret))
  }

  // MARK: - Records

  static func incomingDM(
    text: String, isRead: Bool = false, publicKey: Data = peerKey, timestamp: UInt32 = ts
  ) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: publicKey, wireTimestamp: timestamp, text: text),
      conversation: .direct(peerPublicKey: publicKey),
      direction: .incoming, text: text, wireTimestamp: timestamp,
      senderNodeName: nil, isRead: isRead, originMessageID: nil)
  }

  static func strongChannel(text: String, senderNodeName: String = "Alice") -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: secret, channelIndex: 0, senderNodeName: senderNodeName,
        wireTimestamp: ts, text: text),
      conversation: .channelSecret(secret),
      direction: .incoming, text: text, wireTimestamp: ts,
      senderNodeName: senderNodeName, isRead: false, originMessageID: nil)
  }

  static func weakChannel(slot: UInt8, text: String) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Data(), channelIndex: slot, senderNodeName: "Alice",
        wireTimestamp: ts, text: text),
      conversation: .channelSlot(slot),
      direction: .incoming, text: text, wireTimestamp: ts,
      senderNodeName: "Alice", isRead: false, originMessageID: nil)
  }

  static func outgoing(text: String, originMessageID: UUID = UUID()) -> CloudMessageRecord {
    CloudMessageRecord(
      fingerprint: CloudMessageFingerprint.outgoing(originMessageID: originMessageID),
      conversation: .direct(peerPublicKey: peerKey),
      direction: .outgoing, text: text, wireTimestamp: ts,
      senderNodeName: nil, isRead: false, originMessageID: originMessageID)
  }
}
