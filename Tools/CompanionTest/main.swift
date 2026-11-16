// A stand-in Soundcheck for testing Soundcheck Companion (in the simulator or on a device)
// without touching the Mac's sound: it advertises a Mac called "MacBook Pro" (always with the ID
// TEST-DEMO-MAC, so a simulator can be pointed at it), allows pairing by itself (it prints the
// code), sends a made-up state that looks like a real Mac's (with the Mac's own app icons, for
// screenshots), logs every command (and acts on most), and when the companion plays as a speaker
// it streams silence on a timeline, logging what the companion reports back.
//
//   CompanionTest [seconds]

import AppKit
import CryptoKit
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)
let runFor = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 300
let keys = PairingKeys()
let macID = "TEST-DEMO-MAC"

func say(_ text: String) {
    let time = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    print("[\(time)] \(text)")
}

var state = RemoteState()
state.macName = "MacBook Pro"
state.macShortName = "MacBook"
state.macSymbol = "laptopcomputer"
state.knobValue = 0.8
state.version = "1.2"
state.micInstalled = true
state.options.duckMode = "lower"
var warm = SoundShape()
warm.setGain(3, for: .bass)
warm.setGain(1.5, for: .warmth)
state.speakers = [
    RemoteSpeaker(id: "builtin", name: "MacBook Pro Speakers", symbol: "laptopcomputer", kind: .device, isOn: true, volume: 0.8,
                  muted: false, shape: warm, limit: nil, isHeadphones: false, canHearYourself: true,
                  hearsSoundcheckMic: false, hearsMics: [], status: nil, sync: nil, companion: nil),
    RemoteSpeaker(id: "airpods", name: "AirPods Pro", symbol: "airpods.pro", kind: .device, isOn: false, volume: 0.4,
                  muted: false, shape: SoundShape(), limit: 0.8, isHeadphones: true, canHearYourself: true,
                  hearsSoundcheckMic: false, hearsMics: [], status: nil, sync: nil, companion: nil),
    RemoteSpeaker(id: "airplay:AA", name: "Living Room", symbol: "homepod.fill", kind: .airPlay, isOn: true, volume: 0.55,
                  muted: false, shape: SoundShape(), limit: nil, isHeadphones: false, canHearYourself: false,
                  hearsSoundcheckMic: false, hearsMics: [], status: nil, sync: 0, companion: nil),
    RemoteSpeaker(id: "airplay:BB", name: "Kitchen", symbol: "homepod.mini.fill", kind: .airPlay, isOn: false, volume: 0.3,
                  muted: false, shape: SoundShape(), limit: nil, isHeadphones: false, canHearYourself: false,
                  hearsSoundcheckMic: false, hearsMics: [], status: nil, sync: 0, companion: nil),
]
state.mixing = true

/// Soundcheck's own effects, as the Mac lists them.
state.effectChoices = [
    ("reverb", "Reverb", "building.columns"), ("echo", "Echo", "repeat"),
    ("compressor", "Compressor", "arrow.down.right.and.arrow.up.left"), ("limiter", "Limiter", "chart.line.flattrend.xyaxis"),
    ("pitch", "Pitch", "tuningfork"), ("distortion", "Distortion", "bolt"), ("voice", "Voice Isolation", "person.wave.2"),
].map { RemoteEffectChoice(id: $0.0, name: $0.1, maker: nil, symbol: $0.2) }
let reverb = RemoteEffect(
    id: UUID().uuidString, name: "Reverb", maker: nil, symbol: "building.columns", isOn: true,
    help: "A room, hall or plate around the sound",
    presets: ["Small Room", "Medium Room", "Large Room", "Medium Hall", "Large Hall", "Plate", "Cathedral"], preset: "Large Hall",
    controls: [RemoteEffectControl(id: 0, name: "Amount", style: .percent, min: 0, max: 100, value: 30),
               RemoteEffectControl(id: 1, name: "Size", style: .percent, min: 0, max: 100, value: 60)],
    problem: nil, isPlugIn: false)

