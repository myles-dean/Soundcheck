import Foundation

// Soundcheck Companion's link between the Mac and an iPhone or iPad: the Mac's whole state (all
// of the menu bar panel and the settings windows), what the companion asks of it, and the sound
// that goes each way. Shared by Soundcheck and the companion app.

enum Companion {
    /// The Bonjour service Soundcheck advertises on the local network.
    static let serviceType = "_soundcheck._tcp"
    static let version = 1
    /// Sound to a companion playing as a speaker: 44.1 kHz stereo 16-bit (the AirPlay timeline's).
    static let speakerRate = 44_100.0
    /// A companion's microphone: 48 kHz mono 16-bit.
    static let micRate = 48_000.0
    /// How far ahead of the Mac's own speakers sound is sent to a companion speaker, on top of
    /// its own output latency: room for Wi-Fi to stall for a moment.
    static let speakerMargin = 0.3
}

// MARK: The Mac's state

/// One speaker in the Speakers list: a device, an AirPlay speaker, or a companion playing as one.
struct RemoteSpeaker: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case device, airPlay, companion }
    /// The device's UID, or "airplay:<id>" (how the Mac keys its levels).
    var id: String
    var name: String
    var symbol: String
    var kind: Kind
    /// One of the speakers playing.
    var isOn: Bool
    var volume: Float
    var muted: Bool
    var shape: SoundShape
    /// Headphones' volume limit (0...1), if set.
    var limit: Float?
    var isHeadphones: Bool
    var canHearYourself: Bool
    /// Soundcheck Mic plays on it (Hear Yourself), and which other microphones do.
    var hearsSoundcheckMic: Bool
    var hearsMics: [String]
    /// "Connecting…", or why it couldn't (AirPlay and companions).
    var status: String?
    /// AirPlay: how much earlier (seconds) it gets the sound, to line it up by ear.
    var sync: Double?
    /// A companion speaker's device ID.
    var companion: String?
}

/// A browser tab with sound (from Soundcheck's browser extension).
struct RemoteTab: Codable, Equatable, Identifiable {
    var id: Int
    var title: String
    var host: String
    var playing: Bool
    var call: Bool
    var muted: Bool
    var level: Float
}

struct RemoteApp: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var isSystem: Bool
    var isPlaying: Bool
    var isListening: Bool
    /// The slider: 0...1, or up to 2 with Allow Boost.
    var volume: Float
    var muted: Bool
    var pinned: Bool
    var shape: SoundShape
    /// Split: the speakers (keys) it plays on, when it has its own.
    var routes: [String]
    var isSplitOff: Bool
    /// A browser with Soundcheck's extension: its tabs with sound.
    var tabs: [RemoteTab]?
    /// Its effects, after its EQ, in order.
    var effects: [RemoteEffect]?
}

struct RemoteMic: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    /// Nil when the Mac can't set its level.
    var volume: Float?
    var muted: Bool
    /// The one Soundcheck Mic carries (or macOS's input, without Soundcheck Mic).
    var isSelected: Bool
    /// Mixed into Soundcheck Mic with Route.
    var isRouted: Bool
    var shape: SoundShape
    /// A companion's own microphone (its device ID).
    var companion: String?
    /// Its effects, after its EQ and Voice Cleanup, in order.
    var effects: [RemoteEffect]?
    /// An iPhone's microphone through macOS's Continuity (not picked from an iPhone running the
    /// app, which would be taking its own microphone a second way).
    var isContinuity: Bool?
}

/// One of an app's or microphone's effects.
struct RemoteEffect: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Who makes it (none for Soundcheck's own).
    var maker: String?
    var symbol: String
    var isOn: Bool
    /// What it does, for Soundcheck's own ("A room, hall or plate around the sound").
    var help: String?
    var presets: [String]
    /// The preset last picked.
    var preset: String?
    var controls: [RemoteEffectControl]
    /// What's wrong ("Opening…", "couldn't open").
    var problem: String?
    /// A plug-in: more of its controls are in its window, on the Mac.
    var isPlugIn: Bool
}

