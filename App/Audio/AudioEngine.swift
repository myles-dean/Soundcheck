import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Observation

/// Everything the panel, the volume keys and the menu bar icon show and change: the outputs in
/// use and their volumes, each app's level and outputs, and the microphone (with Route mixing
/// microphones and apps into Soundcheck Mic).
///
/// Sound normally plays the way macOS plays it. Soundcheck only steps in when it has to: an app
/// with its own level, muted, or sent to its own outputs gets its own tap, and one more tap
/// carries everything else when sound goes to several outputs, to an output that has no volume
/// control of its own (most displays) turned down, or when the apps are turned down together.
@MainActor
@Observable
final class AudioEngine {
    static let shared = AudioEngine()
    static let didChangeVolume = Notification.Name("AudioEngine.didChangeVolume")
    static let didChangeActivity = Notification.Name("AudioEngine.didChangeActivity")

    /// What the main slider and the volume keys move.
    enum Knob: String, CaseIterable { case speakers, apps, mics }

    private(set) var outputDevices: [AudioDevice] = []
    private(set) var inputDevices: [AudioDevice] = []
    /// The main outputs (one or more; the first is macOS's default output).
    private(set) var members: [AudioDevice] = []
    private(set) var outputLevels = LinkedLevels()
    private(set) var appLevels = LinkedLevels()
    private(set) var micLevels = LinkedLevels()
    private(set) var knob: Knob = .speakers
    /// Mix opened by hand (it's also open whenever the speakers are at different levels).
    private(set) var mixRequested = false
    /// Mix: each speaker's own volume bar is shown.
    var isMixing: Bool { mixRequested || speakersDiffer }
    /// The speakers in use aren't all at the same level.
    var speakersDiffer: Bool {
        let offsets = speakerKeys.map { outputLevels.offsets[$0] ?? 0 }
        guard offsets.count > 1, let high = offsets.max(), let low = offsets.min() else { return false }
        return high - low > 0.001
    }
    private(set) var isMuted = false
    private(set) var apps: [AudioApp] = []
    private(set) var mutedApps: Set<String> = []
    /// Split: apps can play through their own outputs instead of the main ones.
    private(set) var isSplit = false
    /// Each app's own outputs (device UIDs), used while split. Kept when Split is off.
    private(set) var routes: [String: [String]] = [:]
    private(set) var defaultInput: AudioDevice?
    /// A tap failed because the System Audio Recording permission is off.
    private(set) var needsPermission = false
    /// Apps that keep their row while the panel is open, so rows don't jump around when a sound
    /// stops.
    private var heldApps: Set<String> = []
    /// Apps you've pinned: always in the Apps list while they're running.
    private(set) var pinnedApps: Set<String> = []
    /// Keep the menu bar icon even when nothing's playing or listening.
    private(set) var keepInMenuBar = false

    /// Quiet Apps in Calls: while an app uses a microphone, other apps are lowered or muted.
    enum DuckMode: String { case off, lower, mute }
    private(set) var duckMode: DuckMode = .off
    /// Switch to Headphones: when headphones connect, everything plays through them.
    private(set) var switchToHeadphones = true
    /// Boost: app sliders go up to 200%.
    private(set) var allowBoost = false
    /// Each boosted app's slider past 100% (1...2).
    private(set) var boosts: [String: Float] = [:]
    /// Mute Mics (from the shortcut).
    private(set) var micsMuted = false
    /// Shows a pill: a muted app started, the mics were muted, headphones took over.
    @ObservationIgnored var onNotice: ((HUDNotice) -> Void)?
    /// Headphones took over: show the speakers' pill.
    @ObservationIgnored var onHeadphones: (() -> Void)?

    // Route: microphones and apps mixed into Soundcheck Mic.
    private(set) var isRouting = false
    /// The real microphones mixed in while routing (none: just the apps).
    private(set) var routeMics: [String] = []
    private(set) var routedApps: Set<String> = []
    private(set) var isMicrophoneInstalled = MicDriver.isInstalled
    private(set) var isInstallingMicrophone = false

    /// The outputs in use: the main ones, plus (while split) the ones apps are sent to. Each has
    /// its own level, linked to the main slider.
    var activeOutputs: [AudioDevice] {
        guard isSplit else { return members }
        var devices = members
        for app in apps {
            for device in outputs(for: app.id) where !devices.contains(where: { $0.uid == device.uid }) {
                devices.append(device)
            }
        }
        return devices
    }
    var memberUIDs: [String] { members.map(\.uid) }
    /// The speaker group the main slider moves: the regular speakers in use (not while it's AirPlay
    /// only) and the AirPlay speakers.
    var speakerKeys: [String] {
        (playsLocally ? activeOutputs.map(\.uid) : []) + activeAirPlay.map { Self.airPlayKey($0.id) }
    }
    /// The regular speakers play (they're silent while it's AirPlay only).
    var playsLocally: Bool { !(airPlayOnly && !activeAirPlay.isEmpty) }
    var playingApps: [AudioApp] { apps.filter(\.isPlaying) }
    /// The microphones in use: the ones mixed into Soundcheck Mic while routing, otherwise the
    /// one picked. Only ones whose level can be set from the Mac.
    var activeMics: [AudioDevice] { feedingMics.filter { settableMics.contains($0.uid) } }