state.apps = [
    RemoteApp(id: "com.apple.Music", name: "Music", isSystem: false, isPlaying: true, isListening: false,
              volume: 0.8, muted: false, pinned: false, shape: warm, routes: [], isSplitOff: true, tabs: nil, effects: [reverb]),
    RemoteApp(id: "company.thebrowser.dia", name: "Dia", isSystem: false, isPlaying: true, isListening: false,
              volume: 0.65, muted: false, pinned: true, shape: SoundShape(), routes: [], isSplitOff: true,
              tabs: [RemoteTab(id: 1, title: "Lo-fi beats to relax to", host: "youtube.com", playing: true, call: false, muted: false, level: 0.7),
                     RemoteTab(id: 2, title: "Weekly sync", host: "meet.google.com", playing: true, call: true, muted: false, level: 1)],
              effects: []),
    RemoteApp(id: "com.apple.podcasts", name: "Podcasts", isSystem: false, isPlaying: false, isListening: false,
              volume: 0.5, muted: false, pinned: true, shape: SoundShape(), routes: [], isSplitOff: true, tabs: nil, effects: []),
    RemoteApp(id: "com.mylesdean.Soundcheck.system", name: "System", isSystem: true, isPlaying: false, isListening: false,
              volume: 0.6, muted: false, pinned: false, shape: SoundShape(), routes: [], isSplitOff: true, tabs: nil),
]
state.mics = [
    RemoteMic(id: "builtin-mic", name: "MacBook Pro Microphone", symbol: "laptopcomputer", volume: 0.7, muted: false,
              isSelected: true, isRouted: true, shape: SoundShape(), companion: nil, effects: []),
    RemoteMic(id: "airpods-mic", name: "AirPods Pro", symbol: "airpods.pro", volume: 0.8, muted: false,
              isSelected: false, isRouted: false, shape: SoundShape(), companion: nil, effects: []),
    RemoteMic(id: "continuity", name: "iPhone (Continuity)", symbol: "iphone", volume: nil, muted: false,
              isSelected: false, isRouted: false, shape: SoundShape(), companion: nil, isContinuity: true),
]
state.routeApps = [
    RemoteRouteApp(id: "com.apple.Music", name: "Music", isRouted: true, level: 0.4, muted: false),
    RemoteRouteApp(id: "company.thebrowser.dia", name: "Dia", isRouted: false, level: 1, muted: false),
]
state.playing = ["Music", "Dia"]

/// The Mac's own app icons (and System's tile), as Soundcheck sends them.
func iconPNG(_ image: NSImage, size: CGFloat = 64) -> Data? {
    let pixels = Int(size * 2)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}
func systemTile() -> NSImage {
    NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        let tile = rect.insetBy(dx: 64 * 100 / 1024, dy: 64 * 100 / 1024)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(starting: NSColor(white: 0.66, alpha: 1), ending: NSColor(white: 0.46, alpha: 1))!.draw(in: path, angle: -90)
        if let symbol = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .medium).applying(.init(paletteColors: [.white]))) {
            symbol.draw(in: NSRect(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
        }
        return true
    }
}
var icons: [String: Data] = [:]
for (id, path) in [("com.apple.Music", "/System/Applications/Music.app"), ("company.thebrowser.dia", "/Applications/Dia.app"),
                   ("com.apple.podcasts", "/System/Applications/Podcasts.app")] where FileManager.default.fileExists(atPath: path) {
    icons[id] = iconPNG(NSWorkspace.shared.icon(forFile: path))
}
for id in ["system", "com.mylesdean.Soundcheck.system"] { icons[id] = iconPNG(systemTile()) }

