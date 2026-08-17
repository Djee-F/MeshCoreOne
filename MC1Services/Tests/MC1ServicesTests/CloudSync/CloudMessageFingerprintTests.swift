import Foundation
@testable import MC1Services
import Testing

// MARK: - Shared fixtures

private enum Fixture {
  /// Deterministic 32-byte public key, distinct per `seed`.
  static func publicKey(_ seed: UInt8) -> Data {
    Data((0..<UInt8(ProtocolLimits.publicKeySize)).map { $0 &+ seed })
  }

  /// Deterministic 16-byte channel secret, distinct per `seed`.
  static func channelSecret(_ seed: UInt8) -> Data {
    Data((0..<UInt8(ProtocolLimits.channelSecretSize)).map { $0 &* 3 &+ seed })
  }

  static let alice = publicKey(1)
  static let bob = publicKey(2)
  static let generalChannel = channelSecret(1)
  static let opsChannel = channelSecret(2)
  static let timestamp: UInt32 = 1_704_067_200
}

// MARK: - Incoming direct messages

@Suite("CloudMessageFingerprint — incoming direct messages")
struct CloudMessageFingerprintIncomingDirectTests {
  /// The headline cross-install invariant. Two installs hold the same logical DM
  /// with entirely disjoint local identity — different `Message.id`,
  /// `Contact.id`, and `radioID` — yet agree on peer key, wire timestamp, and
  /// text. Identity must converge.
  @Test
  func `Same logical DM converges across installs despite different local identifiers`() {
    let iPhoneRow = MessageDTO.testDirectMessage(
      id: UUID(), radioID: UUID(), contactID: UUID(),
      text: "meet at the ridge", timestamp: Fixture.timestamp, direction: .incoming
    )
    let iPadRow = MessageDTO.testDirectMessage(
      id: UUID(), radioID: UUID(), contactID: UUID(),
      text: "meet at the ridge", timestamp: Fixture.timestamp, direction: .incoming
    )

    // Every local identifier differs — including the radio, which is not an input.
    #expect(iPhoneRow.id != iPadRow.id)
    #expect(iPhoneRow.radioID != iPadRow.radioID)
    #expect(iPhoneRow.contactID != iPadRow.contactID)

    let iPhone = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice,
      wireTimestamp: iPhoneRow.reactionTimestamp,
      text: iPhoneRow.text
    )
    let iPad = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice,
      wireTimestamp: iPadRow.reactionTimestamp,
      text: iPadRow.text
    )
    #expect(iPhone == iPad)
  }

  @Test
  func `Different peer public keys produce different fingerprints`() {
    let fromAlice = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let fromBob = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.bob, wireTimestamp: Fixture.timestamp, text: "hello"
    )
    #expect(fromAlice != fromBob)
  }

  @Test
  func `Different wire timestamps produce different fingerprints`() {
    let first = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let second = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp + 1, text: "hello"
    )
    #expect(first != second)
  }

  @Test
  func `Different content produces different fingerprints`() {
    let first = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let second = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "hello!"
    )
    #expect(first != second)
  }
}

// MARK: - Incoming channel messages

