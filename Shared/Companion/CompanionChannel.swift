import CryptoKit
import Foundation
import Network

/// One connection between Soundcheck and a companion, over TCP on the local network: packets
/// with a 4-byte length in front, sealed with ChaChaPoly once both sides have shown they hold
/// the pairing key (each direction its own key, numbered so nothing can be replayed or
/// reordered). Everything happens on the channel's own queue; `send` can be called from anywhere.
final class CompanionChannel: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    /// Packets as they arrive (on `queue`).
    var onPacket: ((CompanionPacket) -> Void)?
    /// The connection is ready (on `queue`).
    var onReady: (() -> Void)?
    /// It's closed, for good (on `queue`).
    var onClose: ((String?) -> Void)?

    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var closed = false
    /// Packets bigger than this are a broken or hostile peer.
    private static let largest = 16 << 20

    private let onQueue = DispatchSpecificKey<Bool>()

    init(connection: NWConnection, label: String) {
        self.connection = connection
        queue = DispatchQueue(label: "com.mylesdean.Soundcheck.companion." + label, qos: .userInitiated)
        queue.setSpecific(key: onQueue, value: true)
    }

    /// On the channel's queue (the handshake works there, so keys change between packets).
    var isOnQueue: Bool { DispatchQueue.getSpecific(key: onQueue) == true }

    /// TCP with keepalives, so a companion that's gone (asleep, out of range) is noticed.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // The Wi-Fi network only: Apple's peer-to-peer Wi-Fi (AWDL, as AirDrop uses) stalls for
        // a few hundred milliseconds now and then as it hops channels, which breaks up the sound.
        parameters.includePeerToPeer = false
        // Sound on the link: Wi-Fi's voice queue, which goes first.
        parameters.serviceClass = .interactiveVoice
        return parameters
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .waiting(let error):
                // Not reachable right now: give up rather than wait (the caller tries again).
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            guard let self else { return }
            self.viable = viable
            guard !viable else { return }
            // The way there is gone (Wi-Fi off, the cable out): over, unless it's back in a moment
            // (rather than waiting for the keepalives to give up).
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.viable else { return }
                self.finish("The network went away")
            }
        }
        connection.start(queue: queue)
    }
    private var viable = true

    func close() {
        queue.async { [self] in
            connection.cancel()
            finish(nil)
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
        connection.cancel()
        let onClose = onClose
        self.onClose = nil
        onPacket = nil
        onReady = nil
        onClose?(reason)
    }

    /// From here on, packets are sealed (call on `queue`, between packets).
    func secure(send: SymmetricKey, receive: SymmetricKey) {
        sendKey = send
        receiveKey = receive
        sendCounter = 0
        receiveCounter = 0
    }

    var isSecure: Bool { sendKey != nil }

    func send(_ message: CompanionMessage) { send(.message(message)) }

    /// Sends straight away on the channel's queue (so a packet sent just before `secure` goes in
    /// the clear), or queues it from anywhere else.
    func send(_ packet: CompanionPacket) {
        if isOnQueue { transmit(packet) } else { queue.async { [self] in transmit(packet) } }
    }

    private func transmit(_ packet: CompanionPacket, sent: ((Int) -> Void)? = nil) {
        guard !closed, let plain = try? packet.encoded() else { return }
        var body = plain
        if let key = sendKey {
            guard let sealed = try? ChaChaPoly.seal(plain, using: key, nonce: Self.nonce(sendCounter)) else { return }
            sendCounter += 1
            body = sealed.ciphertext + sealed.tag
        }
        var frame = Data(capacity: body.count + 4)
        frame.appendInteger(UInt32(body.count))
        frame.append(body)
        let size = frame.count
        sent?(size)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if sent != nil { self.inFlight = max(0, self.inFlight - size) }
            if let error { self.finish(error.localizedDescription) }
        })
    }

    /// Sound: past this many bytes waiting to go out (Wi-Fi stalled), frames are dropped rather
    /// than queued (the companion fills the gap), so a stall doesn't build up a backlog.
    func sendAudio(_ packet: CompanionPacket) {
        queue.async { [self] in
            guard inFlight < 384 * 1024 else { return }
            transmit(packet) { self.inFlight += $0 }
        }
    }
    /// Sound bytes handed to the network and not yet taken (on `queue`; completions come there too).
    private var inFlight = 0

    private func receive() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, complete, error in
            guard let self else { return }
            guard let header, header.count == 4, error == nil else {
                self.finish(error?.localizedDescription ?? (complete ? nil : "The connection closed"))
                return
            }
            let length = Int(header.integer32(at: 0))
            guard length > 0, length <= Self.largest else { self.finish("A packet was too big"); return }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, body.count == length, error == nil else {
                    self.finish(error?.localizedDescription ?? "The connection closed")
                    return
                }
                guard let plain = self.open(body) else { self.finish("A packet didn't check out"); return }
                if let packet = CompanionPacket(plain) { self.onPacket?(packet) }
                if !self.closed { self.receive() }
            }
        }
    }

    private func open(_ body: Data) -> Data? {
        guard let key = receiveKey else { return body }
        guard body.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plain = try? ChaChaPoly.open(box, using: key) else { return nil }
        receiveCounter += 1
        return plain
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.appendInteger(counter)
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// The keys: a pairing's key (made once, by an X25519 exchange the Mac's owner approves), proofs
/// that each side has it, and each connection's own keys from it.
enum CompanionCrypto {
    static func randomBytes(_ count: Int = 32) -> Data {
        Data(SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Array($0) })
    }

    /// Shows the other side holds `key`: an HMAC over who's proving it and both nonces.
    static func proof(_ key: SymmetricKey, role: String, client: Data, server: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(role.utf8) + client + server, using: key))
    }

    static func check(_ proof: Data, _ key: SymmetricKey, role: String, client: Data, server: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(role.utf8) + client + server, using: key)
    }

    /// This connection's keys: companion → Mac, and Mac → companion.
    static func sessionKeys(_ key: SymmetricKey, client: Data, server: Data) -> (toMac: SymmetricKey, toCompanion: SymmetricKey) {
        let salt = client + server
        let toMac = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data("Soundcheck companion to Mac".utf8), outputByteCount: 32)
        let toCompanion = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data("Soundcheck Mac to companion".utf8), outputByteCount: 32)
        return (toMac, toCompanion)
    }

    /// The pairing key both sides keep, and the six digits both show so the owner can see
    /// they're talking to each other (and nothing in between).
    static func pairing(_ secret: SharedSecret, client: Data, server: Data, companionKey: Data, macKey: Data) -> (key: SymmetricKey, code: String) {
        let salt = client + server + companionKey + macKey
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("Soundcheck pairing".utf8), outputByteCount: 32)
        let check = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("Soundcheck pairing code".utf8), outputByteCount: 8)
        let number = check.withUnsafeBytes { bytes in bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        let code = String(format: "%06llu", number % 1_000_000)
        return (key, String(code.prefix(3)) + " " + String(code.suffix(3)))
    }
}