struct RemoteEffectControl: Codable, Equatable, Identifiable {
    /// Its address in the effect.
    var id: UInt64
    var name: String
    var style: EffectValueStyle
    var min: Float
    var max: Float
    var value: Float
    var step: Float?
    var choices: [String]?
    var unit: String?

    var text: String { style.format(value, choices: choices, unit: unit) }
}

/// Something that can be added: Soundcheck's own, or a plug-in on the Mac.
struct RemoteEffectChoice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Who makes it (none for Soundcheck's own).
    var maker: String?
    var symbol: String
}

/// An app that can be routed into Soundcheck Mic.
struct RemoteRouteApp: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var isRouted: Bool
    var level: Float
    var muted: Bool
}

struct RemoteSetup: Codable, Equatable, Identifiable {
    enum TriggerKind: String, Codable { case deviceConnects, appOpens }
    var id: UUID
    var name: String
    var triggerKind: TriggerKind?
    var triggerID: String?
    /// "MacBook Pro Speakers + 3 apps"
    var summary: String
}

/// Something a setup can apply itself on: a speaker or mic connecting, or an app opening.
struct RemoteTriggerChoice: Codable, Equatable, Identifiable {
    var kind: RemoteSetup.TriggerKind
    var id: String
    var name: String
}

struct RemoteOptions: Codable, Equatable {
    /// Quiet Apps in Calls: "off", "lower" or "mute".
    var duckMode: String
    var switchToHeadphones: Bool
    var allowBoost: Bool
    var keepInMenuBar: Bool
    var nightMode: Bool
    var voiceCleanup: Bool
    var duckUnderVoice: Bool
    var launchAtLogin: Bool
}

/// A browser's extension: whether it's connected.
struct RemoteBrowser: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var connected: Bool
}

/// An iPhone or iPad paired with this Mac.
struct RemoteCompanion: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var connected: Bool
    var isSpeaker: Bool
    var isMicrophone: Bool
}

/// Everything the panel and the settings windows show.
struct RemoteState: Codable, Equatable {
    /// "Myles's MacBook Pro"
    var macName = ""
    /// "MacBook", "iMac", "Mac mini"…: what the lock screen calls it.
    var macShortName = "Mac"
    var macSymbol = "laptopcomputer"
    /// What the main slider and the volume keys move: "speakers", "apps" or "mics".
    var knob = "speakers"
    var knobValue: Float = 0
    var speakersMuted = false
    var mixing = false
    var airPlayOnly = false
    var speakers: [RemoteSpeaker] = []
    var split = false
    var apps: [RemoteApp] = []
    var micInstalled = false
    var installingMic = false
    var mics: [RemoteMic] = []
    var routing = false
    var routeApps: [RemoteRouteApp] = []
    var micsMuted = false
    var hearYourselfLevel: Float = 0.8
    var hearYourselfMuted = false
    var options = RemoteOptions(duckMode: "off", switchToHeadphones: true, allowBoost: false, keepInMenuBar: false,
                                nightMode: false, voiceCleanup: false, duckUnderVoice: false, launchAtLogin: false)
    var setups: [RemoteSetup] = []
    var triggerChoices: [RemoteTriggerChoice] = []
    var canUndoReset = false
    /// Apps playing sound right now, by name.
    var playing: [String] = []
    var onCall = false
    var browsers: [RemoteBrowser] = []
    /// Soundcheck is waiting on the System Audio Recording permission.
    var needsPermission = false
    var companions: [RemoteCompanion] = []
    var version = ""
    /// The effects that can be added (Soundcheck's own, then the Mac's plug-ins by maker).
    var effectChoices: [RemoteEffectChoice]?
}

// MARK: What a companion asks of the Mac

/// What a shape belongs to.
enum RemoteShapeTarget: Codable, Equatable, Hashable {
    case speaker(String)
    case app(String)
    case mic(String)
}