@Suite("CloudMessageFingerprint — incoming channel messages")
struct CloudMessageFingerprintIncomingChannelTests {
  /// A channel sitting at slot 3 on one radio and slot 7 on another is the same
  /// channel: identity is the secret, the slot is placement. Backup import
  /// already relocates channels between slots for exactly this reason.
  @Test
  func `Same channel at different local slots converges`() throws {
    let onRadioA = MessageDTO.testChannelMessage(
      radioID: UUID(), channelIndex: 3, text: "net at 1900",
      timestamp: Fixture.timestamp, direction: .incoming, senderNodeName: "Alice"
    )
    let onRadioB = MessageDTO.testChannelMessage(
      radioID: UUID(), channelIndex: 7, text: "net at 1900",
      timestamp: Fixture.timestamp, direction: .incoming, senderNodeName: "Alice"
    )
    #expect(onRadioA.radioID != onRadioB.radioID)
    #expect(onRadioA.channelIndex != onRadioB.channelIndex)

    let first = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel,
      channelIndex: try #require(onRadioA.channelIndex),
      senderNodeName: onRadioA.senderNodeName,
      wireTimestamp: onRadioA.reactionTimestamp,
      text: onRadioA.text
    )
    let second = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel,
      channelIndex: try #require(onRadioB.channelIndex),
      senderNodeName: onRadioB.senderNodeName,
      wireTimestamp: onRadioB.reactionTimestamp,
      text: onRadioB.text
    )
    #expect(first == second)
  }

  @Test
  func `Different channel secrets produce different fingerprints`() {
    let general = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let ops = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.opsChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    #expect(general != ops)
  }

  @Test
  func `Different sender node names produce different fingerprints`() {
    let alice = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let bob = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Bob", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    #expect(alice != bob)
  }

  @Test
  func `Different wire timestamps and content produce different channel fingerprints`() {
    let base = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let laterTimestamp = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp + 1, text: "hello"
    )
    let otherText = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello there"
    )
    #expect(base != laterTimestamp)
    #expect(base != otherText)
  }

  /// The public channel and unconfigured slots carry an empty or all-zero
  /// secret, which is not an identity. They fall back to slot identity, matching
  /// backup import's `channelHasStableSecret(_:)`. Without the fallback, every
  /// install's empty-secret slots would hash alike.
  @Test(arguments: [Data(), Data(repeating: 0, count: ProtocolLimits.channelSecretSize)])
  func `Channels without a stable secret fall back to slot identity`(secret: Data) {
    let slot0 = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: secret, channelIndex: 0,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let slot1 = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: secret, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    // Distinct empty-secret slots must stay distinct...
    #expect(slot0 != slot1)
    // ...and must never alias a real secret-identified channel.
    #expect(slot0 != CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 0,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    ))
  }

  /// A stable secret makes the slot irrelevant; only the fallback path reads it.
  @Test
  func `Slot index is ignored when the channel secret is stable`() {
    let atSlot1 = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let atSlot9 = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 9,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    #expect(atSlot1 == atSlot9)
  }

  /// DOCUMENTED PROTOCOL LIMITATION, not a defect.
  ///
  /// `Parsers+Messaging.ChannelMessage.parse` decodes channelIndex, pathLength,
  /// textType, senderTimestamp and payload — there is no sender public key on
  /// the channel wire. The only sender identity is the self-asserted
  /// `"NodeName: "` prefix. Two distinct operators both named "Alice", posting
  /// identical text in the same second on the same channel, cannot be told
  /// apart by any layer above the protocol.
  @Test
  func `Two senders sharing a node name are indistinguishable — protocol limitation`() {
    let firstAlice = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "roger"
    )
    let secondAlice = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "roger"
    )
    #expect(
      firstAlice == secondAlice,
      "protocol limitation: the channel wire format carries no sender public key"
    )
  }

  /// A payload with no node-name prefix must not alias one with an empty name.
  @Test
  func `Nil and empty sender node names do not alias`() {
    let absent = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: nil, wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let empty = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    #expect(absent != empty)
  }
}

// MARK: - Outgoing messages

@Suite("CloudMessageFingerprint — outgoing messages")
struct CloudMessageFingerprintOutgoingTests {
  /// An outgoing message has exactly one author, so identity is its origin
  /// `Message.id`. Two intentional sends that agree on text, timestamp and
  /// recipient must stay distinct — content hashing alone could not do this.
  @Test
  func `Two separate sends with identical text and timestamp remain distinct`() {
    let firstSend = MessageDTO.testDirectMessage(
      text: "ok", timestamp: Fixture.timestamp, direction: .outgoing
    )
    let secondSend = MessageDTO.testDirectMessage(
      text: "ok", timestamp: Fixture.timestamp, direction: .outgoing
    )
    #expect(firstSend.text == secondSend.text)
    #expect(firstSend.timestamp == secondSend.timestamp)

    #expect(
      CloudMessageFingerprint.outgoing(originMessageID: firstSend.id)
        != CloudMessageFingerprint.outgoing(originMessageID: secondSend.id)
    )
  }

  /// `resendDirectMessage(preserveTimestamp: false)` re-stamps `Message.timestamp`
  /// through `updateMessageTimestamp`, so a content-derived key would change
  /// mid-life and the synced copy would fork. Keying on `Message.id` is stable.
  @Test
  func `A resend keeps its identity when MC1 re-stamps the timestamp`() {
    let original = MessageDTO.testDirectMessage(
      text: "ping", timestamp: Fixture.timestamp, direction: .outgoing
    )
    // What MC1 does on resend: same row, new wire timestamp, bumped send count.
    let afterResend = original.copy {
      $0.timestamp = Fixture.timestamp + 42
      $0.sendCount = 2
      $0.status = .sent
    }
    #expect(afterResend.id == original.id)
    #expect(afterResend.timestamp != original.timestamp)

    #expect(
      CloudMessageFingerprint.outgoing(originMessageID: original.id)
        == CloudMessageFingerprint.outgoing(originMessageID: afterResend.id)
    )
  }

  @Test
  func `Outgoing fingerprints never collide with incoming fingerprints`() {
    let outgoing = CloudMessageFingerprint.outgoing(originMessageID: UUID())
    let dm = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let channel = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    #expect(outgoing != dm)
    #expect(outgoing != channel)
    #expect(dm != channel)
  }
}

// MARK: - Encoding safety, privacy, determinism

