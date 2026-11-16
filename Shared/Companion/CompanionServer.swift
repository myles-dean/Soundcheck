import CryptoKit
import Foundation

/// What the Mac's side of a connection reports, from the channel's queue.
protocol CompanionServerDelegate: AnyObject, Sendable {
    /// It proved it holds a pairing's key: from here on its packets are sealed.
    func authenticated(_ peer: CompanionServerPeer, _ hello: CompanionHello)
    /// A companion the Mac doesn't know asks to pair; `code` is what both show.
    func askedToPair(_ peer: CompanionServerPeer, _ hello: CompanionHello, key: SymmetricKey, code: String)
    /// A message from an authenticated companion.
    func received(_ message: CompanionMessage, from peer: CompanionServerPeer)
    /// Sound from an authenticated companion's microphone (on the channel's queue: don't block).
    func receivedMicrophone(_ samples: Data, from peer: CompanionServerPeer)
}

/// The Mac's side of one connection: the handshake (on the channel's queue, so the keys change
/// exactly between packets), then packets passed on to the delegate. Clock pings are answered
/// right here, so they're as quick as they can be.
class CompanionServerPeer: @unchecked Sendable {
    let channel: CompanionChannel
    private let keys: PairingKeys
    private let macID: String
    private let macName: String
    private weak var delegate: CompanionServerDelegate?
    private let lock = NSLock()
    private var _device: String?
    private(set) var hello: CompanionHello?
    private var serverNonce = Data()
    private var pairingPrivate: Curve25519.KeyAgreement.PrivateKey?

    /// The companion's device ID, once it's proven it's paired.
    var device: String? { lock.withLock { _device } }

    init(channel: CompanionChannel, keys: PairingKeys, macID: String, macName: String, delegate: CompanionServerDelegate) {
        self.channel = channel
        self.keys = keys
        self.macID = macID
        self.macName = macName
        self.delegate = delegate
        channel.onPacket = { [weak self] packet in self?.received(packet) }
    }

    private func received(_ packet: CompanionPacket) {
        if device != nil {
            switch packet {
            case .ping(let asked):
                channel.send(.pong(asked, HostClock.now))
            case .micAudio(let samples):
                delegate?.receivedMicrophone(samples, from: self)
            case .message(let message):
                delegate?.received(message, from: self)
            default:
                break
            }
            return
        }
        guard case .message(let message) = packet else { return }
        switch message {
        case .hello(let hello):
            guard hello.version == Companion.version, hello.nonce.count == 32 else { channel.close(); return }
            self.hello = hello
            guard let key = keys.key(hello.pairing) else {
                channel.send(.unknownPairing(mac: macID, name: macName))
                return
            }
            serverNonce = CompanionCrypto.randomBytes()
            let proof = CompanionCrypto.proof(key, role: "mac", client: hello.nonce, server: serverNonce)
            channel.send(.challenge(nonce: serverNonce, proof: proof, mac: macID, name: macName))
        case .proof(let proof):
            guard let hello, let key = keys.key(hello.pairing),
                  CompanionCrypto.check(proof, key, role: "companion", client: hello.nonce, server: serverNonce) else {
                channel.close()
                return
            }
            let session = CompanionCrypto.sessionKeys(key, client: hello.nonce, server: serverNonce)
            channel.secure(send: session.toCompanion, receive: session.toMac)
            lock.withLock { _device = hello.device }
            delegate?.authenticated(self, hello)
        case .pair(let publicKey):
            guard let hello, pairingPrivate == nil,
                  let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) else { channel.close(); return }
            let mine = Curve25519.KeyAgreement.PrivateKey()
            pairingPrivate = mine
            serverNonce = CompanionCrypto.randomBytes()
            guard let secret = try? mine.sharedSecretFromKeyAgreement(with: theirs) else { channel.close(); return }
            let pairing = CompanionCrypto.pairing(secret, client: hello.nonce, server: serverNonce,
                                                  companionKey: publicKey, macKey: mine.publicKey.rawRepresentation)
            // The Mac's public key, then its nonce.
            channel.send(.pairKey(publicKey: mine.publicKey.rawRepresentation + serverNonce))
            delegate?.askedToPair(self, hello, key: pairing.key, code: pairing.code)
        default:
            break
        }
    }
}

/// The pairing keys, by pairing ID, readable from the channels' queues during the handshake.
final class PairingKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]

    func key(_ pairing: String) -> SymmetricKey? { lock.withLock { keys[pairing] } }
    func set(_ key: SymmetricKey?, for pairing: String) { lock.withLock { keys[pairing] = key } }
    var all: [String: SymmetricKey] { lock.withLock { keys } }
}