enum RemoteCommand: Codable, Equatable {
    // Speakers
    case setKnob(String)
    case setKnobValue(Float)
    /// The phone's volume buttons: a step for speakers, apps or mics.
    case step(knob: String, delta: Float)
    case toggleSpeakersMuted
    case selectOnlySpeaker(String)
    case toggleSpeaker(String)
    case setSpeakerVolume(id: String, volume: Float)
    case setSpeakerMuted(id: String, muted: Bool)
    case setMixing(Bool)
    case setAirPlayOnly(Bool)
    case setAirPlaySync(id: String, seconds: Double)
    case setVolumeLimit(id: String, limit: Float?)
    // Apps
    case setAppVolume(id: String, volume: Float)
    case setAppMuted(id: String, muted: Bool)
    case togglePin(String)
    case setSplit(Bool)
    case toggleAppSpeaker(app: String, speaker: String)
    case followMainSpeakers(String)
    case setTabVolume(browser: String, tab: Int, volume: Float)
    case setTabMuted(browser: String, tab: Int, muted: Bool)
    // Microphones
    case selectMic(String)
    case setMicVolume(id: String, volume: Float)
    case setMicMuted(id: String, muted: Bool)
    case setMicsMuted(Bool)
    case setRouting(Bool)
    case toggleRouteMic(String)
    case toggleRoutedApp(String)
    case setRouteAppLevel(id: String, level: Float)
    case setRouteAppMuted(id: String, muted: Bool)
    case installMic
    // Hear Yourself
    case toggleHearSoundcheckMic(speakers: [String])
    case toggleHearMic(mic: String, speakers: [String])
    case setHearYourselfLevel(Float)
    case setHearYourselfMuted(Bool)
    // EQ
    case setShape(target: RemoteShapeTarget, shape: SoundShape)
    // Effects (an app's or microphone's: `effect` is its ID)
    case addEffect(target: RemoteShapeTarget, choice: String)
    case removeEffect(target: RemoteShapeTarget, effect: String)
    case moveEffect(target: RemoteShapeTarget, effect: String, offset: Int)
    case setEffectOn(target: RemoteShapeTarget, effect: String, on: Bool)
    case setEffectValue(target: RemoteShapeTarget, effect: String, control: UInt64, value: Float)
    case setEffectPreset(target: RemoteShapeTarget, effect: String, index: Int)
    // Options
    case setDuckMode(String)
    case setSwitchToHeadphones(Bool)
    case setAllowBoost(Bool)
    case setKeepInMenuBar(Bool)
    case setNightMode(Bool)
    case setVoiceCleanup(Bool)
    case setDuckUnderVoice(Bool)
    case setLaunchAtLogin(Bool)
    // Saved setups
    case applySetup(UUID)
    case saveSetup(name: String)
    case renameSetup(id: UUID, name: String)
    case deleteSetup(UUID)
    case setSetupTrigger(id: UUID, kind: RemoteSetup.TriggerKind?, triggerID: String?)
    case updateSetup(UUID)
    // Soundcheck
    case reset
    case undoReset
    case checkForUpdates
    /// Opens a window on the Mac: "sound" (System Settings › Sound), "setups", "browsers", "welcome".
    case openOnMac(String)
    // Media keys
    case playPause
    case nextTrack
    case previousTrack
    // The companion itself
    case useAsSpeaker(Bool)
    case useAsMicrophone(Bool)
    case forget(String)
}

// MARK: Messages

/// Who's connecting: its pairing (shared by the owner's iPhone and iPad through iCloud
/// Keychain), the device itself, and what to call it.
struct CompanionHello: Codable, Equatable {
    var pairing: String
    var device: String
    var name: String
    /// "iPhone" or "iPad".
    var kind: String
    var nonce: Data
    var version: Int
}

enum CompanionMessage: Codable {
    // The handshake (in the clear; each side proves it has the pairing key).
    case hello(CompanionHello)
    case challenge(nonce: Data, proof: Data, mac: String, name: String)
    case proof(Data)
    /// The Mac doesn't know this pairing: the companion asks to pair.
    case unknownPairing(mac: String, name: String)
    case pair(publicKey: Data)
    case pairKey(publicKey: Data)
    case paired(accepted: Bool)