/// The Bluetooth side of the link: Soundcheck advertises a small Bluetooth service so it can wake
/// its companions when they're asleep in the background (iOS lets an app that keeps a Bluetooth
/// connection run for a few seconds when the other end has news). Nothing private goes over it:
/// only which event it is, numbered and signed with the pairing key.
enum CompanionBeaconFormat {
    static let service = "9C2F1A40-4B3E-4D6A-8E61-53434B4D4143"
    /// Read: the Mac's ID (its UUID's 16 bytes).
    static let info = "9C2F1A41-4B3E-4D6A-8E61-53434B4D4143"
    /// Notify: events for the companion.
    static let events = "9C2F1A42-4B3E-4D6A-8E61-53434B4D4143"
    /// Write: the companion's hello and answers.
    static let replies = "9C2F1A43-4B3E-4D6A-8E61-53434B4D4143"

    enum Event: UInt8 {
        /// Mac → companion: please connect over Wi-Fi.
        case connect = 1
        /// Mac → companion: is a phone call on?
        case askCall = 2
        /// Mac → companion: play as a speaker (it was picked on the Mac).
        case speaker = 3
        /// Mac → companion: be the microphone (it was picked on the Mac).
        case microphone = 4
        /// Companion → Mac: who it is (pairing and device).
        case hello = 10
        /// Companion → Mac: a call on (1), ringing (2), or neither (0).
        case callState = 11
    }

    /// [event][value][counter, 4 bytes][signature, 8 bytes]
    static func sign(_ event: Event, value: UInt8 = 0, counter: UInt32, key: SymmetricKey, device: String) -> Data {
        var data = Data([event.rawValue, value])
        data.appendInteger(counter)
        data.append(signature(data, key: key, device: device))
        return data
    }

    static func read(_ data: Data, key: SymmetricKey, device: String) -> (event: Event, value: UInt8, counter: UInt32)? {
        guard data.count == 14, let event = Event(rawValue: data[data.startIndex]) else { return nil }
        let body = data.prefix(6)
        guard signature(Data(body), key: key, device: device) == data.suffix(8) else { return nil }
        return (event, data[data.startIndex + 1], Data(body).integer32(at: 2))
    }

    /// The companion's hello: [10][pairing, 16][device, 16][counter, 4][signature, 8].
    static func hello(pairing: UUID, device: UUID, counter: UInt32, key: SymmetricKey) -> Data {
        var data = Data([Event.hello.rawValue])
        data.append(pairing.data)
        data.append(device.data)
        data.appendInteger(counter)
        data.append(signature(data, key: key, device: device.uuidString))
        return data
    }

    static func readHello(_ data: Data) -> (pairing: UUID, device: UUID, counter: UInt32, signed: Data, signature: Data)? {
        guard data.count == 45, data.first == Event.hello.rawValue else { return nil }
        let bytes = Data(data)
        guard let pairing = UUID(data: bytes.subdata(in: 1..<17)), let device = UUID(data: bytes.subdata(in: 17..<33)) else { return nil }
        return (pairing, device, bytes.integer32(at: 33), bytes.prefix(37), bytes.suffix(8))
    }

    static func signature(_ data: Data, key: SymmetricKey, device: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(device.utf8) + data, using: key)).prefix(8)
    }
}

extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }

    init?(data: Data) {
        guard data.count == 16 else { return nil }
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: data) }
        self.init(uuid: bytes)
    }
}
