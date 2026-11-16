import CryptoKit
import Foundation
import Network
import Observation
import UIKit
import os

let companionLog = Logger(subsystem: "com.mylesdean.Soundcheck.Companion", category: "link")

/// The companion's link to Soundcheck on a Mac: finds Macs on the network, pairs (once, with
/// the owner's OK on the Mac), keeps an encrypted connection, keeps the Mac's state and icons,
/// sends commands, and keeps time with the Mac's clock so sound plays in sync.
@MainActor
@Observable
final class MacLink {
    static let shared = MacLink()

    struct FoundMac: Identifiable, Equatable {
        var id: String
        var name: String
        /// "laptopcomputer", "desktopcomputer" or "macmini" (from what it advertises).
        var symbol: String
        var endpoint: NWEndpoint
    }

    enum Status: Equatable {
        case searching
        case connecting(String)
        /// Waiting for the Mac's owner to allow this device; both show `code`.
        case pairing(name: String, code: String)
        case refused(String)
        case connected
    }

    private(set) var found: [FoundMac] = []
    private(set) var status: Status = .searching
    private(set) var state: RemoteState?
    private(set) var icons: [String: UIImage] = [:]
    /// The Mac being controlled (kept across launches).
    private(set) var macID: String? = UserDefaults.standard.string(forKey: "macID")
    var isConnected: Bool { status == .connected }
    /// The Mac being connected to or paired with (or else the only one there is).
    var currentMac: FoundMac? { macID.flatMap { id in found.first { $0.id == id } } ?? (found.count == 1 ? found.first : nil) }

    /// The chosen Mac is on the network (so a lost link is only a moment's drop).
    var chosenMacIsAround: Bool { macID.map { id in found.contains { $0.id == id } } ?? false }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var channel: CompanionChannel?
    @ObservationIgnored private var retry: DispatchWorkItem?
    @ObservationIgnored private var pending: [String: RemoteCommand] = [:]
    @ObservationIgnored private var flush: DispatchWorkItem?
    @ObservationIgnored private var waiters: [(Bool) -> Void] = []
    /// The Mac's clock, and the link for sound (both used off the main thread).
    nonisolated static let clock = MacClock()
    nonisolated static let audio = AudioLink()
    @ObservationIgnored private var pingTimer: Timer?
    @ObservationIgnored private var wantsLink = false
    /// Watches for the network coming back (or changing), to look for the Mac again at once.
    @ObservationIgnored private var network: NWPathMonitor?
    @ObservationIgnored private var lastNetwork: String?
    /// Tries since the last connection (the wait between them grows a little).
    @ObservationIgnored private var attempts = 0
    /// A main bar value set here, kept over the Mac's replies until it's caught up.
    @ObservationIgnored private var localKnob: (value: Float, until: Date)?
    /// What the Mac last said the main bar is at (shown once the local value's moment is up).
    @ObservationIgnored private var macKnob: Float?

    private init() {}

    // MARK: Finding Macs

    /// Looks for Macs and keeps a connection to the chosen one (while the app is open, or it's
    /// playing or listening, or something woke it).
    func activate() {
        wantsLink = true
        watchNetwork()
        // Not connected: look afresh. A search kept from before the app was suspended, or from
        // another network, can be dead without saying so (iOS drops it while the app sleeps).
        if channel == nil { restartBrowsing() } else { startBrowsing() }
        connectIfNeeded()
    }