    /// The real microphones going into Soundcheck Mic (or, without it, the input).
    var feedingMics: [AudioDevice] {
        if isRouting && usesSoundcheckMic { return routeMics.compactMap { uid in inputDevices.first { $0.uid == uid } } }
        return shownInput.map { [$0] } ?? []
    }
    /// Microphones whose level can be set from the Mac (asked once per device change: some take
    /// a while to answer).
    @ObservationIgnored private var settableMics: Set<String> = []
    /// Where the main slider sits: the loudest in the group it controls.
    var knobValue: Float {
        switch knob {
        case .speakers: outputLevels.top(speakerKeys)
        case .apps: appLevels.top(playingApps.map(\.id))
        case .mics: micLevels.top(activeMics.map(\.uid))
        }
    }
    /// The loudest speaker in use.
    var speakersVolume: Float { outputLevels.top(speakerKeys) }
    /// A microphone's level, or nil when it can't be set from the Mac.
    func micVolume(_ device: AudioDevice) -> Float? {
        settableMics.contains(device.uid) ? micLevels.value(device.uid) : nil
    }
    func outputVolume(_ device: AudioDevice) -> Float { outputLevels.value(device.uid) }
    func appLevel(_ id: String) -> Float { appLevels.value(id) }
    /// What an app's slider shows: its level, times its boost (so up to 2 with Boost on).
    func appSliderValue(_ id: String) -> Float { appLevels.value(id) * (allowBoost ? (boosts[id] ?? 1) : 1) }
    func isAppMuted(_ id: String) -> Bool { mutedApps.contains(id) }
    var isPlaying: Bool { apps.contains { $0.isPlaying } }
    var isListening: Bool { apps.contains { $0.isListening } }
    var listeningApps: [AudioApp] { apps.filter(\.isListening) }
    /// The apps making sound and the pinned ones, open or not (and, while the panel is open, ones
    /// that just went quiet).
    var visibleApps: [AudioApp] {
        let shown = apps.filter { $0.isPlaying || heldApps.contains($0.id) || pinnedApps.contains($0.id) }
        let closed = pinnedApps.filter { id in !apps.contains { $0.id == id } }.map(AudioApp.pinned)
        guard !closed.isEmpty else { return shown }
        return (shown + closed).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// Apps you can route into the microphone: the ones in the Apps list, plus the routed ones.
    var routableApps: [AudioApp] {
        apps.filter { $0.isPlaying || heldApps.contains($0.id) || pinnedApps.contains($0.id) || routedApps.contains($0.id) }
    }
    var isRouteOnly: Bool { isRouting && routeMics.isEmpty }


    /// The outputs an app plays through: its own while split, otherwise the main ones.
    func outputs(for id: String) -> [AudioDevice] {
        guard isSplit, let route = routes[id] else { return members }
        let present = route.compactMap { uid in outputDevices.first { $0.uid == uid } }
        return present.isEmpty ? members : present
    }

    func isRouted(_ id: String) -> Bool { outputs(for: id).map(\.uid) != memberUIDs }

    @ObservationIgnored private let monitor = ProcessMonitor()
    @ObservationIgnored private var appTaps: [String: TapPlayer] = [:]
    @ObservationIgnored private var globalTap: TapPlayer?
    @ObservationIgnored private var mixer: MicMixer?
    @ObservationIgnored private var softwareGains: [String: SharedValue] = [:]
    @ObservationIgnored private var appGains: [String: (gain: SharedValue, muted: SharedValue)] = [:]
    /// The level of everything without a tap of its own (the apps' main level).
    @ObservationIgnored private let othersGain = SharedValue(1)
    @ObservationIgnored private let unmuted = SharedValue(0)
    @ObservationIgnored private var systemListeners: [HALListener] = []
    @ObservationIgnored private var outputListeners: [HALListener] = []
    @ObservationIgnored private var listenedOutputs: [AudioObjectID] = []
    @ObservationIgnored private var inputListeners: [HALListener] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// What Soundcheck last wrote to each output's own volume. Devices round what they're given,
    /// so reading back a value close to this isn't someone else changing it.
    @ObservationIgnored private var written: [String: Float] = [:]
    @ObservationIgnored private var writtenMic: [String: Float] = [:]
    /// Speakers and microphones Soundcheck has seen before (their levels are remembered).
    @ObservationIgnored private var knownOutputs: Set<String> = []
    @ObservationIgnored private var knownMics: Set<String> = []
    @ObservationIgnored private var activeMicUIDs: Set<String> = []
    /// Every speaker and microphone Soundcheck has seen: name and glyph (uid → [name, symbol]).
    private(set) var speakerNames: [String: [String]] = [:]
    private(set) var micNames: [String: [String]] = [:]

    /// A speaker or microphone for Saved Setups: connected or remembered.
    struct KnownDevice: Identifiable, Hashable {
        let id: String // UID
        let name: String
        let symbol: String
        let isConnected: Bool
    }

    var knownSpeakers: [KnownDevice] { known(speakerNames, connected: outputDevices) }
    var knownMicrophones: [KnownDevice] { known(micNames, connected: inputDevices) }

    private func known(_ names: [String: [String]], connected: [AudioDevice]) -> [KnownDevice] {
        let present = Set(connected.map(\.uid))
        return names.map { uid, info in
            KnownDevice(id: uid, name: info.first ?? uid, symbol: info.count > 1 ? info[1] : "hifispeaker", isConnected: present.contains(uid))
        }
        .sorted { ($0.isConnected ? 0 : 1, $0.name.lowercased()) < ($1.isConnected ? 0 : 1, $1.name.lowercased()) }
    }

    private func rememberNames() {
        var changed = false
        for device in outputDevices where speakerNames[device.uid] != [device.name, device.symbol(.output)] {
            speakerNames[device.uid] = [device.name, device.symbol(.output)]
            changed = true
        }
        for device in inputDevices where micNames[device.uid] != [device.name, device.symbol(.input)] {
            micNames[device.uid] = [device.name, device.symbol(.input)]
            changed = true
        }
        if changed { save() }
    }

    // MARK: Saved Setups

    /// Levels of any speaker, app or microphone, connected or not (for Saved Setups).
    func rememberedSpeakerVolume(_ uid: String) -> Float { outputLevels.value(uid) }
    func rememberedMicVolume(_ uid: String) -> Float { micLevels.value(uid) }

    /// How things are now, as a setup.
    func captureSetup(named name: String) -> SavedSetup {
        let appIDs = apps.filter { $0.isPlaying || pinnedApps.contains($0.id) || needsOwnTap($0.id) || routedApps.contains($0.id) }.map(\.id)
        return SavedSetup(
            name: name,
            speakers: activeOutputs.map { SavedSetup.Level(id: $0.uid, volume: outputLevels.value($0.uid)) },
            apps: appIDs.map { id in
                SavedSetup.AppLevel(id: id, volume: appLevels.value(id), muted: mutedApps.contains(id),
                                    outputs: isSplit ? routes[id] : nil)
            },
            split: isSplit,
            route: SavedSetup.Route(isOn: isRouting,
                                    microphones: routeMics.map { SavedSetup.Level(id: $0, volume: micLevels.value($0)) },
                                    apps: Array(routedApps))
        )
    }

    /// Puts a setup in place. Speakers that aren't connected keep their level for when they are.
    func apply(_ setup: SavedSetup) {
        beforeHeadphones = nil
        // Speakers: the connected ones in the setup become the outputs.
        for speaker in setup.speakers { knownOutputs.insert(speaker.id); outputLevels.set(speaker.volume, for: speaker.id) }
        let present = setup.speakers.compactMap { speaker in outputDevices.first { $0.uid == speaker.id } }
        if let first = present.first {
            members = present
            if HAL.defaultOutput != first.id {
                HAL.write(.system, kAudioHardwarePropertyDefaultOutputDevice, value: first.id)
            }
        }
        // Apps.
        for app in setup.apps {
            appLevels.set(app.volume, for: app.id)
            boosts[app.id] = nil
            if app.muted { mutedApps.insert(app.id) } else { mutedApps.remove(app.id) }
            gains(for: app.id).muted.value = app.muted ? 1 : 0
            routes[app.id] = app.outputs?.isEmpty == false ? app.outputs : nil
        }
        isSplit = setup.split
        // Route.
        for mic in setup.route.microphones { knownMics.insert(mic.id); micLevels.set(mic.volume, for: mic.id) }
        routeMics = setup.route.microphones.map(\.id)
        routedApps = Set(setup.route.apps)
        if setup.route.isOn != isRouting {
            setRouting(setup.route.isOn)
        } else {
            rebuildMixer()
        }
        refreshInput()
        for mic in activeMics { writtenMic[mic.uid] = nil }
        applyMicVolumes()
        outputsChanged()
    }
    /// When Soundcheck last wrote each device's volume. Writes happen in the background, so for
    /// a moment after one the device can still report values that are on their way out.
    @ObservationIgnored private var lastWrite: [String: Date] = [:]
    private func recentlyWritten(_ uid: String) -> Bool { Date().timeIntervalSince(lastWrite[uid] ?? .distantPast) < 0.6 }
    @ObservationIgnored private var wasActive = false
    /// Processes (by ID) that have made sound since Soundcheck started watching. An app gets a
    /// new one each time it's opened, which is when a muted app is told it's muted again.
    @ObservationIgnored private var soundedPIDs: Set<pid_t> = []
    @ObservationIgnored private var hasSeenFirstApps = false
    @ObservationIgnored private var askingPermission = false
    /// The level Soundcheck gives each output that has no volume control of its own (most
    /// displays). One it hasn't seen yet starts at full, which is how macOS plays it.
    @ObservationIgnored private var softwareLevels: [String: Float] = [:]

    private init() {}

    func start() {
        // Soundcheck's own audio IO mustn't keep the Mac awake.
        HAL.write(.system, kAudioHardwarePropertySleepingIsAllowed, value: UInt32(1))
        loadSettings()
        systemListeners = [
            HALListener(.system, kAudioHardwarePropertyDevices) { [weak self] in self?.devicesChanged() },
            HALListener(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.defaultOutputChanged() },
            HALListener(.system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.defaultInputChanged() },
        ].compactMap { $0 }
        monitor.onChange = { [weak self] in self?.processesChanged() }
        monitor.onTick = { [weak self] in
            self?.idleQuietTaps()
            self?.warnMutedApps()
        }
        monitor.start()

        outputDevices = AudioDevice.list(.output)
        let saved = (UserDefaults.standard.stringArray(forKey: Keys.outputs) ?? []).compactMap { uid in
            outputDevices.first { $0.uid == uid }
        }
        let current = AudioDevice(id: HAL.defaultOutput)
        members = saved.count >= 2 && saved.first?.uid == current?.uid ? saved : (current.map { [$0] } ?? [])
        apps = monitor.apps
        watchHeadphoneJack()
        refreshInput()
        rememberNames()
        if !airPlayIDs.isEmpty { AirPlayBrowser.shared.start() }
        watchAirPlayBrowser()
        // Soundcheck Mic is macOS's input while Soundcheck runs.
        if usesSoundcheckMic { takeOverInput() }
        outputsChanged()
    }

    /// Every app gets its own sound back, and the real microphone is the input again.
    func shutdown() {
        if micsMuted { muteMicrophones(false) }
        for meter in appMeters.values { meter.invalidate() }
        appMeters = [:]
        stopAirPlay()
        stopTaps()
        mixer?.invalidate()
        mixer = nil
        if usesSoundcheckMic { restoreRealMicrophone() }
    }

    private func stopTaps() {
        globalTap?.invalidate()
        globalTap = nil
        for tap in appTaps.values { tap.invalidate() }
        appTaps.removeAll()
    }

    // MARK: Outputs

    /// Clicking an output: play through it alone.
    func selectOnly(_ device: AudioDevice) {
        if !airPlayIDs.isEmpty {
            airPlayIDs = []
            airPlayOnly = false
        }
        if members.map(\.uid) == [device.uid] { outputsChanged(); return }
        beforeHeadphones = nil
        members = [device]
        if HAL.defaultOutput != device.id {
            HAL.write(.system, kAudioHardwarePropertyDefaultOutputDevice, value: device.id)
        }
        outputsChanged()
    }

    /// Its circle: add it to the outputs, or take it out.
    func toggleOutput(_ device: AudioDevice) {
        beforeHeadphones = nil
        if let index = members.firstIndex(where: { $0.uid == device.uid }) {
            if members.count == 1 && !activeAirPlay.isEmpty {
                setAirPlayOnly(!airPlayOnly)
                return
            }
            guard members.count > 1 else { return }
            members.remove(at: index)
            if index == 0, let first = members.first {
                // The first output is macOS's default (where apps play before Soundcheck takes over).
                HAL.write(.system, kAudioHardwarePropertyDefaultOutputDevice, value: first.id)
            }
        } else {
            members.append(device)
        }
        outputsChanged()
    }

    // MARK: AirPlay

    /// The AirPlay speakers chosen (by device ID), played through alongside the regular speakers
    /// (in sync: those are held back by the AirPlay delay) or on their own.
    private(set) var airPlayIDs: [String] = []
    /// Only the AirPlay speakers play; the regular speakers are silent.
    private(set) var airPlayOnly = false
    /// Each chosen AirPlay speaker's connection.
    enum AirPlayState: Equatable { case connecting, playing, failed(String) }
    private(set) var airPlayStates: [String: AirPlayState] = [:]

    var activeAirPlay: [AirPlaySpeaker] {
        airPlayIDs.compactMap { id in AirPlayBrowser.shared.speakers.first { $0.id == id } }
    }
    static func airPlayKey(_ id: String) -> String { "airplay:" + id }
    func airPlayVolume(_ speaker: AirPlaySpeaker) -> Float { outputLevels.value(Self.airPlayKey(speaker.id)) }

    func setAirPlayVolume(_ volume: Float, for speaker: AirPlaySpeaker) {
        outputLevels.set(volume, for: Self.airPlayKey(speaker.id))
        volumesChanged()
    }

    /// Adds an AirPlay speaker to the speakers in use, or takes it out.
    func toggleAirPlay(_ speaker: AirPlaySpeaker) {
        beforeHeadphones = nil
        if let index = airPlayIDs.firstIndex(of: speaker.id) {
            airPlayIDs.remove(at: index)
            if airPlayIDs.isEmpty { airPlayOnly = false }
        } else {
            airPlayIDs.append(speaker.id)
            let key = Self.airPlayKey(speaker.id)
            if !knownOutputs.contains(key) {
                knownOutputs.insert(key)
                outputLevels.set(min(speakersVolume, 0.5), for: key) // start no louder than half
            }
            speakerNames[key] = [speaker.name, speaker.symbol]
        }
        outputsChanged()
    }

    /// The regular speakers on or off while AirPlay speakers play.
    func setAirPlayOnly(_ on: Bool) {
        airPlayOnly = on && !activeAirPlay.isEmpty
        outputsChanged()
    }

    /// AirPlay speakers come and go (and the chosen ones are only found a moment after launch).
    private func watchAirPlayBrowser() {
        withObservationTracking {
            _ = AirPlayBrowser.shared.speakers
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let engine = AudioEngine.shared
                    if !engine.airPlayIDs.isEmpty { engine.outputsChanged() }
                    engine.watchAirPlayBrowser()
                }
            }
        }
    }

    /// An Apple TV (or TV) asking for the code on its screen, the first time it's paired.
    private(set) var airPlayCodeRequest: String?
    @ObservationIgnored private var airPlayCodeReply: (@Sendable (String?) -> Void)?

    func answerAirPlayCode(_ code: String?) {
        let reply = airPlayCodeReply
        airPlayCodeReply = nil
        airPlayCodeRequest = nil
        reply?(code?.trimmingCharacters(in: .whitespaces).isEmpty == false ? code : nil)
    }

    @ObservationIgnored private var airPlaySessions: [String: AirPlaySession] = [:]
    @ObservationIgnored private var mainMixer: MainMixer?
    @ObservationIgnored private var mainMixerSilent = false
    @ObservationIgnored private let airPlayTimeline = AirPlayTimeline()

    /// Connects to the chosen AirPlay speakers and lets go of the others.
    private func syncAirPlaySessions() {
        let wanted = Set(activeAirPlay.map(\.id))
        for (id, session) in airPlaySessions where !wanted.contains(id) {
            session.stop()
            airPlaySessions[id] = nil
            airPlayStates[id] = nil
        }
        for speaker in activeAirPlay where airPlaySessions[speaker.id] == nil {
            let session = AirPlaySession(speaker: speaker, timeline: airPlayTimeline)
            session.allowsPTP = !airPlayWithoutPTP.contains(speaker.id)
            airPlaySessions[speaker.id] = session
            airPlayStates[speaker.id] = .connecting
            let id = speaker.id
            session.onError = { error in
                DispatchQueue.main.async { MainActor.assumeIsolated { AudioEngine.shared.airPlayFailed(id, error) } }
            }
            // Apple TVs show a code the first time; it's typed into the AirPlay list.
            session.requestPIN = { reply in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let engine = AudioEngine.shared
                        engine.airPlayCodeReply?(nil)
                        engine.airPlayCodeReply = reply
                        engine.airPlayCodeRequest = id
                    }
                }
            }
            session.start { error in
                MainActor.assumeIsolated { AudioEngine.shared.airPlayStarted(id, error) }
            }
        }
        feedAirPlay()
    }

    private func airPlayStarted(_ id: String, _ error: Error?) {
        guard airPlaySessions[id] != nil else { return }
        if let error {
            airPlayFailed(id, error)
            return
        }
        airPlayStates[id] = .playing
        airPlayRetries[id] = nil
        applyVolumes()
        feedAirPlay()
    }

    private func airPlayFailed(_ id: String, _ error: Error) {
        log.error("AirPlay \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        let session = airPlaySessions.removeValue(forKey: id)
        session?.stop()
        feedAirPlay()
        // Connections can fail for a moment (the network waking up, the speaker busy): try again
        // a few times before saying so. A speaker that fails twice with PTP timing is tried the
        // older NTP way from then on (until Soundcheck restarts).
        let tries = airPlayRetries[id, default: 0]
        if tries >= 1, session?.timingMethod == .ptp {
            airPlayWithoutPTP.insert(id)
            log.notice("AirPlay \(id, privacy: .public): trying NTP timing instead of PTP")
        }
        if tries < 3, airPlayIDs.contains(id) {
            airPlayRetries[id] = tries + 1
            airPlayStates[id] = .connecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    let engine = AudioEngine.shared
                    if engine.airPlayIDs.contains(id) && engine.airPlaySessions[id] == nil { engine.syncAirPlaySessions() }
                }
            }
        } else {
            airPlayStates[id] = .failed(error.localizedDescription)
        }
    }
    @ObservationIgnored private var airPlayRetries: [String: Int] = [:]
    @ObservationIgnored private var airPlayWithoutPTP: Set<String> = []

    /// The connected sessions get the mix (each shifted by its sync adjustment), and the regular
    /// speakers wait as long as AirPlay takes.
    private func feedAirPlay() {
        let playing = airPlaySessions.filter { airPlayStates[$0.key] == .playing }
        // Each speaker is heard after its own delay; the slowest sets the pace, the faster ones are
        // sent their sound that much later, and the regular speakers wait as long as the slowest.
        let slowest = playing.values.map(\.playbackDelay).max() ?? 0
        mainMixer?.feed.setSessions(playing.map { id, session in
            (session, Int64((airPlaySync(id) - (slowest - session.playbackDelay)) * 44_100))
        })
        mainMixer?.setDelay(seconds: slowest)
    }

    /// How much earlier (seconds) an AirPlay speaker gets the sound, so it lines up with the
    /// others. AirPlay speakers add their own processing delay on top of AirPlay's buffer, and
    /// it differs by model, so it's set by ear.
    private(set) var airPlaySyncs: [String: Double] = [:]
    func airPlaySync(_ id: String) -> Double { airPlaySyncs[id] ?? 0 }

    func setAirPlaySync(_ seconds: Double, for id: String) {
        airPlaySyncs[id] = abs(seconds) < 0.005 ? nil : seconds
        feedAirPlay()
        save()
    }

    // MARK: Split (apps on their own outputs)

    func setSplit(_ on: Bool) {
        isSplit = on
        beforeHeadphones = nil
        outputsChanged()
    }

    /// Adds or removes one of an app's own outputs. With none left it follows the main outputs.
    func toggleRoute(_ device: AudioDevice, for id: String) {
        var route = routes[id] ?? []
        if let index = route.firstIndex(of: device.uid) { route.remove(at: index) } else { route.append(device.uid) }
        routes[id] = route.isEmpty ? nil : route
        outputsChanged()
    }

    func followMainOutputs(_ id: String) {
        routes[id] = nil
        outputsChanged()
    }

    // MARK: Volume

    func setKnob(_ knob: Knob) {
        self.knob = knob
        NotificationCenter.default.post(name: Self.didChangeVolume, object: nil)
        save()
    }

    /// The main slider: the loudest in the group goes there, the rest move by the same amount.
    func setKnobValue(_ value: Float) {
        switch knob {
        case .speakers:
            outputLevels.setTop(value, speakerKeys)
            if isMuted && value > 0 { isMuted = false }
        case .apps:
            appLevels.setTop(value, playingApps.map(\.id))
        case .mics:
            micLevels.setTop(value, activeMics.map(\.uid))
            applyMicVolumes()
        }
        volumesChanged()
    }

    /// A volume key: everything in the group the main slider controls moves by the same amount.
    func step(_ delta: Float) {
        switch knob {
        case .speakers:
            if isMuted { isMuted = false }
            outputLevels.step(delta, speakerKeys)
        case .apps:
            appLevels.step(delta, playingApps.map(\.id))
        case .mics:
            micLevels.step(delta, activeMics.map(\.uid))
            applyMicVolumes()
        }
        volumesChanged()
    }

    /// One speaker's own bar (shown with Mix).
    func setOutputVolume(_ volume: Float, for device: AudioDevice) {
        outputLevels.set(volume, for: device.uid)
        volumesChanged()
    }

    /// Closing Mix puts every speaker in use at the loudest one's level.
    func setMixing(_ on: Bool) {
        mixRequested = on
        if !on { evenOutSpeakers() }
        save()
    }

    private func evenOutSpeakers() {
        let uids = speakerKeys
        let top = outputLevels.top(uids)
        for uid in uids { outputLevels.set(top, for: uid) }
        volumesChanged()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        volumesChanged()
    }

    private func volumesChanged() {
        for device in activeOutputs where !device.hasHardwareVolume {
            softwareLevels[device.uid] = outputLevels.value(device.uid)
        }
        applyVolumes()
        syncTaps()
        NotificationCenter.default.post(name: Self.didChangeVolume, object: nil)
        save()
    }

    /// Writes each output's volume (to the device when it has a volume control, otherwise as
    /// Soundcheck's own gain for it) and each app's gain.
    private func applyVolumes() {
        let scope = kAudioObjectPropertyScopeOutput
        for device in activeOutputs {
            let volume = outputLevels.value(device.uid)
            if device.hasHardwareVolume {
                if abs((written[device.uid] ?? -1) - volume) > 0.001 {
                    written[device.uid] = volume
                    lastWrite[device.uid] = Date()
                    VolumeWriter.shared.set(device.id, scope: scope, volume)
                }
                if DeviceVolume.canMute(device.id, scope: scope), DeviceVolume.isMuted(device.id, scope: scope) != isMuted {
                    DeviceVolume.setMuted(device.id, scope: scope, isMuted)
                }
                softwareGain(device.uid).value = 1
            } else {
                softwareGain(device.uid).value = isMuted ? 0 : Self.taper(volume)
            }
        }
        for speaker in activeAirPlay {
            airPlaySessions[speaker.id]?.setVolume(isMuted ? 0 : outputLevels.value(Self.airPlayKey(speaker.id)))
        }
        othersGain.value = Self.taper(appLevels.base) * duckFactor
        for (id, gains) in appGains { gains.gain.value = appGain(id) }
    }

    /// An app's gain: its level, its boost, and (unless it's the one on the call) the call ducking.
    private func appGain(_ id: String) -> Float {
        let boost = allowBoost ? (boosts[id] ?? 1) : 1
        let duck = callApps.contains(id) ? 1 : duckFactor
        // Past 100% the slider adds up to +12 dB (×4); TapPlayer keeps the peaks from clipping hard.
        return Self.taper(appLevels.value(id)) * boost * boost * duck
    }

    /// Cubed: sounds about as even as the volume steps of outputs that have a volume control.
    private static func taper(_ level: Float) -> Float { level * level * level }

    private func softwareGain(_ uid: String) -> SharedValue {
        if let gain = softwareGains[uid] { return gain }
        let gain = SharedValue(1)
        softwareGains[uid] = gain
        return gain
    }

    // MARK: Apps

    /// An app's own slider: only that app changes. With Boost on it goes to 2 (200%).
    func setAppLevel(_ level: Float, for id: String) {
        if allowBoost && level > 1 {
            appLevels.set(1, for: id)
            boosts[id] = min(level, 2)
        } else {
            appLevels.set(level, for: id)
            boosts[id] = nil
        }
        applyVolumes()
        syncTaps()
        NotificationCenter.default.post(name: Self.didChangeVolume, object: nil)
        save()
    }

    func setAppMuted(_ muted: Bool, for id: String) {
        if muted { mutedApps.insert(id) } else { mutedApps.remove(id) }
        gains(for: id).muted.value = muted ? 1 : 0
        syncTaps()
        save()
    }

    /// Has its own level or boost, is muted, is sent to its own outputs, or is on a call while
    /// the others are ducked.
    private func needsOwnTap(_ id: String) -> Bool {
        appLevels.hasOwnLevel(id) || mutedApps.contains(id) || isRouted(id)
            || (allowBoost && (boosts[id] ?? 1) > 1.001)
            || (duckFactor < 0.999 && callApps.contains(id))
    }

    private func gains(for id: String) -> (gain: SharedValue, muted: SharedValue) {
        if let gains = appGains[id] { return gains }
        let gains = (SharedValue(appGain(id)), SharedValue(mutedApps.contains(id) ? 1 : 0))
        appGains[id] = gains
        return gains
    }

    func setDuckMode(_ mode: DuckMode) {
        duckMode = mode
        updateDucking()
        save()
    }

    func setSwitchToHeadphones(_ on: Bool) {
        switchToHeadphones = on
        if !on { beforeHeadphones = nil }
        save()
    }

    func setAllowBoost(_ on: Bool) {
        allowBoost = on
        if !on { boosts = [:] }
        applyVolumes()
        syncTaps()
        save()
    }

    // MARK: Quiet Apps in Calls

    /// Apps using a microphone (on a call); they're never ducked.
    var callApps: Set<String> { Set(apps.filter(\.isListening).map(\.id)) }
    /// 1 normally; eases down to the ducked level while a call is on, and back after.
    @ObservationIgnored private var duckFactor: Float = 1
    @ObservationIgnored private var duckTimer: Timer?

    private func updateDucking() {
        let target: Float = duckMode == .off || callApps.isEmpty ? 1 : (duckMode == .mute ? 0 : 0.2)
        guard abs(target - duckFactor) > 0.001 || duckTimer != nil else { return }
        duckTimer?.invalidate()
        let start = duckFactor, began = Date(), duration = 0.6
        if target < 1 { syncTaps() } // the taps carry the ducking, so they come first
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = Float(min(Date().timeIntervalSince(began) / duration, 1))
                self.duckFactor = start + (target - start) * (t * t * (3 - 2 * t))
                self.applyVolumes()
                if t >= 1 {
                    timer.invalidate()
                    self.duckTimer = nil
                    self.syncTaps() // taps that were only there for the ducking go away
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        duckTimer = timer
    }

    // MARK: Mute Mics

    func setMicsMuted(_ muted: Bool) {
        micsMuted = muted
        muteMicrophones(muted)
        if !muted { applyMicVolumes() } // ones turned all the way down stay muted
        rebuildMixer() // Soundcheck Mic goes quiet too
        onNotice?(HUDNotice(symbol: muted ? "mic.slash.fill" : "mic.fill", title: muted ? "Mics Muted" : "Mics On", detail: nil))
    }

    /// Microphones that can't be muted are turned to zero instead (and back after).
    @ObservationIgnored private var zeroedMics: [String: Float] = [:]

    private func muteMicrophones(_ muted: Bool) {
        let scope = kAudioObjectPropertyScopeInput
        for device in inputDevices where device.uid != MicDriver.microphoneUID {
            if DeviceVolume.canMute(device.id, scope: scope) {
                if DeviceVolume.isMuted(device.id, scope: scope) != muted { DeviceVolume.setMuted(device.id, scope: scope, muted) }
            } else if settableMics.contains(device.uid) {
                if muted, zeroedMics[device.uid] == nil {
                    zeroedMics[device.uid] = DeviceVolume.get(device.id, scope: scope) ?? micLevels.value(device.uid)
                    lastWrite[device.uid] = Date()
                    VolumeWriter.shared.set(device.id, scope: scope, 0)
                } else if !muted, let volume = zeroedMics.removeValue(forKey: device.uid) {
                    lastWrite[device.uid] = Date()
                    VolumeWriter.shared.set(device.id, scope: scope, volume)
                }
            }
        }
    }

    // MARK: Switch to Headphones

    /// What was playing where before headphones took over, to go back to when they disconnect.
    /// Forgotten if you change the outputs meanwhile.
    @ObservationIgnored private var beforeHeadphones: (members: [String], split: Bool, headphones: String)?

    /// Headphones appeared (or were plugged into the Mac): everything plays through them.
    private func switchToHeadphonesIfNew(_ device: AudioDevice) -> Bool {
        guard switchToHeadphones, device.isHeadphones, members.map(\.uid) != [device.uid] || isSplit else { return false }
        beforeHeadphones = (memberUIDs, isSplit, device.uid)
        isSplit = false
        members = [device]
        if HAL.defaultOutput != device.id {
            HAL.write(.system, kAudioHardwarePropertyDefaultOutputDevice, value: device.id)
        }
        outputsChanged()
        onHeadphones?()
        return true
    }

    /// The headphones went away: back to what was playing before, if nothing was changed since.
    private func restoreAfterHeadphones() -> Bool {
        guard let before = beforeHeadphones else { return false }
        beforeHeadphones = nil
        let restored = before.members.compactMap { uid in outputDevices.first { $0.uid == uid } }
        guard let first = restored.first else { return false }
        members = restored
        isSplit = before.split
        if HAL.defaultOutput != first.id {
            HAL.write(.system, kAudioHardwarePropertyDefaultOutputDevice, value: first.id)
        }
        outputsChanged()
        return true
    }

    /// The Mac's own headphone jack: the built-in output switches between speakers and headphones.
    @ObservationIgnored private var jackListener: HALListener?
    @ObservationIgnored private var jackDevice: AudioObjectID = .unknown

    private func watchHeadphoneJack() {
        guard let builtIn = outputDevices.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) else { return }
        guard builtIn.id != jackDevice else { return }
        jackDevice = builtIn.id
        jackListener = HALListener(builtIn.id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
            guard let self, let device = AudioDevice(id: self.jackDevice) else { return }
            if device.isHeadphones {
                _ = self.switchToHeadphonesIfNew(device)
            } else if self.beforeHeadphones?.headphones == device.uid, self.members.map(\.uid) == [device.uid] {
                _ = self.restoreAfterHeadphones()
            }
        }
    }

    func togglePin(_ id: String) {
        if pinnedApps.contains(id) { pinnedApps.remove(id) } else { pinnedApps.insert(id) }
        save()
    }

    func setKeepInMenuBar(_ on: Bool) {
        keepInMenuBar = on
        NotificationCenter.default.post(name: Self.didChangeActivity, object: nil)
        save()
    }

    /// Options › Reset: Route off and back to one microphone, Split off, Mix closed with every
    /// speaker at the loudest one's level, every app back to full (unmuted, no boost), and the
    /// main slider back on Speakers.
    func reset() {
        isRouting = false
        routeMics = []
        routedApps = []
        isSplit = false
        routes = [:]
        appLevels = LinkedLevels()
        boosts = [:]
        for id in mutedApps { gains(for: id).muted.value = 0 }
        mutedApps = []
        mixRequested = false
        knob = .speakers
        outputsChanged()
        evenOutSpeakers()
        refreshInput()
        rebuildMixer()
        save()
    }

    /// While the panel or the volume pill is up (`reason`), apps keep their rows even when they go
    /// quiet for a moment, so the rows don't flicker.
    func holdApps(_ reason: String, _ on: Bool) {
        let wasHolding = !holdReasons.isEmpty
        if on { holdReasons.insert(reason) } else { holdReasons.remove(reason) }
        if holdReasons.isEmpty {
            heldApps = []
        } else if !wasHolding {
            heldApps = Set(apps.filter(\.isPlaying).map(\.id))
        }
        if on && reason == "panel" {
            isMicrophoneInstalled = MicDriver.isInstalled
            refreshInput()
        }
    }
    @ObservationIgnored private var holdReasons: Set<String> = []

    // MARK: Microphone
    //
    // With Soundcheck Mic added, it's always macOS's input while Soundcheck runs, and the
    // microphone you pick here is what goes into it (with Route: several microphones, and apps).
    // So apps and browsers never need their microphone changed. Without Soundcheck Mic, picking a
    // microphone sets macOS's input.

    /// The real microphone picked in the dropdown, which feeds Soundcheck Mic.
    private(set) var selectedMicUID: String?
    /// Soundcheck Mic is added, so it's the input and the dropdown picks what feeds it.
    var usesSoundcheckMic: Bool { isMicrophoneInstalled }

    /// The microphone the dropdown shows.
    var shownInput: AudioDevice? {
        if usesSoundcheckMic {
            return selectedMicUID.flatMap { uid in inputDevices.first { $0.uid == uid } } ?? inputDevices.first
        }
        return defaultInput.flatMap { input in inputDevices.first { $0.uid == input.uid } }
    }

    func selectInput(_ device: AudioDevice) {
        if usesSoundcheckMic {
            selectedMicUID = device.uid
            refreshInput()
            rebuildMixer()
            save()
        } else {
            HAL.write(.system, kAudioHardwarePropertyDefaultInputDevice, value: device.id)
        }
    }

    /// One microphone's own slider.
    func setMicVolume(_ volume: Float, for device: AudioDevice) {
        micLevels.set(volume, for: device.uid)
        applyMicVolumes()
        NotificationCenter.default.post(name: Self.didChangeVolume, object: nil)
        save()
    }

    /// Writes the microphones' levels to the devices. One turned all the way down is muted too
    /// (some don't go fully silent at their lowest level), so zero means nothing gets through.
    private func applyMicVolumes() {
        let scope = kAudioObjectPropertyScopeInput
        for device in activeMics {
            let volume = micLevels.value(device.uid)
            if abs((writtenMic[device.uid] ?? -1) - volume) > 0.001 {
                writtenMic[device.uid] = volume
                lastWrite[device.uid] = Date()
                VolumeWriter.shared.set(device.id, scope: scope, volume)
            }
            let mute = micsMuted || volume < 0.001
            if DeviceVolume.canMute(device.id, scope: scope), DeviceVolume.isMuted(device.id, scope: scope) != mute {
                DeviceVolume.setMuted(device.id, scope: scope, mute)
            }
        }
        updateMicGains()
    }

    /// Each microphone's gain in Soundcheck Mic: 0 when it's turned all the way down or muted.
    @ObservationIgnored private var micGains: [String: SharedValue] = [:]

    private func micGain(_ uid: String) -> SharedValue {
        if let gain = micGains[uid] { return gain }
        let gain = SharedValue(1)
        micGains[uid] = gain
        return gain
    }

    private func updateMicGains() {
        for device in feedingMics {
            let silent = micsMuted || (settableMics.contains(device.uid) && micLevels.value(device.uid) < 0.001)
            micGain(device.uid).value = silent ? 0 : 1
        }
    }

    private func refreshInput() {
        let devices = AudioDevice.list(.input)
        if devices.map(\.id) != inputDevices.map(\.id) || settableMics.isEmpty {
            settableMics = Set(devices.filter { DeviceVolume.canSet($0.id, scope: kAudioObjectPropertyScopeInput) }.map(\.uid))
        }
        inputDevices = devices
        defaultInput = AudioDevice(id: HAL.defaultInput)
        // The microphones' own levels are the truth (System Settings or the device may have
        // changed them); watch them for changes.
        let scope = kAudioObjectPropertyScopeInput
        let mics = activeMics
        // Like speakers: a microphone's own level the first time it's seen, the remembered one after.
        for device in mics where !knownMics.contains(device.uid) {
            knownMics.insert(device.uid)
            if let volume = DeviceVolume.get(device.id, scope: scope) { micLevels.set(volume, for: device.uid) }
        }
        let newlyActive = mics.filter { !activeMicUIDs.contains($0.uid) }
        for device in newlyActive { writtenMic[device.uid] = nil }
        activeMicUIDs = Set(mics.map(\.uid))
        if !newlyActive.isEmpty { applyMicVolumes() }
        if micsMuted { muteMicrophones(true) } // ones plugged in while muted
        inputListeners = mics.compactMap { device in
            HALListener(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) { [weak self] in
                guard let self, !self.recentlyWritten(device.uid),
                      let volume = DeviceVolume.get(device.id, scope: scope),
                      abs(volume - self.micLevels.value(device.uid)) > 0.005,
                      abs(volume - (self.writtenMic[device.uid] ?? -1)) > 0.02 else { return }
                self.writtenMic[device.uid] = nil
                self.micLevels.set(volume, for: device.uid)
                NotificationCenter.default.post(name: Self.didChangeVolume, object: nil)
            }
        }
    }

    // MARK: Route (several microphones, and apps, into Soundcheck Mic)

    func setRouting(_ on: Bool) {
        guard on != isRouting else { return }
        isRouting = on
        // Start from the microphone picked in the dropdown.
        if on, routeMics.isEmpty, let mic = shownInput { routeMics = [mic.uid] }
        refreshInput()
        rebuildMixer()
        save()
    }

    func toggleRouteMic(_ device: AudioDevice) {
        if let index = routeMics.firstIndex(of: device.uid) { routeMics.remove(at: index) } else { routeMics.append(device.uid) }
        rebuildMixer()
        refreshInput()
        save()
    }

    func toggleRoutedApp(_ id: String) {
        if routedApps.contains(id) { routedApps.remove(id) } else { routedApps.insert(id) }
        rebuildMixer()
        save()
    }

    /// Adds Soundcheck Mic to macOS (asks for an administrator password).
    func installMicrophone() {
        guard !isInstallingMicrophone else { return }
        isInstallingMicrophone = true
        MicDriver.install { [weak self] installed in
            guard let self else { return }
            self.isInstallingMicrophone = false
            self.isMicrophoneInstalled = installed
            if installed { self.takeOverInput() }
        }
    }

    /// Makes Soundcheck Mic macOS's input; the input until now becomes the microphone feeding it.
    private func takeOverInput() {
        isMicrophoneInstalled = MicDriver.isInstalled
        guard isMicrophoneInstalled else { return }
        if let input = defaultInput, input.uid != MicDriver.microphoneUID, inputDevices.contains(where: { $0.uid == input.uid }) {
            selectedMicUID = input.uid
        }
        if selectedMicUID.flatMap({ uid in inputDevices.first { $0.uid == uid } }) == nil {
            selectedMicUID = routeMics.first { uid in inputDevices.contains { $0.uid == uid } } ?? inputDevices.first?.uid
        }
        let microphone = HAL.device(forUID: MicDriver.microphoneUID)
        if microphone.isValid && HAL.defaultInput != microphone {
            HAL.write(.system, kAudioHardwarePropertyDefaultInputDevice, value: microphone)
        }
        watchMicrophoneUse()
        refreshInput()
        rebuildMixer()
        save()
    }

    /// Back to the real microphone as macOS's input (when Soundcheck quits).
    private func restoreRealMicrophone() {
        guard let real = shownInput, HAL.defaultInput != real.id else { return }
        HAL.write(.system, kAudioHardwarePropertyDefaultInputDevice, value: real.id)
    }

    // The real microphones are only read while an app is listening to Soundcheck Mic (or the
    // panel is open, for its level): reading them otherwise would keep macOS's orange microphone
    // dot on.
    @ObservationIgnored private var useListener: HALListener?
    @ObservationIgnored private var watchedMicrophone = AudioObjectID.unknown
    @ObservationIgnored private var microphoneInUse = false
    @ObservationIgnored private var metering = false

    private func watchMicrophoneUse() {
        let microphone = HAL.device(forUID: MicDriver.microphoneUID)
        guard microphone.isValid, microphone != watchedMicrophone else { return }
        watchedMicrophone = microphone
        useListener = HALListener(microphone, kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in
            self?.microphoneUseChanged()
        }
        microphoneUseChanged()
    }

    private func microphoneUseChanged() {
        let inUse = (HAL.read(watchedMicrophone, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) ?? 0) != 0
        guard inUse != microphoneInUse else { return }
        microphoneInUse = inUse
        rebuildMixer()
    }

    /// The panel is open: read the microphones for their level.
    func setMetering(_ on: Bool) {
        guard on != metering else { return }
        metering = on
        rebuildMixer()
        updateAppMeters()
    }

    /// The loudest microphone feeding Soundcheck Mic right now (ones turned all the way down
    /// don't count), for the main bar's shade when it controls the microphones.
    var micsLiveLevel: Float {
        feedingMics.filter { !settableMics.contains($0.uid) || micLevels.value($0.uid) > 0.001 }.map { liveLevel($0) }.max() ?? 0
    }

    /// The microphones' live levels (0...1), while the panel is open or an app is listening.
    func liveLevel(_ device: AudioDevice) -> Float { mixer?.level(device.uid) ?? 0 }

    /// Builds Soundcheck Mic's mix off the main thread: opening a microphone can take a moment,
    /// and the panel (which asks for the level) shouldn't wait for it.
    private func rebuildMixer() {
        mixerGeneration += 1
        let generation = mixerGeneration
        let old = mixer
        mixer = nil
        let wanted = usesSoundcheckMic && !micsMuted && (microphoneInUse || metering)
            && HAL.device(forUID: MicDriver.feedUID).isValid
        let routed = isRouting ? apps.filter { routedApps.contains($0.id) } : []
        let appSources = routed.map { (id: $0.id, processes: $0.objects, gain: routeGain($0.id)) }
        let microphones = feedingMics.map { (uid: $0.uid, gain: micGain($0.uid)) }
        updateMicGains()
        guard wanted, !microphones.isEmpty || !appSources.isEmpty else {
            if let old { mixerQueue.async { old.invalidate() } }
            return
        }
        if !appSources.isEmpty && AudioCapturePermission.status != .allowed {
            if let old { mixerQueue.async { old.invalidate() } }
            syncTaps() // asks for the permission; the mix is rebuilt once it's granted
            return
        }
        // Reading a real microphone needs macOS's Microphone permission.
        if !microphones.isEmpty && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            if let old { mixerQueue.async { old.invalidate() } }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in AudioEngine.shared.rebuildMixer() }
            }
            return
        }
        mixerQueue.async {
            old?.invalidate()
            let made: MicMixer?
            do {
                made = try MicMixer(feedUID: MicDriver.feedUID, microphones: microphones, apps: appSources)
            } catch {
                log.error("Soundcheck Mic failed: \(String(describing: error), privacy: .public)")
                made = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Something changed while it was being made: a newer one is on its way.
                    if generation == self.mixerGeneration { self.mixer = made } else if let made { self.mixerQueue.async { made.invalidate() } }
                }
            }
        }
    }

    @ObservationIgnored private var mixerGeneration = 0
    @ObservationIgnored private let mixerQueue = DispatchQueue(label: "com.mylesdean.Soundcheck.mixer", qos: .userInitiated)

    // MARK: Levels inside Soundcheck Mic

    /// Each routed app's level in Soundcheck Mic (0...1; full if never set).
    private(set) var routeAppLevels: [String: Float] = [:]
    @ObservationIgnored private var routeGains: [String: SharedValue] = [:]

    func routeAppLevel(_ id: String) -> Float { routeAppLevels[id] ?? 1 }

    func setRouteAppLevel(_ level: Float, for id: String) {
        routeAppLevels[id] = level >= 0.999 ? nil : level
        routeGain(id).value = Self.taper(level)
        save()
    }

    private func routeGain(_ id: String) -> SharedValue {
        if let gain = routeGains[id] { return gain }
        let gain = SharedValue(Self.taper(routeAppLevel(id)))
        routeGains[id] = gain
        return gain
    }

    /// A microphone's or a routed app's level going into Soundcheck Mic right now.
    func routeLiveLevel(_ id: String) -> Float { mixer?.level(id) ?? 0 }

    // MARK: App meters

    /// While the panel is open, each app in the list gets a meter (a tap that doesn't mute it).
    @ObservationIgnored private var appMeters: [String: TapMeter] = [:]
    @ObservationIgnored private var metersGeneration = 0

    /// An app's sound right now, before its slider (0 when muted; the shade scales it by the slider).
    func appLiveLevel(_ id: String) -> Float {
        guard let meter = appMeters[id], !mutedApps.contains(id) else { return 0 }
        return meter.level
    }

    private func updateAppMeters() {
        metersGeneration += 1
        let generation = metersGeneration
        let wanted = metering && AudioCapturePermission.status == .allowed
            ? Dictionary(uniqueKeysWithValues: routableApps.map { ($0.id, $0.objects) }) : [:]
        var gone: [TapMeter] = []
        for (id, meter) in appMeters where wanted[id] != meter.processes {
            gone.append(meter)
            appMeters[id] = nil
        }
        let missing = wanted.filter { appMeters[$0.key] == nil }
        guard let clock = members.first?.uid else { return }
        mixerQueue.async {
            for meter in gone { meter.invalidate() }
            var made: [String: TapMeter] = [:]
            for (id, processes) in missing {
                made[id] = try? TapMeter(processes: processes, clockUID: clock)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.metersGeneration else {
                        let stale = made.values
                        self.mixerQueue.async { for meter in stale { meter.invalidate() } }
                        return
                    }
                    self.appMeters.merge(made) { _, new in new }
                }
            }
        }
    }

    private func defaultInputChanged() {
        refreshInput()
        guard usesSoundcheckMic, let input = defaultInput, input.uid != MicDriver.microphoneUID else { return }
        // Another microphone picked somewhere else (Control Center, Sound settings, headphones
        // connecting): it's the one to feed Soundcheck Mic now, and Soundcheck Mic stays the input.
        if inputDevices.contains(where: { $0.uid == input.uid }) { selectedMicUID = input.uid }
        takeOverInput()
    }

    // MARK: Changes from macOS

    private func devicesChanged() {
        let before = Set(outputDevices.map(\.uid))
        outputDevices = AudioDevice.list(.output)
        defer { rememberNames() }
        watchHeadphoneJack()
        if let headphones = outputDevices.first(where: { !before.contains($0.uid) && $0.isHeadphones }),
           switchToHeadphonesIfNew(headphones) {
            refreshInput()
            return
        }
        if let gone = beforeHeadphones?.headphones, !outputDevices.contains(where: { $0.uid == gone }), restoreAfterHeadphones() {
            refreshInput()
            return
        }
        isMicrophoneInstalled = MicDriver.isInstalled
        // Devices can come back with new IDs (after sleep, or reconnecting), so look them up again.
        let refreshed = members.compactMap { member in outputDevices.first { $0.uid == member.uid } }
        let current = AudioDevice(id: HAL.defaultOutput)
        let next = refreshed.count >= 2 || (refreshed.count == 1 && refreshed.first?.uid == current?.uid)
            ? refreshed : (current.map { [$0] } ?? [])
        let inputsBefore = inputDevices.map(\.uid)
        let wasInstalled = watchedMicrophone
        refreshInput()
        // Soundcheck Mic just appeared (added, or macOS's audio restarted): it's the input again.
        if usesSoundcheckMic && (HAL.device(forUID: MicDriver.microphoneUID) != wasInstalled || inputsBefore != inputDevices.map(\.uid)) {
            takeOverInput()
        }
        // Soundcheck's own taps come and go as devices too; only a change to the outputs matters.
        guard next.map(\.uid) != memberUIDs || next.map(\.id) != members.map(\.id) else { return }
        members = next
        outputsChanged()
    }

    private func defaultOutputChanged() {
        guard let device = AudioDevice(id: HAL.defaultOutput) else { return }
        if members.first?.uid == device.uid { return }
        // macOS switches to headphones by itself when they connect; make it everything.
        if switchToHeadphonesIfNew(device) { return }
        if members.count > 1 {
            if members.contains(where: { $0.uid == device.uid }) { return }
            if device.isAirPlay {
                // AirPlay speakers picked while playing through several outputs join them.
                toggleOutput(device)
                return
            }
        }
        // Chosen somewhere else (Control Center, Sound settings): play there alone.
        members = [device]
        outputsChanged()
    }

    /// The outputs in use changed (or might have): take their real volumes on board, watch
    /// them, and rebuild the taps around them.
    private func outputsChanged() {
        outputDevices = AudioDevice.list(.output)
        let active = activeOutputs
        let uids = active.map(\.uid)
        let scope = kAudioObjectPropertyScopeOutput
        // Every speaker keeps its own level, connected or not: the first time Soundcheck sees one
        // it takes the volume the speaker has; after that it gives back the remembered level
        // (which has moved with the main slider meanwhile, if that was the last change).
        for device in active where !knownOutputs.contains(device.uid) {
            knownOutputs.insert(device.uid)
            let current = device.hasHardwareVolume
                ? (DeviceVolume.get(device.id, scope: scope) ?? outputLevels.base)
                : (softwareLevels[device.uid] ?? 1)
            outputLevels.set(current, for: device.uid)
        }
        _ = uids
        for device in active { written[device.uid] = nil } // write the remembered level
        if let first = members.first, first.hasHardwareVolume {
            isMuted = DeviceVolume.canMute(first.id, scope: scope) && DeviceVolume.isMuted(first.id, scope: scope)
        }
        if active.map(\.id) != listenedOutputs {
            listenedOutputs = active.map(\.id)
            outputListeners = active.flatMap { device -> [HALListener] in
                guard device.hasHardwareVolume else { return [] }
                return [
                    HALListener(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) { [weak self] in
                        self?.hardwareVolumeChanged(device)
                    },
                    HALListener(device.id, kAudioDevicePropertyMute, scope: scope) { [weak self] in
                        self?.hardwareMuteChanged(device)
                    },
                ].compactMap { $0 }
            }
        }
        volumesChanged()
    }

    /// Control Center, the Sound settings or the device itself changed an output's volume.
    private func hardwareVolumeChanged(_ device: AudioDevice) {
        guard !recentlyWritten(device.uid),
              let volume = DeviceVolume.get(device.id, scope: kAudioObjectPropertyScopeOutput),
              abs(volume - outputLevels.value(device.uid)) > 0.005,
              abs(volume - (written[device.uid] ?? -1)) > 0.02 else { return }
        written[device.uid] = nil
        if activeOutputs.count == 1 {
            outputLevels.offsets[device.uid] = nil
            outputLevels.level = volume
        } else {
            outputLevels.set(volume, for: device.uid)
        }
        volumesChanged()
    }

    private func hardwareMuteChanged(_ device: AudioDevice) {
        let muted = DeviceVolume.isMuted(device.id, scope: kAudioObjectPropertyScopeOutput)
        guard muted != isMuted else { return }
        isMuted = muted
        volumesChanged()
    }

    private func processesChanged() {
        let routedBefore = apps.filter { routedApps.contains($0.id) }.flatMap(\.objects)
        let appsBefore = Set(apps.map(\.id))
        let activeBefore = activeOutputs.map(\.uid)
        apps = monitor.apps
        // Keep showing apps that play while the panel is open.
        if !heldApps.isEmpty { heldApps.formUnion(apps.filter(\.isPlaying).map(\.id)) }
        if activeOutputs.map(\.uid) != activeBefore {
            outputsChanged()
        } else {
            syncTaps()
        }
        if isRouting && routedBefore != apps.filter({ routedApps.contains($0.id) }).flatMap(\.objects) { rebuildMixer() }
        updateDucking()
        if metering { updateAppMeters() }
        _ = appsBefore
        let active = isPlaying || isListening
        if active != wasActive {
            wasActive = active
            NotificationCenter.default.post(name: Self.didChangeActivity, object: nil)
        }
    }

    // MARK: Taps

    /// Soundcheck carries everything else when sound goes to several main outputs, to one whose
    /// level only Soundcheck can lower, or when the apps are turned down together.
    private var needsGlobalTap: Bool {
        members.count > 1
            || members.contains { !$0.hasHardwareVolume && (isMuted || outputLevels.value($0.uid) < 0.999) }
            || appLevels.base < 0.999
            || duckFactor < 0.999
    }

    private func syncTaps() {
        guard !members.isEmpty else { stopTaps(); return }
        let memberGains = members.map { (uid: $0.uid, gain: softwareGain($0.uid)) }

        // A tap without the System Audio Recording permission silences what it taps, so none
        // until macOS allows them (it asks the first time one is needed).
        let wantsTaps = needsGlobalTap || apps.contains { needsOwnTap($0.id) } || (isRouting && !routedApps.isEmpty)
            || !activeAirPlay.isEmpty
        switch AudioCapturePermission.status {
        case .allowed:
            needsPermission = false
        case .denied:
            needsPermission = wantsTaps
            stopTaps()
            return
        case .unknown:
            needsPermission = false
            stopTaps()
            if wantsTaps && !askingPermission {
                askingPermission = true
                AudioCapturePermission.request { [weak self] granted in
                    guard let self else { return }
                    self.askingPermission = false
                    if granted {
                        self.syncTaps()
                        self.rebuildMixer()
                    } else {
                        self.needsPermission = true
                    }
                }
            }
            return
        }

        // With AirPlay speakers, one mixer carries the sound (below); only apps sent to their own
        // speakers keep a tap of their own.
        let mixing = !activeAirPlay.isEmpty

        // One tap per app with its own level, muted, or on its own outputs.
        var wanted: [String: (app: AudioApp, outputs: [(uid: String, gain: SharedValue)])] = [:]
        for app in apps where needsOwnTap(app.id) && (!mixing || isRouted(app.id)) {
            wanted[app.id] = (app, outputs(for: app.id).map { (uid: $0.uid, gain: softwareGain($0.uid)) })
        }
        for (id, tap) in appTaps {
            guard let want = wanted[id], tap.outputUIDs == want.outputs.map(\.uid),
                  tap.source == .processes(want.app.objects), tap.isAlive else {
                tap.invalidate()
                appTaps[id] = nil
                continue
            }
        }
        for (id, want) in wanted where appTaps[id] == nil {
            let gains = gains(for: id)
            gains.gain.value = appGain(id)
            if let tap = makeTap(.processes(want.app.objects), outputs: want.outputs, gain: gains.gain, muted: gains.muted) {
                appTaps[id] = tap
            }
        }

        let own = monitor.ownProcessObject
        if mixing {
            globalTap?.invalidate()
            globalTap = nil
            if own.isValid { syncMainMixer(own: own) }
            syncAirPlaySessions()
            return
        }
        stopAirPlay()

        // One more for everything else.
        if needsGlobalTap && own.isValid {
            let excluded = ([own] + appTaps.values.flatMap { tap -> [AudioObjectID] in
                if case .processes(let objects) = tap.source { return objects }
                return []
            }).sorted()
            if let tap = globalTap, tap.outputUIDs == memberUIDs, tap.isAlive, tap.updateExcluded(excluded) {
                return
            }
            globalTap?.invalidate()
            globalTap = makeTap(.everythingExcept(excluded), outputs: memberGains, gain: othersGain, muted: unmuted)
        } else if let tap = globalTap {
            tap.invalidate()
            globalTap = nil
        }
    }

    /// The one mixer that carries the sound while AirPlay speakers play: each app with its own
    /// level, mute, boost or ducking as a source, then everything else at the apps' level.
    private func syncMainMixer(own: AudioObjectID) {
        let outputs = members.map { (uid: $0.uid, gain: softwareGain($0.uid)) }
        var sources: [MainMixer.Source] = []
        var claimed: [AudioObjectID] = [own]
        for app in apps where needsOwnTap(app.id) && !isRouted(app.id) {
            let gains = gains(for: app.id)
            gains.gain.value = appGain(app.id)
            sources.append(.init(tap: .processes(app.objects), gain: gains.gain, muted: gains.muted))
            claimed += app.objects
        }
        for tap in appTaps.values { if case .processes(let objects) = tap.source { claimed += objects } }
        sources.append(.init(tap: .everythingExcept(claimed.sorted()), gain: othersGain, muted: unmuted))

        let silent = !playsLocally
        if let mixer = mainMixer, mixer.outputUIDs == outputs.map(\.uid), mixer.sourceSignature == sources.map(\.tap),
           mainMixerSilent == silent, mixer.isAlive {
            return
        }
        mainMixer?.invalidate()
        mainMixer = nil
        do {
            mainMixer = try MainMixer(outputs: outputs, silent: silent, sources: sources, timeline: airPlayTimeline)
            mainMixerSilent = silent
            needsPermission = false
        } catch let error as HALError {
            if error.isPermissionDenied { needsPermission = true }
            log.error("Main mix failed: \(error.description, privacy: .public)")
        } catch {
            log.error("Main mix failed: \(error.localizedDescription, privacy: .public)")
        }
        feedAirPlay()
    }

    private func stopAirPlay() {
        mainMixer?.invalidate()
        mainMixer = nil
        for session in airPlaySessions.values { session.stop() }
        airPlaySessions = [:]
        airPlayStates = [:]
    }

    /// Lets the output idle once an app with its own tap has been quiet for half a minute. It
    /// stays muted at the source meanwhile, so it can't come back at full volume; its tap starts
    /// reading again as soon as it plays.
    /// Muted, or turned all the way down.
    private func isSilenced(_ id: String) -> Bool { mutedApps.contains(id) || appLevels.value(id) < 0.005 }

    /// The first sound an app makes after it's opened: if it's muted (or all the way down), the
    /// pill says so, once, until the app is quit and opened again. Muting an app that's already
    /// been heard says nothing (you just did it). Browsers report playing as soon as they open,
    /// before any sound, so an app with a tap of its own (every muted one) waits for real sound.
    private func warnMutedApps() {
        if !hasSeenFirstApps {
            // Already playing when Soundcheck started: nothing new to say about those.
            hasSeenFirstApps = true
            soundedPIDs.formUnion(apps.filter(\.isPlaying).map(\.pid))
            return
        }
        for app in apps where !soundedPIDs.contains(app.pid) {
            let sounding: Bool
            if let tap = appTaps[app.id], !tap.isSuspended {
                sounding = tap.takePeak() > 0.001 // about -60 dB
            } else {
                sounding = app.isPlaying
            }
            guard sounding else { continue }
            soundedPIDs.insert(app.pid)
            if isSilenced(app.id) {
                onNotice?(HUDNotice(icon: app.icon, title: app.name, detail: "Muted"))
            }
        }
        if soundedPIDs.count > 200 {
            soundedPIDs = soundedPIDs.filter { pid in kill(pid, 0) == 0 || errno == EPERM }
        }
    }

    private func idleQuietTaps() {
        // Allowed in System Settings since: start the taps that were waiting for it.
        if needsPermission, AudioCapturePermission.status == .allowed {
            syncTaps()
            rebuildMixer()
        }
        for app in apps {
            guard let tap = appTaps[app.id] else { continue }
            if app.isPlaying {
                tap.resume()
                tap.quietSince = nil
            } else if !tap.isSuspended {
                let since = tap.quietSince ?? Date()
                tap.quietSince = since
                if Date().timeIntervalSince(since) > 30 { tap.suspend() }
            }
        }
    }

    private func makeTap(_ source: TapPlayer.Source, outputs: [(uid: String, gain: SharedValue)], gain: SharedValue, muted: SharedValue) -> TapPlayer? {
        do {
            let tap = try TapPlayer(source: source, outputs: outputs, gain: gain, muted: muted)
            needsPermission = false
            return tap
        } catch let error as HALError {
            if error.isPermissionDenied { needsPermission = true }
            log.error("Tap failed: \(error.description, privacy: .public)")
        } catch {
            log.error("Tap failed: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    // MARK: Settings

    private enum Keys {
        static let outputLevels = "outputLevels.v3"
        static let appLevels = "appLevels.v3"
        static let micLevels = "micLevels"
        static let knob = "knob.v2"
        static let mixing = "mix"
        static let pinnedApps = "pinnedApps"
        static let keepInMenuBar = "keepInMenuBar"
        static let duckMode = "duckMode"
        static let switchToHeadphones = "switchToHeadphones"
        static let allowBoost = "allowBoost"
        static let boosts = "boosts"
        static let knownOutputs = "knownOutputs"
        static let knownMics = "knownMics"
        static let speakerNames = "speakerNames"
        static let micNames = "micNames"
        static let mutedApps = "mutedApps"
        static let outputs = "outputs"
        static let split = "split"
        static let routes = "routes"
        static let softwareLevels = "softwareLevels"
        static let routing = "routing"
        static let routeMics = "routeMicrophones"
        static let selectedMic = "selectedMicrophone"
        static let routeAppLevels = "routeAppLevels"
        static let airPlay = "airPlaySpeakers"
        static let airPlayOnly = "airPlayOnly"
        static let airPlaySyncs = "airPlaySync"
        static let routedApps = "routedApps"
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        // The test builds' settings.
        for old in ["levels", "levels.v2", "appVolumes", "splitOutputs", "outputLevels", "appLevels", "routeMicrophone",
                    "outputLevels.v2", "appLevels.v2", "knob"] {
            defaults.removeObject(forKey: old)
        }
        if let data = defaults.data(forKey: Keys.outputLevels), let saved = try? JSONDecoder().decode(LinkedLevels.self, from: data) {
            outputLevels = saved
        }
        if let data = defaults.data(forKey: Keys.appLevels), let saved = try? JSONDecoder().decode(LinkedLevels.self, from: data) {
            appLevels = saved
        }
        if let data = defaults.data(forKey: Keys.micLevels), let saved = try? JSONDecoder().decode(LinkedLevels.self, from: data) {
            micLevels = saved
        }
        knob = Knob(rawValue: defaults.string(forKey: Keys.knob) ?? "") ?? .speakers
        mixRequested = defaults.bool(forKey: Keys.mixing)
        pinnedApps = Set(defaults.stringArray(forKey: Keys.pinnedApps) ?? [])
        keepInMenuBar = defaults.bool(forKey: Keys.keepInMenuBar)
        duckMode = DuckMode(rawValue: defaults.string(forKey: Keys.duckMode) ?? "") ?? .off
        switchToHeadphones = defaults.object(forKey: Keys.switchToHeadphones) as? Bool ?? true
        allowBoost = defaults.bool(forKey: Keys.allowBoost)
        boosts = ((defaults.dictionary(forKey: Keys.boosts) as? [String: Double]) ?? [:]).mapValues { Float($0) }
        // Devices with a remembered level (including ones from before this was saved).
        knownOutputs = Set(defaults.stringArray(forKey: Keys.knownOutputs) ?? []).union(outputLevels.offsets.keys)
        knownMics = Set(defaults.stringArray(forKey: Keys.knownMics) ?? []).union(micLevels.offsets.keys)
        speakerNames = (defaults.dictionary(forKey: Keys.speakerNames) as? [String: [String]]) ?? [:]
        micNames = (defaults.dictionary(forKey: Keys.micNames) as? [String: [String]]) ?? [:]
        mutedApps = Set(defaults.stringArray(forKey: Keys.mutedApps) ?? [])
        isSplit = defaults.bool(forKey: Keys.split)
        routes = (defaults.dictionary(forKey: Keys.routes) as? [String: [String]]) ?? [:]
        softwareLevels = ((defaults.dictionary(forKey: Keys.softwareLevels) as? [String: Double]) ?? [:]).mapValues { Float($0) }
        isRouting = defaults.bool(forKey: Keys.routing)
        routeMics = defaults.stringArray(forKey: Keys.routeMics) ?? []
        selectedMicUID = defaults.string(forKey: Keys.selectedMic)
        routeAppLevels = ((defaults.dictionary(forKey: Keys.routeAppLevels) as? [String: Double]) ?? [:]).mapValues { Float($0) }
        airPlayIDs = defaults.stringArray(forKey: Keys.airPlay) ?? []
        airPlayOnly = defaults.bool(forKey: Keys.airPlayOnly)
        defaults.removeObject(forKey: Keys.airPlaySyncs) // set by the old slider, which shifted the stream mid-flight
        airPlaySyncs = [:]
        routedApps = Set(defaults.stringArray(forKey: Keys.routedApps) ?? [])
    }

    /// Saved a moment after the last change (the volume keys and sliders change things often).
    private func save() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let defaults = UserDefaults.standard
            defaults.set(try? JSONEncoder().encode(self.outputLevels), forKey: Keys.outputLevels)
            defaults.set(try? JSONEncoder().encode(self.appLevels), forKey: Keys.appLevels)
            defaults.set(try? JSONEncoder().encode(self.micLevels), forKey: Keys.micLevels)
            defaults.set(self.knob.rawValue, forKey: Keys.knob)
            defaults.set(self.mixRequested, forKey: Keys.mixing)
            defaults.set(Array(self.pinnedApps), forKey: Keys.pinnedApps)
            defaults.set(self.keepInMenuBar, forKey: Keys.keepInMenuBar)
            defaults.set(self.duckMode.rawValue, forKey: Keys.duckMode)
            defaults.set(self.switchToHeadphones, forKey: Keys.switchToHeadphones)
            defaults.set(self.allowBoost, forKey: Keys.allowBoost)
            defaults.set(self.boosts.mapValues { Double($0) }, forKey: Keys.boosts)
            defaults.set(Array(self.knownOutputs), forKey: Keys.knownOutputs)
            defaults.set(Array(self.knownMics), forKey: Keys.knownMics)
            defaults.set(self.speakerNames, forKey: Keys.speakerNames)
            defaults.set(self.micNames, forKey: Keys.micNames)
            defaults.set(Array(self.mutedApps), forKey: Keys.mutedApps)
            defaults.set(self.members.count > 1 ? self.memberUIDs : [], forKey: Keys.outputs)
            defaults.set(self.isSplit, forKey: Keys.split)
            defaults.set(self.routes, forKey: Keys.routes)
            defaults.set(self.softwareLevels.mapValues { Double($0) }, forKey: Keys.softwareLevels)
            defaults.set(self.isRouting, forKey: Keys.routing)
            defaults.set(self.routeMics, forKey: Keys.routeMics)
            defaults.set(self.selectedMicUID, forKey: Keys.selectedMic)
            defaults.set(self.routeAppLevels.mapValues { Double($0) }, forKey: Keys.routeAppLevels)
            defaults.set(self.airPlayIDs, forKey: Keys.airPlay)
            defaults.set(self.airPlayOnly, forKey: Keys.airPlayOnly)
            defaults.set(self.airPlaySyncs, forKey: Keys.airPlaySyncs)
            defaults.set(Array(self.routedApps), forKey: Keys.routedApps)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