@Suite("CloudMessageFingerprint — safety")
struct CloudMessageFingerprintSafetyTests {
  /// Nothing recoverable may reach the output: not the body, not the node name,
  /// not the channel secret, not a public key.
  @Test
  func `Fingerprints leak no content, node name, secret, or key material`() {
    let secretText = "RENDEZVOUS AT GRID 44821"
    let dm = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: secretText
    )
    let channel = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: secretText
    )

    for fingerprint in [dm, channel] {
      #expect(!fingerprint.contains(secretText))
      #expect(!fingerprint.contains("RENDEZVOUS"))
      #expect(!fingerprint.contains("44821"))
      #expect(!fingerprint.lowercased().contains("rendezvous"))
    }
    #expect(!channel.contains("Alice"))
    #expect(!channel.contains(Fixture.generalChannel.uppercaseHexString().prefix(16)))
    #expect(!dm.contains(Fixture.alice.uppercaseHexString().prefix(16)))

    // The origin UUID must not survive into an outgoing fingerprint either.
    let originID = UUID()
    #expect(!CloudMessageFingerprint.outgoing(originMessageID: originID).contains(originID.uuidString))
  }

  @Test
  func `Fingerprints are deterministic across repeated execution`() {
    let compute = {
      CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "stable"
      )
    }
    let baseline = compute()
    for _ in 0..<64 {
      #expect(compute() == baseline)
    }
  }

  /// Field boundaries are length-prefixed, so content cannot be shifted across a
  /// boundary. Without this a crafted node name could forge another message's
  /// identity by borrowing the leading characters of the body.
  @Test
  func `Adjacent fields cannot be shifted without changing the fingerprint`() {
    let nameCarriesBob = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "AliceBob", wireTimestamp: Fixture.timestamp, text: "hello"
    )
    let textCarriesBob = CloudMessageFingerprint.incomingChannelMessage(
      channelSecret: Fixture.generalChannel, channelIndex: 1,
      senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "Bobhello"
    )
    #expect(nameCarriesBob != textCarriesBob)
  }

  @Test
  func `Unicode content is handled deterministically`() {
    let accented = CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "rendez-vous 🏔️ à 19h"
    )
    #expect(accented == CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "rendez-vous 🏔️ à 19h"
    ))
    #expect(accented != CloudMessageFingerprint.incomingDirectMessage(
      peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "rendez-vous 🏔️ a 19h"
    ))
  }

  @Test(arguments: ["dm", "ch", "out"])
  func `Fingerprint format is scheme-tagged and fixed width`(kind: String) {
    let fingerprint = switch kind {
    case "dm":
      CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Fixture.alice, wireTimestamp: Fixture.timestamp, text: "hello"
      )
    case "ch":
      CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Fixture.generalChannel, channelIndex: 1,
        senderNodeName: "Alice", wireTimestamp: Fixture.timestamp, text: "hello"
      )
    default:
      CloudMessageFingerprint.outgoing(originMessageID: UUID())
    }

    let prefix = "cmf1-\(kind)-"
    #expect(fingerprint.hasPrefix(prefix))
    let digest = fingerprint.dropFirst(prefix.count)
    #expect(digest.count == 64)
    #expect(digest.allSatisfy { $0.isHexDigit && !$0.isLowercase })
  }

  /// Golden vectors. These pin the exact on-the-wire encoding without
  /// re-implementing it in the test. A stored CloudSync key must keep meaning
  /// the same message forever, so any change to field order, framing, domain
  /// tags, or endianness must break this test and force a `scheme` bump.
  @Test
  func `Golden vectors pin the encoding`() {
    #expect(
      CloudMessageFingerprint.incomingDirectMessage(
        peerPublicKey: Data((0..<32).map { UInt8($0) }),
        wireTimestamp: 1_704_067_200,
        text: "hello"
      ) == "cmf1-dm-C0BAE67229E45C23EE766E71E1BDF7590F1E539E98A3383C45E0B46F27A964DC"
    )
    #expect(
      CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Data((0..<16).map { UInt8($0) }),
        channelIndex: 3,
        senderNodeName: "Alice",
        wireTimestamp: 1_704_067_200,
        text: "hello"
      ) == "cmf1-ch-B180FF84B817F7FE44192CCD3F113B8E69ED83F2755FD95EC15F0B4887320149"
    )
    #expect(
      CloudMessageFingerprint.incomingChannelMessage(
        channelSecret: Data(),
        channelIndex: 0,
        senderNodeName: nil,
        wireTimestamp: 1_704_067_200,
        text: "hello"
      ) == "cmf1-ch-5460927DFAC2B02107D015B029B3CE0366A129DF7255173FE54D90A657C60CB0"
    )
    #expect(
      CloudMessageFingerprint.outgoing(
        originMessageID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
      ) == "cmf1-out-AFBCCCFD1CDDECD64C66D8FBE7C1BB9A8128B6585817A479343849F0D51DAE49"
    )
  }
}