    // Mac → companion
    case state(RemoteState)
    /// App icons (PNG), by app ID; browser tab icons by "<browser>#<tab>"; "system" is the
    /// Mac's own tile, for the lock screen.
    case icons([String: Data])
    /// Play as a speaker: frame P of the timeline plays at Mac host time `start` + P/44100 +
    /// `delay` (nanoseconds and seconds).
    case speakerStart(start: UInt64, delay: Double)
    case speakerStop
    case speakerVolume(Float)
    /// The companion's microphone in Soundcheck Mic: start or stop sending it.
    case micStart
    case micStop
    /// Is a phone call on?
    case askCall

    // Companion → Mac
    case command(RemoteCommand)
    /// Playing: how long after a frame is handed to its output it's heard (seconds).
    case speakerReady(latency: Double)
    /// Couldn't play (iOS didn't allow it from the background, a call's on…).
    case speakerFailed(String)
    case micReady
    case micFailed(String)
    case callState(active: Bool, ringing: Bool)
}

/// A packet on the link: a message, or sound and clock packets in binary.
enum CompanionPacket {
    case message(CompanionMessage)
    /// To a companion speaker: frames (44.1 kHz stereo Int16) starting at `position` on the timeline.
    case speakerAudio(position: Int64, samples: Data)
    /// From a companion's microphone: 48 kHz mono Int16.
    case micAudio(samples: Data)
    /// Clock sync: the companion's time when it asked; the Mac answers with its own time too.
    case ping(UInt64)
    case pong(UInt64, UInt64)

    enum Kind: UInt8 { case message = 1, speakerAudio = 2, micAudio = 3, ping = 4, pong = 5 }

    func encoded() throws -> Data {
        var data = Data()
        switch self {
        case .message(let message):
            data.append(Kind.message.rawValue)
            data.append(try JSONEncoder().encode(message))
        case .speakerAudio(let position, let samples):
            data.append(Kind.speakerAudio.rawValue)
            data.appendInteger(UInt64(bitPattern: position))
            data.append(samples)
        case .micAudio(let samples):
            data.append(Kind.micAudio.rawValue)
            data.append(samples)
        case .ping(let time):
            data.append(Kind.ping.rawValue)
            data.appendInteger(time)
        case .pong(let asked, let answered):
            data.append(Kind.pong.rawValue)
            data.appendInteger(asked)
            data.appendInteger(answered)
        }
        return data
    }

    init?(_ data: Data) {
        guard let first = data.first, let kind = Kind(rawValue: first) else { return nil }
        let body = data.dropFirst()
        switch kind {
        case .message:
            guard let message = try? JSONDecoder().decode(CompanionMessage.self, from: Data(body)) else { return nil }
            self = .message(message)
        case .speakerAudio:
            guard body.count >= 8 else { return nil }
            self = .speakerAudio(position: Int64(bitPattern: body.integer(at: 0)), samples: Data(body.dropFirst(8)))
        case .micAudio:
            self = .micAudio(samples: Data(body))
        case .ping:
            guard body.count >= 8 else { return nil }
            self = .ping(body.integer(at: 0))
        case .pong:
            guard body.count >= 16 else { return nil }
            self = .pong(body.integer(at: 0), body.integer(at: 8))
        }
    }
}

extension Data {
    mutating func appendInteger(_ value: UInt64) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendInteger(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    /// A big-endian UInt64 at `offset` from the start of this slice.
    func integer(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in self[(startIndex + offset)..<(startIndex + offset + 8)] { value = value << 8 | UInt64(byte) }
        return value
    }

    func integer32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for byte in self[(startIndex + offset)..<(startIndex + offset + 4)] { value = value << 8 | UInt32(byte) }
        return value
    }
}

/// The host clock (mach_absolute_time, which Core Audio's timestamps use) in nanoseconds, the
/// same way on the Mac and on iOS.
enum HostClock {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static var now: UInt64 { nanoseconds(mach_absolute_time()) }

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: timebase.numer)
        return timebase.denom.dividingFullWidth(product).quotient
    }

    static func ticks(_ nanoseconds: UInt64) -> UInt64 {
        let product = nanoseconds.multipliedFullWidth(by: timebase.denom)
        return timebase.numer.dividingFullWidth(product).quotient
    }
}