    /// The app went to the background with nothing to do there: the link closes (iOS would
    /// close it anyway).
    func deactivate() {
        wantsLink = false
        browser?.cancel()
        browser = nil
        network?.cancel()
        network = nil
        lastNetwork = nil
        retry?.cancel()
        attempts = 0
        channel?.close()
        channel = nil
        if case .connected = status { status = .searching }
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Companion.serviceType, domain: nil), using: CompanionChannel.parameters())
        browser.browseResultsChangedHandler = { [weak browser] results, _ in
            var macs: [FoundMac] = []
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                var id = name, symbol = "laptopcomputer"
                if case .bonjour(let txt) = result.metadata {
                    if let value = txt["id"] { id = value }
                    if let value = txt["sym"], !value.isEmpty { symbol = value }
                }
                // The same Mac on more than one network (Wi-Fi and a cable): once.
                if !macs.contains(where: { $0.id == id }) {
                    macs.append(FoundMac(id: id, name: name, symbol: symbol, endpoint: result.endpoint))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let link = MacLink.shared
                    guard let browser, link.browser === browser else { return }
                    link.found = macs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    companionLog.notice("Found: \(macs.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "), privacy: .public); chosen \(link.macID ?? "none", privacy: .public)")
                    link.connectIfNeeded()
                }
            }
        }
        browser.stateUpdateHandler = { [weak browser] state in
            switch state {
            case .failed(let error):
                companionLog.error("Browsing failed: \(error.localizedDescription, privacy: .public)")
                // A failed search is over for good: start another.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated {
                        let link = MacLink.shared
                        guard let browser, link.browser === browser, link.wantsLink else { return }
                        link.restartBrowsing()
                    }
                }
            case .waiting(let error):
                companionLog.notice("Browsing waiting: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// A new search (what the old one found stays listed until the new one reports).
    private func restartBrowsing() {
        browser?.cancel()
        browser = nil
        startBrowsing()
    }

    /// When the network comes back or changes (Wi-Fi rejoined, a cable plugged in or out), looks
    /// for the Mac again straight away, rather than on a search that may have gone stale.
    private func watchNetwork() {
        guard network == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let summary = path.status == .satisfied
                ? path.availableInterfaces.filter { $0.type != .cellular }.map(\.name).sorted().joined(separator: ",")
                : "none"
            DispatchQueue.main.async { MainActor.assumeIsolated { MacLink.shared.networkChanged(summary) } }
        }
        monitor.start(queue: .main)
        network = monitor
    }

    private func networkChanged(_ summary: String) {
        guard summary != lastNetwork else { return }
        let first = lastNetwork == nil
        lastNetwork = summary
        guard !first, wantsLink else { return }
        companionLog.notice("Network now: \(summary, privacy: .public)")
        guard !isConnected, summary != "none" else { return }
        if case .pairing = status { return }
        attempts = 0
        restartBrowsing()
        if let channel {
            // A try begun on the old network: start it over (it comes back here when it's closed).
            channel.close()
        } else {
            retry?.cancel()
            connectIfNeeded()
        }
    }

    /// Picks a Mac to control (from the list, the first time or to switch).
    func choose(_ mac: FoundMac) {
        macID = mac.id
        UserDefaults.standard.set(mac.id, forKey: "macID")
        SharedState.macID = mac.id
        channel?.close()
        channel = nil
        state = nil
        icons = [:]
        connect(to: mac)
        VolumeButtons.shared.update()
    }

    /// The Mac to connect to: the chosen one, or the only paired one, or the only one there is.
    /// The chosen one is tried by name even when the search hasn't listed it (yet).
    private var target: FoundMac? {
        if let macID, let mac = found.first(where: { $0.id == macID }) { return mac }
        let paired = found.filter { PairingStore.pairing(for: $0.id) != nil }
        if macID == nil, paired.count == 1 { return paired.first }
        if macID == nil, found.count == 1 { return found.first }
        if let lastKnown { return lastKnown }
        return nil
    }

    /// The chosen Mac as last seen (its Bonjour name), to connect to without waiting for the
    /// search: just back on Wi-Fi, the search can take a while to list it again.
    private var lastKnown: FoundMac? {
        guard let macID, PairingStore.pairing(for: macID) != nil,
              let name = UserDefaults.standard.string(forKey: "macService") else { return nil }
        return FoundMac(id: macID, name: name, symbol: UserDefaults.standard.string(forKey: "macSymbol") ?? "laptopcomputer",
                        endpoint: .service(name: name, type: Companion.serviceType, domain: "local.", interface: nil))
    }

    private func connectIfNeeded() {
        guard wantsLink, channel == nil, let mac = target else { return }
        connect(to: mac)
    }

    // MARK: Connecting

    private func connect(to mac: FoundMac) {
        let listed = found.contains { $0.id == mac.id }
        companionLog.notice("Connecting to \(mac.name, privacy: .public) [\(mac.id, privacy: .public)]\(listed ? "" : " (by name)", privacy: .public)")
        retry?.cancel()
        if macID != mac.id {
            macID = mac.id
            UserDefaults.standard.set(mac.id, forKey: "macID")
            SharedState.macID = mac.id
        }
        if listed {
            UserDefaults.standard.set(mac.name, forKey: "macService")
            UserDefaults.standard.set(mac.symbol, forKey: "macSymbol")
            status = .connecting(mac.name)
        }
        // By name, the Mac may well not be there: still "looking" until it answers.
        let channel = CompanionChannel(connection: NWConnection(to: mac.endpoint, using: CompanionChannel.parameters()), label: "link")
        self.channel = channel
        let handshake = Handshake(mac: mac, channel: channel)
        channel.onReady = {
            companionLog.notice("Link ready; saying hello")
            handshake.begin()
        }
        channel.onPacket = { packet in handshake.received(packet) }
        channel.onClose = { reason in
            DispatchQueue.main.async { MainActor.assumeIsolated { MacLink.shared.closed(channel, reason) } }
        }
        channel.start()
    }

    private func closed(_ closed: CompanionChannel, _ reason: String?) {
        guard closed === channel else { return }
        channel = nil
        pingTimer?.invalidate()
        pingTimer = nil
        Self.clock.reset()
        Self.audio.channel = nil
        if case .refused = status {} else { status = .searching }
        companionLog.notice("Link closed: \(reason ?? "", privacy: .public)")
        SpeakerPlayer.shared.linkLost()
        MicStreamer.shared.linkLost()
        VolumeButtons.shared.update()
        // Anyone waiting for the link keeps waiting while it's tried again (just back on Wi-Fi,
        // the first tries often fail); they hear no only if it won't be.
        var refused = false
        if case .refused = status { refused = true }
        if refused || !wantsLink {
            let waiting = waiters
            waiters = []
            waiting.forEach { $0(false) }
        }
        // Refused on the Mac: wait for Try Again rather than asking over and over.
        guard wantsLink, !refused else { return }
        // Soon at first, then every few seconds (the Mac may be away, or asleep).
        attempts += 1
        let work = DispatchWorkItem { MainActor.assumeIsolated { MacLink.shared.connectIfNeeded() } }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(1.5 * Double(attempts), 6), execute: work)
    }

    /// The handshake, on the channel's queue: show the Mac holds the pairing key and prove this
    /// device does too, or pair for the first time.
    private final class Handshake: @unchecked Sendable {
        let mac: FoundMac
        let channel: CompanionChannel
        var nonce = CompanionCrypto.randomBytes()
        var pairing: PairingStore.Pairing?
        var pairingID = UUID().uuidString
        var privateKey: Curve25519.KeyAgreement.PrivateKey?
        var newKey: SymmetricKey?
        var done = false

        init(mac: FoundMac, channel: CompanionChannel) {
            self.mac = mac
            self.channel = channel
            pairing = PairingStore.pairing(for: mac.id)
            if let pairing { pairingID = pairing.pairing }
        }

        func begin() {
            channel.send(.hello(CompanionHello(pairing: pairingID, device: PairingStore.deviceID, name: PairingStore.deviceKind,
                                               kind: PairingStore.deviceKind, nonce: nonce, version: Companion.version)))
        }

        func received(_ packet: CompanionPacket) {
            if done {
                MacLink.received(packet, from: channel)
                return
            }
            guard case .message(let message) = packet else { return }
            companionLog.notice("Handshake: \(String(describing: message).prefix(40), privacy: .public)")
            switch message {
            case .challenge(let serverNonce, let proof, let macID, let name):
                guard let key = pairing?.symmetricKey,
                      CompanionCrypto.check(proof, key, role: "mac", client: nonce, server: serverNonce) else {
                    // The Mac doesn't have our key (forgotten there): pair again.
                    companionLog.notice("The Mac's proof didn't check out; pairing again")
                    PairingStore.forget(mac.id)
                    channel.close()
                    return
                }
                channel.send(.proof(CompanionCrypto.proof(key, role: "companion", client: nonce, server: serverNonce)))
                let session = CompanionCrypto.sessionKeys(key, client: nonce, server: serverNonce)
                channel.secure(send: session.toMac, receive: session.toCompanion)
                done = true
                if var pairing, pairing.macName != name {
                    pairing.macName = name
                    PairingStore.save(pairing)
                }
                _ = macID
                let channel = channel
                DispatchQueue.main.async { MainActor.assumeIsolated { MacLink.shared.connected(channel) } }
            case .unknownPairing:
                // Not paired with this Mac (or it forgot us): ask to.
                if pairing != nil { PairingStore.forget(mac.id); pairing = nil }
                let key = Curve25519.KeyAgreement.PrivateKey()
                privateKey = key
                channel.send(.pair(publicKey: key.publicKey.rawRepresentation))
            case .pairKey(let reply):
                guard let privateKey, reply.count == 64,
                      let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: reply.prefix(32)),
                      let secret = try? privateKey.sharedSecretFromKeyAgreement(with: theirs) else { channel.close(); return }
                let serverNonce = Data(reply.suffix(32))
                let result = CompanionCrypto.pairing(secret, client: nonce, server: serverNonce,
                                                     companionKey: privateKey.publicKey.rawRepresentation, macKey: Data(reply.prefix(32)))
                newKey = result.key
                let name = mac.name, code = result.code
                DispatchQueue.main.async { MainActor.assumeIsolated { MacLink.shared.status = .pairing(name: name, code: code) } }
            case .paired(let accepted):
                if accepted, let newKey {
                    PairingStore.save(PairingStore.Pairing(mac: mac.id, macName: mac.name, pairing: pairingID,
                                                           key: newKey.withUnsafeBytes { Data($0) }))
                    // Connect again, now paired.
                    channel.close()
                } else {
                    let name = mac.name
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { MacLink.shared.status = .refused("\(name) didn't allow this \(PairingStore.deviceKind).") }
                    }
                    channel.close()
                }
            default:
                break
            }
        }
    }

    private func connected(_ channel: CompanionChannel) {
        guard channel === self.channel else { return }
        status = .connected
        attempts = 0
        Self.audio.channel = channel
        companionLog.notice("Connected")
        startPinging()
        VolumeButtons.shared.update()
        let waiting = waiters
        waiters = []
        waiting.forEach { $0(true) }
        CallWatcher.shared.report()
        flushPending()
    }

    /// Calls back once connected (at once if it is), or false if it couldn't within `timeout`.
    func whenConnected(timeout: TimeInterval = 8, _ done: @escaping (Bool) -> Void) {
        if isConnected { done(true); return }
        waiters.append(done)
        activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated {
                let link = MacLink.shared
                guard !link.waiters.isEmpty, !link.isConnected else { return }
                let waiting = link.waiters
                link.waiters = []
                waiting.forEach { $0(false) }
            }
        }
    }

    func whenConnected(timeout: TimeInterval = 8) async -> Bool {
        await withCheckedContinuation { continuation in whenConnected(timeout: timeout) { continuation.resume(returning: $0) } }
    }

    /// Tries again now (the Mac refused, and its owner says it's fine now).
    func tryAgain() {
        if case .refused = status { status = .searching }
        channel?.close()
        channel = nil
        activate()
    }

    func forgetMac() {
        guard let macID else { return }
        send(.forget(PairingStore.deviceID))
        PairingStore.forget(macID)
        self.macID = nil
        UserDefaults.standard.removeObject(forKey: "macID")
        UserDefaults.standard.removeObject(forKey: "macService")
        UserDefaults.standard.removeObject(forKey: "macSymbol")
        channel?.close()
        channel = nil
        state = nil
        status = .searching
        VolumeButtons.shared.update()
    }

    // MARK: Packets from the Mac (on the channel's queue)

    nonisolated private static func received(_ packet: CompanionPacket, from channel: CompanionChannel) {
        switch packet {
        case .speakerAudio(let position, let samples):
            SpeakerPlayer.shared.receive(position: position, samples: samples)
        case .pong(let asked, let answered):
            MacLink.clock.add(asked: asked, mac: answered, answered: HostClock.now)
        case .message(let message):
            DispatchQueue.main.async { MainActor.assumeIsolated { MacLink.shared.handle(message, from: channel) } }
        default:
            break
        }
    }

    private func handle(_ message: CompanionMessage, from channel: CompanionChannel) {
        guard channel === self.channel else { return }
        switch message {
        case .state(var state):
            // Replies to earlier presses arrive while more are made: the latest here wins a moment.
            macKnob = state.knobValue
            if let local = localKnob {
                if Date() < local.until { state.knobValue = local.value } else { localKnob = nil }
            }
            self.state = state
            SharedState.update(from: state)
            SpeakerPlayer.shared.stateChanged(state)
        case .icons(let icons):
            for (key, data) in icons {
                if let image = UIImage(data: data, scale: 2) { self.icons[key] = image }
            }
            if let tile = icons["system"] { SharedState.macTile = tile }
        case .speakerStart(let start, let delay):
            SpeakerPlayer.shared.start(timelineStart: start, delay: delay)
        case .speakerStop:
            SpeakerPlayer.shared.stop()
        case .speakerVolume(let volume):
            SpeakerPlayer.shared.setVolume(volume)
        case .micStart:
            MicStreamer.shared.start()
        case .micStop:
            MicStreamer.shared.stop()
        case .askCall:
            CallWatcher.shared.report()
        default:
            break
        }
    }

    // MARK: Showing changes straight away

    /// The main bar moved here (a volume button, the lock screen's bar): shown at once, before
    /// the Mac says so (its next state puts it exactly where it landed).
    func setKnobValueLocally(_ value: Float) {
        guard state != nil else { return }
        localKnob = (min(max(value, 0), 1), Date().addingTimeInterval(0.5))
        state?.knobValue = min(max(value, 0), 1)
        // If the Mac ended up somewhere else (nothing to turn up, say), show that after the moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            MainActor.assumeIsolated {
                let link = MacLink.shared
                guard let local = link.localKnob, Date() >= local.until else { return }
                link.localKnob = nil
                if let mac = link.macKnob, link.state?.knobValue != mac {
                    link.state?.knobValue = mac
                    SpeakerPlayer.shared.updateNowPlaying()
                }
            }
        }
        if state?.knob == "speakers", (state?.speakersMuted ?? false), value > 0 { state?.speakersMuted = false }
        SpeakerPlayer.shared.updateNowPlaying()
    }

    func stepKnobLocally(_ delta: Float) {
        guard let value = state?.knobValue else { return }
        setKnobValueLocally(value + delta)
    }

    // MARK: To the Mac

    /// Sends a command. With `coalescing`, a burst of the same kind (a slider being dragged)
    /// goes at most 25 times a second, the last one always.
    func send(_ command: RemoteCommand, coalescing key: String? = nil) {
        guard let key else {
            flushPending()
            channel?.send(.command(command))
            return
        }
        pending[key] = command
        guard flush == nil else { return }
        let work = DispatchWorkItem { MainActor.assumeIsolated { MacLink.shared.flushPending() } }
        flush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func flushPending() {
        flush?.cancel()
        flush = nil
        guard let channel, isConnected else { return }
        for command in pending.values { channel.send(.command(command)) }
        pending = [:]
    }

    func send(_ message: CompanionMessage) {
        channel?.send(message)
    }


    // MARK: Clock

    private func startPinging() {
        pingTimer?.invalidate()
        var count = 0
        ping()
        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            MainActor.assumeIsolated {
                count += 1
                // Quickly at first, then every few seconds (often while it plays, to follow drift).
                let link = MacLink.shared
                if count < 10 || count % (SpeakerPlayer.shared.isPlaying ? 2 : 8) == 0 { link.ping() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func ping() {
        channel?.send(.ping(HostClock.now))
    }
}

/// The connection, for sound sent from the audio threads.
final class AudioLink: @unchecked Sendable {
    private let lock = NSLock()
    private var _channel: CompanionChannel?
    var channel: CompanionChannel? {
        get { lock.withLock { _channel } }
        set { lock.withLock { _channel = newValue } }
    }
}

/// The Mac's clock as seen from here: from ping round trips, the offset found on the quickest
/// recent ones (the least delayed by the network, so the most exact).
final class MacClock: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(rtt: UInt64, offset: Int64)] = []
    private var current: Int64?

    func add(asked: UInt64, mac: UInt64, answered: UInt64) {
        guard answered >= asked else { return }
        let rtt = answered - asked
        // The Mac answered halfway through the round trip.
        let offset = Int64(bitPattern: mac &- (asked &+ rtt / 2))
        lock.withLock {
            samples.append((rtt, offset))
            if samples.count > 16 { samples.removeFirst() }
            let best = samples.min { $0.rtt < $1.rtt }!
            current = best.offset
        }
    }

    func reset() { lock.withLock { samples = []; current = nil } }

    /// Mac host time (nanoseconds) at a local host time, once the clocks are known.
    func macTime(_ local: UInt64) -> UInt64? {
        lock.withLock { current.map { UInt64(bitPattern: Int64(bitPattern: local) &+ $0) } }
    }

    var isKnown: Bool { lock.withLock { current != nil } }
}
