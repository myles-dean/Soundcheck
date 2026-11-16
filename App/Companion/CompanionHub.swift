import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import os

private let companionLog = Logger(subsystem: "com.mylesdean.Soundcheck", category: "companion")

/// Soundcheck's side of Soundcheck Companion, the iPhone and iPad app: it advertises Soundcheck on
/// the local network, pairs with companions (once, with the owner's OK on the Mac), sends them
/// everything the panel and the settings windows show, does what they ask, and carries sound
/// both ways: the Mac's to a companion playing as a speaker, and a companion's microphone into
/// Soundcheck Mic.
@MainActor
@Observable
final class CompanionHub {
    static let shared = CompanionHub()

    /// A companion this Mac knows (it has connected at least once).
    struct Device: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        /// "iPhone" or "iPad".
        var kind: String
        var pairing: String
        var lastSeen: Date
        var symbol: String { kind == "iPad" ? "ipad" : "iphone" }
    }

    /// Waiting for the owner to allow a new companion.
    struct PairingRequest: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let kind: String
        let code: String
    }

    private(set) var devices: [Device] = []
    /// Companions connected over Wi-Fi right now (device IDs).
    private(set) var connected: Set<String> = []
    private(set) var request: PairingRequest?
    /// Something to say about a companion speaker or microphone while it starts ("Open Soundcheck
    /// on your iPhone"), by device ID.
    private(set) var notes: [String: String] = [:]
    /// Companions on a phone call (answered on the iPhone), or ringing.
    private(set) var phoneCalls: [String: (active: Bool, ringing: Bool)] = [:]
    /// Apps really making sound (heard in the last moments), while a companion is connected:
    /// macOS says an app is playing for as long as it keeps its sound open, which browsers and
    /// Music do well after they've paused.
    private(set) var sounding: Set<String> = []
    @ObservationIgnored private var lastHeard: [String: Date] = [:]
    @ObservationIgnored private var soundTimer: Timer?

    /// The Mac stopped ringing a moment ago: the call may have been answered on the iPhone, so
    /// the apps stay lowered until it says.
    private(set) var awaitingAnswer = false

    /// This Mac, for companions (kept across launches).
    let macID: String
    @ObservationIgnored let keys = PairingKeys()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [ObjectIdentifier: Peer] = [:]
    /// Each companion's newest authenticated connection (an older one may still be closing).
    @ObservationIgnored private var activePeers: [String: Peer] = [:]
    @ObservationIgnored private var pendingPairing: (peer: Peer, key: SymmetricKey, hello: CompanionHello)?
    @ObservationIgnored private var stateTimer: DispatchWorkItem?
    @ObservationIgnored private(set) var lastState = RemoteState()
    @ObservationIgnored private var speakerSessions: [String: CompanionSpeakerSession] = [:]
    @ObservationIgnored private var wantedMics: Set<String> = []
    @ObservationIgnored private var answerTimer: DispatchWorkItem?
    @ObservationIgnored private var callPoll: Timer?
    @ObservationIgnored private var started = false

    private init() {
        if let id = UserDefaults.standard.string(forKey: "companionMacID") {
            macID = id
        } else {
            macID = UUID().uuidString
            UserDefaults.standard.set(macID, forKey: "companionMacID")
        }
        load()
    }

    // MARK: Starting

    func start() {
        guard !started else { return }
        started = true
        startListener()
        watchState()
        if !devices.isEmpty { CompanionBeacon.shared.start() }
        AirPlayBrowser.shared.setCompanions(companionSpeakers)
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: CompanionChannel.parameters())
            listener.service = NWListener.Service(name: Self.macName, type: Companion.serviceType, domain: nil,
                                                  txtRecord: NWTXTRecord(["id": macID, "v": String(Companion.version), "sym": AudioDevice.macSymbol]))
            listener.newConnectionHandler = { connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { CompanionHub.shared.accept(connection) } }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    companionLog.error("Companion listener failed: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        MainActor.assumeIsolated { CompanionHub.shared.restartListener() }
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            companionLog.error("Couldn't listen for companions: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        startListener()
    }

    // MARK: Connections

    /// One connection (the handshake is shared with the companion's test server), plus what's
    /// been sent to it (main actor only).
    final class Peer: CompanionServerPeer, @unchecked Sendable {
        var sentIcons: Set<String> = []
        var sentState: RemoteState?
    }

    /// The connections' reports, from their queues, passed to the main actor.
    private final class Delegate: CompanionServerDelegate, @unchecked Sendable {
        func authenticated(_ peer: CompanionServerPeer, _ hello: CompanionHello) {
            guard let peer = peer as? Peer else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { CompanionHub.shared.joined(peer, hello) } }
        }

        func askedToPair(_ peer: CompanionServerPeer, _ hello: CompanionHello, key: SymmetricKey, code: String) {
            guard let peer = peer as? Peer else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { CompanionHub.shared.askToPair(peer, hello, key: key, code: code) } }
        }

        func received(_ message: CompanionMessage, from peer: CompanionServerPeer) {
            guard let peer = peer as? Peer else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { CompanionHub.shared.handle(message, from: peer) } }
        }

        func receivedMicrophone(_ samples: Data, from peer: CompanionServerPeer) {
            guard let device = peer.device else { return }
            CompanionMics.shared.ring(for: device)?.write(samples)
        }
    }
    @ObservationIgnored private let delegate = Delegate()

    private func accept(_ connection: NWConnection) {
        let channel = CompanionChannel(connection: connection, label: "mac")
        let peer = Peer(channel: channel, keys: keys, macID: macID, macName: Self.macName, delegate: delegate)
        let id = ObjectIdentifier(peer)
        peers[id] = peer
        companionLog.notice("Connection from \(String(describing: connection.endpoint), privacy: .public)")
        channel.onClose = { reason in
            DispatchQueue.main.async { MainActor.assumeIsolated { CompanionHub.shared.closed(id, reason) } }
        }
        channel.start()
        // A connection that doesn't finish the handshake soon is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak peer] in
            MainActor.assumeIsolated {
                guard let peer, peer.device == nil, CompanionHub.shared.pendingPairing?.peer !== peer else { return }
                peer.channel.close()
            }
        }
    }

    private func closed(_ id: ObjectIdentifier, _ reason: String?) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        if pendingPairing?.peer === peer {
            companionLog.notice("The device asking to pair left: \(reason ?? "closed", privacy: .public)")
            pendingPairing = nil
            request = nil
            CompanionPairingPrompt.shared.close()
        }
        guard let device = peer.device else { return }
        companionLog.notice("Companion \(device, privacy: .public) left: \(reason ?? "closed", privacy: .public)")
        // Another connection from the same companion may already have replaced this one.
        if activePeers[device] === peer { activePeers[device] = nil }
        if activePeers[device] == nil {
            connected.remove(device)
            updateListening()
            speakerSessions[device]?.lostConnection()
            if CompanionMics.shared.ring(for: device) != nil { CompanionMics.shared.markIdle(device) }
        }
        publishSoon()
    }

    private func joined(_ peer: Peer, _ hello: CompanionHello) {
        // One connection per companion: an older one is stale.
        for other in peers.values where other !== peer && other.device == hello.device { other.channel.close() }
        activePeers[hello.device] = peer
        remember(hello)
        connected.insert(hello.device)
        updateListening()
        companionLog.notice("Companion \(hello.name, privacy: .public) connected")
        let state = buildState()
        lastState = state
        send(state, to: peer)
        if let session = speakerSessions[hello.device] { session.connected() }
        if wantedMics.contains(hello.device) { peer.channel.send(.micStart) }
        if CompanionHub.shared.awaitingAnswer || AudioEngine.shared.isRinging { peer.channel.send(.askCall) }
        publishSoon()
    }

    private func remember(_ hello: CompanionHello) {
        let device = Device(id: hello.device, name: hello.name, kind: hello.kind, pairing: hello.pairing, lastSeen: Date())
        if let index = devices.firstIndex(where: { $0.id == hello.device }) {
            devices[index] = device
        } else {
            devices.append(device)
            CompanionBeacon.shared.start()
        }
        save()
        AirPlayBrowser.shared.setCompanions(companionSpeakers)
        AudioEngine.shared.companionsChanged()
    }

    func peer(for device: String) -> Peer? { activePeers[device] }

    // MARK: Pairing

    private func askToPair(_ peer: Peer, _ hello: CompanionHello, key: SymmetricKey, code: String) {
        // One at a time. The same device asking again (it reconnected) takes over its request;
        // another device asking meanwhile is turned away.
        if let pending = pendingPairing {
            if pending.hello.device == hello.device {
                pendingPairing = nil
                pending.peer.channel.close()
            } else {
                peer.channel.send(.paired(accepted: false))
                return
            }
        }
        companionLog.notice("\(hello.kind, privacy: .public) asks to pair")
        pendingPairing = (peer, key, hello)
        request = PairingRequest(name: hello.name, kind: hello.kind, code: code)
        CompanionPairingPrompt.shared.show()
    }

    /// The owner's answer, from the prompt on the Mac.
    func answerPairing(_ allow: Bool) {
        guard let pending = pendingPairing else { return }
        pendingPairing = nil
        request = nil
        if allow {
            keys.set(pending.key, for: pending.hello.pairing)
            remember(pending.hello)
            save()
        }
        pending.peer.channel.send(.paired(accepted: allow))
        companionLog.notice("Pairing with \(pending.hello.name, privacy: .public): \(allow ? "allowed" : "refused", privacy: .public)")
    }

    /// Forgets a companion; its pairing too once no other device uses it (the iPhone and the
    /// iPad on the same Apple Account share one).
    func forget(_ device: String) {
        guard let index = devices.firstIndex(where: { $0.id == device }) else { return }
        let pairing = devices[index].pairing
        devices.remove(at: index)
        if !devices.contains(where: { $0.pairing == pairing }) { keys.set(nil, for: pairing) }
        for peer in peers.values where peer.device == device || (peer.device != nil && keys.key(peer.hello?.pairing ?? "") == nil) {
            peer.channel.close()
        }
        if AudioEngine.shared.airPlayIDs.contains(Self.speakerID(device)) {
            if let speaker = companionSpeakers.first(where: { $0.id == Self.speakerID(device) }) { AudioEngine.shared.toggleAirPlay(speaker) }
        }
        save()
        AirPlayBrowser.shared.setCompanions(companionSpeakers)
        AudioEngine.shared.companionsChanged()
        if devices.isEmpty { CompanionBeacon.shared.stop() }
        publishSoon()
    }

    // MARK: Messages from companions

    private func handle(_ message: CompanionMessage, from peer: Peer) {
        guard let device = peer.device else { return }
        switch message {
        case .command(let command):
            perform(command, from: device)
        case .speakerReady(let latency):
            companionLog.notice("Speaker \(device.prefix(8), privacy: .public): playing, latency \(Int(latency * 1000)) ms")
            notes[device] = nil
            speakerSessions[device]?.ready(latency: latency)
        case .speakerFailed(let reason):
            companionLog.notice("Speaker \(device.prefix(8), privacy: .public): couldn't play: \(reason, privacy: .public)")
            notes[device] = reason
            speakerSessions[device]?.waiting(reason)
        case .micReady:
            notes[device] = nil
        case .micFailed(let reason):
            companionLog.notice("Microphone \(device.prefix(8), privacy: .public): \(reason, privacy: .public)")
            notes[device] = reason
        case .callState(let active, let ringing):
            callStateChanged(device, active: active, ringing: ringing)
        default:
            break
        }
    }

    // MARK: What's playing

    /// App meters run while a companion is connected, so it's told what really plays.
    private func updateListening() {
        let on = !connected.isEmpty
        AudioEngine.shared.setAppMetering(on)
        if on, soundTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { CompanionHub.shared.listen() }
            }
            RunLoop.main.add(timer, forMode: .common)
            soundTimer = timer
        } else if !on {
            soundTimer?.invalidate()
            soundTimer = nil
            lastHeard = [:]
            if !sounding.isEmpty { sounding = [] }
        }
    }

    private func listen() {
        let engine = AudioEngine.shared
        let now = Date()
        for app in engine.apps where app.isPlaying {
            // Without a meter (yet), macOS's word for it.
            if (engine.appMeterLevel(app.id) ?? 1) > 0.0005 { lastHeard[app.id] = now }
        }
        let playing = Set(engine.apps.filter(\.isPlaying).map(\.id))
        lastHeard = lastHeard.filter { playing.contains($0.key) && now.timeIntervalSince($0.value) < 2.5 }
        let heard = Set(lastHeard.keys)
        if heard != sounding { sounding = heard }
    }

    // MARK: State to companions

    /// Follows everything the state is made of; any change sends it again (a little later, so a
    /// slider being dragged doesn't send hundreds).
    private func watchState() {
        let state = withObservationTracking {
            buildState()
        } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { CompanionHub.shared.publishSoon() } }
        }
        lastState = state
        for peer in peers.values where peer.device != nil { send(state, to: peer) }
    }

    func publishSoon() {
        guard stateTimer == nil else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let hub = CompanionHub.shared
                hub.stateTimer = nil
                hub.watchState()
            }
        }
        stateTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func send(_ state: RemoteState, to peer: Peer) {
        let icons = iconsNeeded(by: peer, state)
        if !icons.isEmpty { peer.channel.send(.icons(icons)) }
        guard peer.sentState != state else { return }
        peer.sentState = state
        peer.channel.send(.state(state))
    }

    /// App icons (and tab icons, and the Mac's own tile) the companion hasn't been sent yet.
    private func iconsNeeded(by peer: Peer, _ state: RemoteState) -> [String: Data] {
        var icons: [String: Data] = [:]
        func add(_ key: String, _ image: @autoclosure () -> NSImage?) {
            guard !peer.sentIcons.contains(key), let image = image(), let png = Self.png(image, size: 64) else { return }
            icons[key] = png
            peer.sentIcons.insert(key)
        }
        add("system", AudioApp.systemIcon)
        for app in state.apps {
            add(app.id, AudioEngine.shared.apps.first { $0.id == app.id }?.icon
                ?? AudioApp.pinned(app.id).icon)
            for tab in app.tabs ?? [] {
                let key = BrowserTabs.key(app.id, tab.id)
                add(key, BrowserTabs.shared.icons[key])
            }
        }
        for app in state.routeApps { add(app.id, AudioEngine.shared.apps.first { $0.id == app.id }?.icon) }
        return icons
    }

    static func png(_ image: NSImage, size: CGFloat) -> Data? {
        let pixels = Int(size * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Companions as speakers

    nonisolated static let speakerModel = "SoundcheckCompanion"
    nonisolated static func speakerID(_ device: String) -> String { "companion-" + device }
    nonisolated static func device(fromSpeakerID id: String) -> String? {
        id.hasPrefix("companion-") ? String(id.dropFirst("companion-".count)) : nil
    }

    /// Known companions, shown with the AirPlay speakers (they're played to the same way).
    var companionSpeakers: [AirPlaySpeaker] {
        devices.map { device in
            var speaker = AirPlaySpeaker(id: Self.speakerID(device.id), name: device.name, model: Self.speakerModel,
                                         host: "", port: 0, raopProperties: [:], airplayProperties: [:],
                                         raopServiceName: nil, airplayServiceName: nil)
            speaker.symbol = device.symbol
            return speaker
        }
    }

    func register(_ session: CompanionSpeakerSession) {
        companionLog.notice("Speaker \(session.device.prefix(8), privacy: .public): starting (\(self.peer(for: session.device) != nil ? "connected" : "waking", privacy: .public))")
        speakerSessions[session.device]?.lostConnection()
        speakerSessions[session.device] = session
        if peer(for: session.device) != nil {
            session.connected()
        } else {
            notes[session.device] = "Waking \(name(of: session.device))…"
            CompanionBeacon.shared.send(.speaker, to: session.device)
        }
    }

    func unregister(_ session: CompanionSpeakerSession) {
        guard speakerSessions[session.device] === session else { return }
        speakerSessions[session.device] = nil
        notes[session.device] = nil
        peer(for: session.device)?.channel.send(.speakerStop)
    }

    func name(of device: String) -> String { devices.first { $0.id == device }?.name ?? "your iPhone" }

    // MARK: Companions as microphones

    /// The companions whose microphone Soundcheck Mic carries (from the mixer, as it's rebuilt).
    func wantMicrophones(_ wanted: Set<String>) {
        guard wanted != wantedMics else { return }
        for device in wantedMics.subtracting(wanted) {
            peer(for: device)?.channel.send(.micStop)
            notes[device] = nil
        }
        for device in wanted.subtracting(wantedMics) {
            if let peer = peer(for: device) {
                peer.channel.send(.micStart)
            } else {
                notes[device] = "Waking \(name(of: device))…"
                CompanionBeacon.shared.send(.microphone, to: device)
            }
        }
        wantedMics = wanted
    }

    // MARK: Phone calls

    /// A phone call on (or not) on a companion.
    private func callStateChanged(_ device: String, active: Bool, ringing: Bool) {
        let before = phoneOnCall
        phoneCalls[device] = active || ringing ? (active, ringing) : nil
        if awaitingAnswer {
            awaitingAnswer = false
            answerTimer?.cancel()
            answerTimer = nil
        }
        updateCallPoll()
        _ = before
        AudioEngine.shared.phoneCallChanged()
    }

    /// A call answered on an iPhone keeps the apps lowered until it ends.
    var phoneOnCall: Bool { phoneCalls.values.contains { $0.active } }
    /// Lowered for a companion's call (or while waiting to hear whether it was answered there).
    var holdsCall: Bool { phoneOnCall || awaitingAnswer }

    /// The Mac's ringing (a call to the iPhone, through Continuity) started or stopped.
    func ringingChanged(_ ringing: Bool) {
        let phones = devices.filter { $0.kind == "iPhone" }
        guard !phones.isEmpty else { return }
        for phone in phones { ask(phone.id) }
        if !ringing && phoneCalls.isEmpty {
            // Stopped ringing: answered on the iPhone, declined, or missed. Hold the apps down a
            // few seconds while the iPhone says which.
            awaitingAnswer = true
            answerTimer?.cancel()
            let work = DispatchWorkItem {
                MainActor.assumeIsolated {
                    let hub = CompanionHub.shared
                    hub.answerTimer = nil
                    guard hub.awaitingAnswer else { return }
                    hub.awaitingAnswer = false
                    AudioEngine.shared.phoneCallChanged()
                }
            }
            answerTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
        updateCallPoll()
    }

    private func ask(_ device: String) {
        if let peer = peer(for: device) {
            peer.channel.send(.askCall)
        } else {
            CompanionBeacon.shared.send(.askCall, to: device)
        }
    }

    /// While a companion's call is on, it's asked every few seconds (it's usually asleep in the
    /// background, where iOS doesn't tell it when the call ends).
    private func updateCallPoll() {
        let wanted = !phoneCalls.isEmpty
        if wanted && callPoll == nil {
            let timer = Timer(timeInterval: 4, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let hub = CompanionHub.shared
                    for device in hub.phoneCalls.keys { hub.ask(device) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            callPoll = timer
        } else if !wanted {
            callPoll?.invalidate()
            callPoll = nil
        }
    }

    /// An answer over Bluetooth.
    func beaconCallState(_ device: String, value: UInt8) {
        callStateChanged(device, active: value == 1, ringing: value == 2)
    }

    // MARK: This Mac

    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// What the lock screen calls this Mac: "MacBook", "iMac", "Mac mini", "Mac Studio", "Mac Pro".
    static let macShortName: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        var product = ""
        if entry != 0, let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data {
            product = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        if product.isEmpty {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.model", &model, &size, nil, 0)
            product = String(cString: model)
        }
        for name in ["MacBook", "iMac", "Mac mini", "Mac Studio", "Mac Pro"] where product.contains(name) { return name }
        if product.hasPrefix("Macmini") { return "Mac mini" }
        return AudioDevice.macSymbol == "laptopcomputer" ? "MacBook" : "Mac"
    }()

    // MARK: Saved

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soundcheck/Companions.json")
    }

    private struct Saved: Codable {
        var devices: [Device]
        var pairings: [String: Data]
    }

    private func load() {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        devices = saved.devices
        for (pairing, key) in saved.pairings { keys.set(SymmetricKey(data: key), for: pairing) }
    }

    private func save() {
        let saved = Saved(devices: devices, pairings: keys.all.mapValues { key in key.withUnsafeBytes { Data($0) } })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Only this user can read the pairing keys.
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