final class Server: CompanionServerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "test")
    var peers: [CompanionServerPeer] = []
    var streaming: [String: DispatchSourceTimer] = [:]
    var micBytes: [String: Int] = [:]
    let start = HostClock.now

    func authenticated(_ peer: CompanionServerPeer, _ hello: CompanionHello) {
        queue.async { [self] in
            say("AUTHENTICATED \(hello.kind) device=\(hello.device.prefix(8))")
            if !state.companions.contains(where: { $0.id == hello.device }) {
                state.companions.append(RemoteCompanion(id: hello.device, name: hello.kind, kind: hello.kind, connected: true,
                                                        isSpeaker: false, isMicrophone: false))
                state.speakers.append(RemoteSpeaker(id: "airplay:companion-" + hello.device, name: hello.kind, symbol: "iphone",
                                                    kind: .companion, isOn: false, volume: 0.5, muted: false, shape: SoundShape(),
                                                    limit: nil, isHeadphones: false, canHearYourself: false, hearsSoundcheckMic: false,
                                                    hearsMics: [], status: nil, sync: nil, companion: hello.device))
                state.mics.append(RemoteMic(id: "companion-mic." + hello.device, name: "\(hello.kind) (Soundcheck)", symbol: "iphone",
                                            volume: 1, muted: false, isSelected: false, isRouted: false, shape: SoundShape(),
                                            companion: hello.device))
            }
            peer.channel.send(.icons(icons))
            peer.channel.send(.state(state))
            peer.channel.send(.askCall)
        }
    }

    func askedToPair(_ peer: CompanionServerPeer, _ hello: CompanionHello, key: SymmetricKey, code: String) {
        say("PAIRING \(hello.kind): code \(code) (allowed automatically)")
        keys.set(key, for: hello.pairing)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { peer.channel.send(.paired(accepted: true)) }
    }

    func received(_ message: CompanionMessage, from peer: CompanionServerPeer) {
        queue.async { [self] in
            guard let device = peer.device else { return }
            switch message {
            case .command(let command):
                say("COMMAND \(command)")
                apply(command, device: device, peer: peer)
            case .speakerReady(let latency):
                say(String(format: "SPEAKER READY latency %.1f ms", latency * 1000))
                setSpeaker(device, status: nil)
            case .speakerFailed(let reason):
                say("SPEAKER FAILED \(reason)")
            case .micReady:
                say("MIC READY")
            case .micFailed(let reason):
                say("MIC FAILED \(reason)")
            case .callState(let active, let ringing):
                say("CALL STATE active=\(active) ringing=\(ringing)")
            default:
                say("MESSAGE \(message)")
            }
        }
    }

    func receivedMicrophone(_ samples: Data, from peer: CompanionServerPeer) {
        queue.async { [self] in
            let device = peer.device ?? ""
            let before = micBytes[device, default: 0]
            micBytes[device] = before + samples.count
            // About every second of sound (96 kB at 48 kHz mono 16-bit).
            if before / 96_000 != (before + samples.count) / 96_000 {
                say("MIC \(Double(before + samples.count) / 96_000) s of sound so far")
            }
        }
    }

    private func setSpeaker(_ device: String, status: String?) {
        if let index = state.speakers.firstIndex(where: { $0.companion == device }) { state.speakers[index].status = status }
        publish()
    }

    func publish() {
        for peer in peers where peer.device != nil { peer.channel.send(.state(state)) }
    }

    private func apply(_ command: RemoteCommand, device: String, peer: CompanionServerPeer) {
        switch command {
        case .setKnobValue(let value): state.knobValue = value
        case .setKnob(let knob): state.knob = knob
        case .toggleSpeakersMuted: state.speakersMuted.toggle()
        case .setMixing(let on): state.mixing = on
        case .setAppVolume(let id, let volume):
            if let index = state.apps.firstIndex(where: { $0.id == id }) { state.apps[index].volume = volume }
        case .setAppMuted(let id, let muted):
            if let index = state.apps.firstIndex(where: { $0.id == id }) { state.apps[index].muted = muted }
        case .toggleSpeaker(let id):
            if let index = state.speakers.firstIndex(where: { $0.id == id }) {
                state.speakers[index].isOn.toggle()
                if let companion = state.speakers[index].companion { speaker(companion, state.speakers[index].isOn, peer) }
            }
        case .selectOnlySpeaker(let id):
            for index in state.speakers.indices { state.speakers[index].isOn = state.speakers[index].id == id }
        case .useAsSpeaker(let on):
            if let index = state.speakers.firstIndex(where: { $0.companion == device }) { state.speakers[index].isOn = on }
            speaker(device, on, peer)
        case .useAsMicrophone(let on):
            if let index = state.companions.firstIndex(where: { $0.id == device }) { state.companions[index].isMicrophone = on }
            for index in state.mics.indices { state.mics[index].isSelected = on ? state.mics[index].companion == device : index == 0 }
            peer.channel.send(on ? .micStart : .micStop)
        case .setMicsMuted(let muted): state.micsMuted = muted
        case .setNightMode(let on): state.options.nightMode = on
        case .setDuckMode(let mode): state.options.duckMode = mode
        case .setShape(let target, let shape):
            if case .app(let id) = target, let index = state.apps.firstIndex(where: { $0.id == id }) { state.apps[index].shape = shape }
            if case .speaker(let id) = target, let index = state.speakers.firstIndex(where: { $0.id == id }) { state.speakers[index].shape = shape }
            if case .mic(let id) = target, let index = state.mics.firstIndex(where: { $0.id == id }) { state.mics[index].shape = shape }
        case .setSpeakerVolume(let id, let volume):
            if let index = state.speakers.firstIndex(where: { $0.id == id }) { state.speakers[index].volume = volume }
        case .setMicVolume(let id, let volume):
            if let index = state.mics.firstIndex(where: { $0.id == id }) { state.mics[index].volume = volume }
        case .selectMic(let id):
            for index in state.mics.indices { state.mics[index].isSelected = state.mics[index].id == id }
        case .setRouting(let on): state.routing = on
        case .toggleRouteMic(let id):
            if let index = state.mics.firstIndex(where: { $0.id == id }) { state.mics[index].isRouted.toggle() }
        case .toggleRoutedApp(let id):
            if let index = state.routeApps.firstIndex(where: { $0.id == id }) { state.routeApps[index].isRouted.toggle() }
        case .setRouteAppLevel(let id, let level):
            if let index = state.routeApps.firstIndex(where: { $0.id == id }) { state.routeApps[index].level = level }
        case .setEffectOn(let target, let effect, let on):
            editEffects(target) { effects in
                if let index = effects.firstIndex(where: { $0.id == effect }) { effects[index].isOn = on }
            }
        case .setEffectValue(let target, let effect, let control, let value):
            editEffects(target) { effects in
                if let index = effects.firstIndex(where: { $0.id == effect }),
                   let at = effects[index].controls.firstIndex(where: { $0.id == control }) { effects[index].controls[at].value = value }
            }
        case .setEffectPreset(let target, let effect, let index):
            editEffects(target) { effects in
                if let at = effects.firstIndex(where: { $0.id == effect }), index < effects[at].presets.count {
                    effects[at].preset = effects[at].presets[index]
                }
            }
        case .addEffect(let target, let choice):
            guard let choice = state.effectChoices?.first(where: { $0.id == choice }) else { break }
            editEffects(target) { effects in
                effects.append(RemoteEffect(id: UUID().uuidString, name: choice.name, maker: nil, symbol: choice.symbol, isOn: true,
                                            help: nil, presets: [], preset: nil,
                                            controls: [RemoteEffectControl(id: 0, name: "Amount", style: .percent, min: 0, max: 100, value: 50)],
                                            problem: nil, isPlugIn: false))
            }
        case .removeEffect(let target, let effect):
            editEffects(target) { effects in effects.removeAll { $0.id == effect } }
        default: break
        }
        publish()
    }

    private func editEffects(_ target: RemoteShapeTarget, _ edit: (inout [RemoteEffect]) -> Void) {
        switch target {
        case .app(let id):
            if let index = state.apps.firstIndex(where: { $0.id == id }) {
                var effects = state.apps[index].effects ?? []
                edit(&effects)
                state.apps[index].effects = effects
            }
        case .mic(let id):
            if let index = state.mics.firstIndex(where: { $0.id == id }) {
                var effects = state.mics[index].effects ?? []
                edit(&effects)
                state.mics[index].effects = effects
            }
        case .speaker:
            break
        }
    }

    /// Streams silence on a timeline starting now, 441 frames every 10 ms, as the Mac's feed does.
    private func speaker(_ device: String, _ on: Bool, _ peer: CompanionServerPeer) {
        if let index = state.companions.firstIndex(where: { $0.id == device }) { state.companions[index].isSpeaker = on }
        streaming[device]?.cancel()
        streaming[device] = nil
        guard on else { peer.channel.send(.speakerStop); return }
        setSpeaker(device, status: "Connecting…")
        let timelineStart = HostClock.now
        peer.channel.send(.speakerStart(start: timelineStart, delay: 0.3))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var position: Int64 = 0
        let silence = Data(count: 441 * 4)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            // Frames are sent as they're "current" on the timeline.
            let current = Int64(Double(HostClock.now - timelineStart) / 1e9 * 44_100)
            while position + 441 <= current {
                peer.channel.sendAudio(.speakerAudio(position: position, samples: silence))
                position += 441
            }
        }
        timer.resume()
        streaming[device] = timer
    }
}

let server = Server()
let listener = try NWListener(using: CompanionChannel.parameters())
listener.service = NWListener.Service(name: state.macName, type: Companion.serviceType, domain: nil,
                                      txtRecord: NWTXTRecord(["id": macID, "v": String(Companion.version), "sym": "laptopcomputer"]))
listener.newConnectionHandler = { connection in
    let channel = CompanionChannel(connection: connection, label: "test")
    let peer = CompanionServerPeer(channel: channel, keys: keys, macID: macID, macName: state.macName, delegate: server)
    server.queue.async { server.peers.append(peer) }
    channel.onClose = { reason in
        say("CLOSED \(reason ?? "")")
        server.queue.async { server.peers.removeAll { $0 === peer } }
    }
    channel.start()
    say("CONNECTION from \(connection.endpoint)")
}
listener.stateUpdateHandler = { say("LISTENER \($0)") }
listener.start(queue: .main)
say("Advertising \(state.macName) (\(macID)) for \(Int(runFor)) s")
DispatchQueue.main.asyncAfter(deadline: .now() + runFor) { exit(0) }
dispatchMain()
