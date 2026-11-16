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
        case .apps: appLevels.top(knobApps)
        case .mics: micLevels.top(activeMics.map(\.uid))
        }
    }
    /// The apps the main bar and the volume keys move on Apps: the ones the list (and the volume
    /// pill) shows, so the bar is the loudest of those, not just of the ones playing this moment.
    var knobApps: [String] { visibleApps.map(\.id) }
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
        let shown = apps.filter { !$0.isSystem && ($0.isPlaying || heldApps.contains($0.id) || pinnedApps.contains($0.id)) }
        let closed = pinnedApps.filter { id in id != AudioApp.systemID && !apps.contains { $0.id == id } }.map(AudioApp.pinned)
        let sorted = closed.isEmpty ? shown
            : (shown + closed).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // System (macOS's own sounds) is always there, at the end.
        return sorted + [systemApp]
    }

    /// macOS's own sounds as an app: the running one, or a stand-in until one plays.
    var systemApp: AudioApp { apps.first(where: \.isSystem) ?? AudioApp.pinned(AudioApp.systemID) }

    /// The apps the closed Apps row names: System only while it's making a sound (or when it's all
    /// there is).
    var summaryApps: [AudioApp] {
        let apps = visibleApps
        let others = apps.filter { !$0.isSystem || $0.isPlaying }
        return others.isEmpty ? apps : others
    }
    /// Apps you can route into the microphone: the ones in the Apps list, plus the routed ones.
    var routableApps: [AudioApp] {
        apps.filter { !$0.isSystem && ($0.isPlaying || heldApps.contains($0.id) || pinnedApps.contains($0.id) || routedApps.contains($0.id)) }
            + [systemApp]
    }
    var isRouteOnly: Bool { isRouting && routeMics.isEmpty }


    /// The Mac's outputs an app plays through: its own while split, otherwise the main ones. An app
    /// sent only to AirPlay speakers has none.
    func outputs(for id: String) -> [AudioDevice] {
        guard isSplit, let route = routes[id] else { return members }
        let present = route.compactMap { uid in outputDevices.first { $0.uid == uid } }
        return present.isEmpty && airPlayRoute(for: id).isEmpty ? members : present
    }

    /// The AirPlay speakers (IDs) an app is sent to while split: the ones in its route that are on.
    func airPlayRoute(for id: String) -> [String] {
        guard isSplit, let route = routes[id], !activeAirPlay.isEmpty else { return [] }
        return route.compactMap { key in
            guard key.hasPrefix("airplay:") else { return nil }
            let speaker = String(key.dropFirst("airplay:".count))
            return activeAirPlay.contains { $0.id == speaker } ? speaker : nil
        }
    }

    func isRouted(_ id: String) -> Bool { !airPlayRoute(for: id).isEmpty || outputs(for: id).map(\.uid) != memberUIDs }

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

    @ObservationIgnored private var started = false

    /// Once, at launch (a Shortcuts action that opens Soundcheck may get here first).
    func start() {
        guard !started else { return }
        started = true
        // Soundcheck's own audio IO mustn't keep the Mac awake.
        HAL.write(.system, kAudioHardwarePropertySleepingIsAllowed, value: UInt32(1))
        loadSettings()
        // Before any taps: apps with effects get taps of their own.
        Effects.shared.load()
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
        // A setup that applies when an app opens.
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let id else { return }
                AudioEngine.shared.applyAutomaticSetup { $0.kind == .appOpens && $0.id == id }
            }
        }
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

    @ObservationIgnored private var airPlaySessions: [String: any SpeakerSession] = [:]
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
            // A companion (an iPhone or iPad) plays the same mix on the same timeline.
            let session: any SpeakerSession = speaker.isCompanion
                ? CompanionSpeakerSession(speaker: speaker, timeline: airPlayTimeline)
                : AirPlaySession(speaker: speaker, timeline: airPlayTimeline)
            session.allowsPTP = !airPlayWithoutPTP.contains(speaker.id)
            airPlaySessions[speaker.id] = session
            airPlayStates[speaker.id] = .connecting
            let id = speaker.id
            session.onError = { error in
                DispatchQueue.main.async { MainActor.assumeIsolated { AudioEngine.shared.airPlayFailed(id, error) } }
            }
            // Turned up or down on the speaker itself, with Siri, or from an iPhone or the Home app.
            session.onSpeakerVolume = { volume in
                DispatchQueue.main.async { MainActor.assumeIsolated { AudioEngine.shared.airPlaySpeakerChangedVolume(id, volume) } }
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

    /// The speaker's own volume changed (its buttons, Siri, an iPhone): its slider follows. When
    /// it's the only speaker playing, that's the main level, as with any other speaker.
    private func airPlaySpeakerChangedVolume(_ id: String, _ volume: Float) {
        let key = Self.airPlayKey(id)
        guard airPlayIDs.contains(id), !isMuted, !mutedSpeakers.contains(key) else { return }
        guard abs(outputLevels.value(key) - volume) > 0.005 else { return }
        if speakerKeys == [key] {
            outputLevels.offsets[key] = nil
            outputLevels.level = volume
        } else {
            outputLevels.set(volume, for: key)
        }
        volumesChanged()
    }

    /// The connected sessions get the mix (each shifted by its sync adjustment), and the regular
    /// speakers wait as long as AirPlay takes.
    private func feedAirPlay() {
        let playing = airPlaySessions.filter { airPlayStates[$0.key] == .playing }
        // Each speaker is heard after its own delay; the slowest sets the pace, the faster ones are
        // sent their sound that much later, and the regular speakers wait as long as the slowest.
        let slowest = playing.values.map(\.playbackDelay).max() ?? 0
        guard let mixer = mainMixer else { return }
        let targets = playing.map { id, session in
            (id: id, target: (session: session, earlier: Int64((airPlaySync(id) - (slowest - session.playbackDelay)) * 44_100),
                              shape: Optional(shapeControl(.speaker(Self.airPlayKey(id))))))
        }
        if mixer.airPlaySlots.isEmpty {
            mixer.feeds[0].setSessions(targets.map(\.target))
        } else {
            // Each speaker from its own mix (the main mix plus any apps sent to it).
            for (slot, id) in mixer.airPlaySlots.enumerated() where slot < mixer.feeds.count {
                mixer.feeds[slot].setSessions(targets.filter { $0.id == id }.map(\.target))
            }
        }
        mixer.setDelay(seconds: slowest)
    }

    /// A companion speaker's own delay changed (headphones on the iPhone, say): everything lines
    /// up with it again.
    func companionLatencyChanged() { feedAirPlay() }

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
    func toggleRoute(_ device: AudioDevice, for id: String) { toggleRoute(key: device.uid, for: id) }

    /// The same for an AirPlay speaker that's on.
    func toggleRoute(_ speaker: AirPlaySpeaker, for id: String) { toggleRoute(key: Self.airPlayKey(speaker.id), for: id) }

    private func toggleRoute(key: String, for id: String) {
        var route = routes[id] ?? []
        if let index = route.firstIndex(of: key) { route.remove(at: index) } else { route.append(key) }
        routes[id] = route.isEmpty ? nil : route
        outputsChanged()
    }

    /// Whether an app's own route includes this AirPlay speaker.
    func isRouted(_ id: String, to speaker: AirPlaySpeaker) -> Bool { airPlayRoute(for: id).contains(speaker.id) }

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
            appLevels.setTop(value, knobApps)
        case .mics:
            micLevels.setTop(value, activeMics.map(\.uid))
            applyMicVolumes()
        }
        volumesChanged()
    }

    /// A volume key: everything in the group the main slider controls moves by the same amount.
    func step(_ delta: Float) { step(delta, knob: knob) }

    /// A step for one group, whatever the main slider controls (a companion's volume buttons).
    func step(_ delta: Float, knob: Knob) {
        switch knob {
        case .speakers:
            if isMuted { isMuted = false }
            outputLevels.step(delta, speakerKeys)
        case .apps:
            appLevels.step(delta, knobApps)
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
        enforceVolumeLimits()
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
            let ownMute = mutedSpeakers.contains(device.uid)
            let silent = isMuted || ownMute
            if device.hasHardwareVolume {
                let canMute = DeviceVolume.canMute(device.id, scope: scope)
                // Muted on its own but without a mute of its own: turned to zero (its level is kept).
                let target = ownMute && !canMute ? 0 : volume
                if abs((written[device.uid] ?? -1) - target) > 0.001 {
                    written[device.uid] = target
                    lastWrite[device.uid] = Date()
                    VolumeWriter.shared.set(device.id, scope: scope, target)
                }
                if canMute, DeviceVolume.isMuted(device.id, scope: scope) != silent {
                    DeviceVolume.setMuted(device.id, scope: scope, silent)
                }
                softwareGain(device.uid).value = 1
            } else {
                softwareGain(device.uid).value = silent ? 0 : Self.taper(volume)
            }
        }
        for speaker in activeAirPlay {
            let key = Self.airPlayKey(speaker.id)
            airPlaySessions[speaker.id]?.setVolume(isMuted || mutedSpeakers.contains(key) ? 0 : outputLevels.value(key))
        }
        othersGain.value = Self.taper(appLevels.base) * duckFactor
        for (id, gains) in appGains { gains.gain.value = appGain(id) }
    }

    /// An app's gain: its level, its boost, and (unless it's the one on the call) the call ducking.
    private func appGain(_ id: String) -> Float {
        let boost = allowBoost ? (boosts[id] ?? 1) : 1
        let duck = callApps.contains(id) || duckExempt.contains(id) ? 1 : duckFactor
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
            || appShapes[id]?.hasEQ == true
            || Effects.shared.isActive(.app(id))
            || (duckFactor < 0.999 && (callApps.contains(id) || duckExempt.contains(id)))
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

    @ObservationIgnored private var wasRinging = false

    /// Apps using a microphone (on a call); they're never ducked. While a call rings, System (which
    /// plays the ringtone) isn't either.
    var callApps: Set<String> {
        var ids = Set(apps.filter(\.isListening).map(\.id))
        if monitor.isRinging { ids.insert(AudioApp.systemID) }
        // A browser with a tab on a call (from Soundcheck's extension); its other tabs are lowered
        // through the extension instead.
        ids.formUnion(BrowserTabs.shared.callBrowsers)
        return ids
    }
    /// On a call (an app using a microphone, or a browser tab on one), or one ringing.
    var onCall: Bool {
        monitor.isRinging || apps.contains(where: \.isListening) || !BrowserTabs.shared.callBrowsers.isEmpty
            || CompanionHub.shared.holdsCall
    }
    /// The Mac is ringing (a call to the iPhone, through Continuity).
    var isRinging: Bool { monitor.isRinging }

    /// A call answered on a paired iPhone started or ended (or it's said whether the call the
    /// Mac stopped ringing for was answered there).
    func phoneCallChanged() {
        syncTaps()
        updateDucking()
    }

    /// A browser tab joined or left a call.
    func browserCallsChanged() {
        syncTaps()
        updateDucking()
    }
    /// 1 normally; eases down to the ducked level while a call is on, and back after. The gain the
    /// other apps get is its cube.
    @ObservationIgnored private var duckLevel: Float = 1
    private var duckFactor: Float { duckLevel * duckLevel * duckLevel }
    /// Apps kept at full while the others are lowered (see updateDucking).
    @ObservationIgnored private var duckExempt: Set<String> = []
    @ObservationIgnored private var duckTimer: Timer?

    /// Going down, the fade moves evenly in decibels over a second (a straight line in gain, or
    /// even in the sliders' cube, drops most of the way in the first moments and sounds abrupt).
    /// Coming back up is on the sliders' cube over 1.2 s, which sounds even on the way up.
    private func updateDucking() {
        // Lowered is 20% of the gain (about -14 dB).
        let target: Float = duckMode == .off || !onCall ? 1 : (duckMode == .mute ? 0 : pow(0.2, 1.0 / 3))
        guard abs(target - duckLevel) > 0.001 || duckTimer != nil else { return }
        duckTimer?.invalidate()
        if target < 1 {
            // The apps on the call stay at full (with their own taps) until the others are all
            // the way back, even once they've hung up: dropping their tap mid-fade would let them
            // blip out at full volume before landing in the lowered mix.
            duckExempt.formUnion(callApps)
            syncTaps() // the taps carry the ducking, so they come first
        }
        let start = duckLevel, began = Date(), down = target < start, duration = down ? 1.0 : 1.2
        // The call's browser lowers its other tabs itself, over the same time.
        BrowserTabs.shared.duckOtherTabs(gain: target * target * target, seconds: duration)
        // In decibels for the way down; silence is taken as -60 dB until the very end.
        let startDecibels = max(60 * log10f(max(start, 1e-6)), -60)
        let targetDecibels = max(60 * log10f(max(target, 1e-6)), -60)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = Float(min(Date().timeIntervalSince(began) / duration, 1))
                let eased = t * t * (3 - 2 * t)
                if down {
                    let decibels = startDecibels + (targetDecibels - startDecibels) * eased
                    // The level whose cube is that gain (gain = level³, so dB = 60·log10(level)).
                    self.duckLevel = t >= 1 && target == 0 ? 0 : powf(10, decibels / 60)
                } else {
                    self.duckLevel = start + (target - start) * eased
                }
                self.applyVolumes()
                if t >= 1 {
                    timer.invalidate()
                    self.duckTimer = nil
                    if target >= 1 { self.duckExempt = [] }
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
    /// The microphone in use before the headphones' own took over (and Route's microphones), to
    /// give back when they disconnect; nil if the microphone wasn't switched.
    @ObservationIgnored private var micBeforeHeadphones: (headphones: String, selected: String?, routeMics: [String])?

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
        switchMicrophoneToHeadphones(device)
        onHeadphones?()
        return true
    }

    /// Headphones with a microphone of their own (AirPods, a headset): it becomes the microphone
    /// too. A Bluetooth headset's microphone can show up a moment after its speaker, so it's
    /// looked for again shortly. The Mac's own jack needs nothing: its microphone input switches
    /// to the headset's by itself.
    private func switchMicrophoneToHeadphones(_ headphones: AudioDevice, again: Bool = true) {
        guard headphones.transport != kAudioDeviceTransportTypeBuiltIn else { return }
        let inputs = AudioDevice.list(.input)
        guard let microphone = Self.headphoneMicrophone(for: headphones, in: inputs) else {
            if again {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.beforeHeadphones?.headphones == headphones.uid else { return }
                    self.switchMicrophoneToHeadphones(headphones, again: false)
                }
            }
            return
        }
        inputDevices = inputs
        // Route with several microphones is a setup made on purpose: it's left as it is.
        if isRouting && usesSoundcheckMic && routeMics.count > 1 { return }
        let current = usesSoundcheckMic ? (isRouting ? routeMics.first : shownInput?.uid) : defaultInput?.uid
        guard current != microphone.uid else { return }
        let before = (headphones.uid, usesSoundcheckMic ? selectedMicUID : defaultInput?.uid, routeMics)
        if isRouting && usesSoundcheckMic {
            routeMics = [microphone.uid]
            refreshInput()
            rebuildMixer()
            save()
        } else {
            selectInput(microphone)
        }
        micBeforeHeadphones = before
        log.notice("Headphones: microphone switched to \(microphone.name, privacy: .public)")
    }

    /// The headphones' own microphone: the same device, or one with the same Bluetooth address
    /// (its UID before the ":input" / ":output" suffix) or the same name.
    static func headphoneMicrophone(for headphones: AudioDevice, in inputs: [AudioDevice]) -> AudioDevice? {
        func base(_ uid: String) -> String {
            for suffix in [":output", ":input", "-output", "-input"] where uid.hasSuffix(suffix) { return String(uid.dropLast(suffix.count)) }
            return uid
        }
        let candidates = inputs.filter { $0.uid != MicDriver.microphoneUID }
        return candidates.first { $0.uid == headphones.uid }
            ?? candidates.first { base($0.uid) == base(headphones.uid) }
            ?? candidates.first { $0.name == headphones.name && $0.transport == headphones.transport }
    }

    /// The headphones went away: the microphone from before comes back, unless another was
    /// picked meanwhile.
    private func restoreMicrophoneAfterHeadphones(_ headphones: String) {
        guard let before = micBeforeHeadphones, before.headphones == headphones else { return }
        micBeforeHeadphones = nil
        let inputs = AudioDevice.list(.input)
        if usesSoundcheckMic {
            if isRouting {
                // Only if Route still has just the headphones' microphone (now gone).
                if routeMics.count <= 1 && routeMics.allSatisfy({ uid in !inputs.contains { $0.uid == uid } }) {
                    routeMics = before.routeMics
                }
            } else if let selected = before.selected, !inputs.contains(where: { $0.uid == selectedMicUID }) {
                selectedMicUID = selected
            }
            refreshInput()
            rebuildMixer()
            save()
        } else if let selected = before.selected, let device = inputs.first(where: { $0.uid == selected }), HAL.defaultInput != device.id {
            HAL.write(.system, kAudioHardwarePropertyDefaultInputDevice, value: device.id)
        }
    }

    /// The headphones went away: back to what was playing before, if nothing was changed since.
    private func restoreAfterHeadphones() -> Bool {
        guard let before = beforeHeadphones else { return false }
        beforeHeadphones = nil
        restoreMicrophoneAfterHeadphones(before.headphones)
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
    /// speaker at the loudest one's level, every app back to full (unmuted, no boost), every EQ,
    /// balance and mono flat, every effect off (still set up, to turn back on), Hear Yourself off,
    /// nothing muted on its own, and the main slider back on Speakers. Headphones' volume limits
    /// stay (they're for your ears). It can be undone for 5 seconds.
    func reset() {
        resetSnapshot = ResetSnapshot(
            isRouting: isRouting, routeMics: routeMics, routedApps: routedApps, isSplit: isSplit, routes: routes,
            appLevels: appLevels, boosts: boosts, mutedApps: mutedApps, mixRequested: mixRequested, knob: knob,
            outputLevels: outputLevels, mutedSpeakers: mutedSpeakers, mutedMics: mutedMics, mutedRouteApps: mutedRouteApps,
            speakerShapes: speakerShapes, appShapes: appShapes, micShapes: micShapes,
            hearYourselfPicks: hearYourselfPicks, hearYourselfMics: hearYourselfMics, hearYourselfMuted: hearYourselfMuted,
            effectsOn: Effects.shared.turnAllOff())
        undoResetUntil = Date().addingTimeInterval(5)
        undoExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            self?.resetSnapshot = nil
            self?.undoResetUntil = nil
        }
        undoExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: expiry)

        isRouting = false
        routeMics = []
        routedApps = []
        isSplit = false
        routes = [:]
        appLevels = LinkedLevels()
        boosts = [:]
        mutedApps = []
        mixRequested = false
        mutedSpeakers = []
        mutedMics = []
        mutedRouteApps = []
        speakerShapes = [:]
        appShapes = [:]
        micShapes = [:]
        hearYourselfPicks = []
        hearYourselfMics = [:]
        hearYourselfMuted = false
        knob = .speakers
        settleAfterReset()
        evenOutSpeakers()
    }

    /// Back to how things were just before Reset (within 5 seconds of it).
    func undoReset() {
        guard let before = resetSnapshot else { return }
        resetSnapshot = nil
        undoResetUntil = nil
        undoExpiry?.cancel()
        isRouting = before.isRouting
        routeMics = before.routeMics
        routedApps = before.routedApps
        isSplit = before.isSplit
        routes = before.routes
        appLevels = before.appLevels
        boosts = before.boosts
        mutedApps = before.mutedApps
        mixRequested = before.mixRequested
        knob = before.knob
        outputLevels = before.outputLevels
        mutedSpeakers = before.mutedSpeakers
        mutedMics = before.mutedMics
        mutedRouteApps = before.mutedRouteApps
        speakerShapes = before.speakerShapes
        appShapes = before.appShapes
        micShapes = before.micShapes
        hearYourselfPicks = before.hearYourselfPicks
        hearYourselfMics = before.hearYourselfMics
        hearYourselfMuted = before.hearYourselfMuted
        Effects.shared.turnOn(before.effectsOn)
        settleAfterReset()
    }

    /// Puts the levels, mutes and shapes in place after Reset or its undo.
    private func settleAfterReset() {
        for (id, gains) in appGains { gains.muted.value = mutedApps.contains(id) ? 1 : 0 }
        for (id, gain) in routeGains { gain.value = mutedRouteApps.contains(id) ? 0 : Self.taper(routeAppLevel(id)) }
        for (target, control) in shapeControls { control.set(shape(target)) }
        monitorGain.value = hearYourselfMuted ? 0 : Self.taper(hearYourselfLevel)
        for key in Array(written.keys) { written[key] = nil }
        for key in Array(writtenMic.keys) { writtenMic[key] = nil }
        outputsChanged()
        refreshInput()
        applyMicVolumes()
        rebuildMixer()
        NotificationCenter.default.post(name: Self.didChangeVolume, object: nil)
        save()
    }

    /// Everything Reset changes, kept for 5 seconds so it can be undone.
    private struct ResetSnapshot {
        var isRouting: Bool
        var routeMics: [String]
        var routedApps: Set<String>
        var isSplit: Bool
        var routes: [String: [String]]
        var appLevels: LinkedLevels
        var boosts: [String: Float]
        var mutedApps: Set<String>
        var mixRequested: Bool
        var knob: Knob
        var outputLevels: LinkedLevels
        var mutedSpeakers: Set<String>
        var mutedMics: Set<String>
        var mutedRouteApps: Set<String>
        var speakerShapes: [String: SoundShape]
        var appShapes: [String: SoundShape]
        var micShapes: [String: SoundShape]
        var hearYourselfPicks: Set<String>
        var hearYourselfMics: [String: [String]]
        var hearYourselfMuted: Bool
        /// The effects that were on (Reset turns them off, keeping how they're set).
        var effectsOn: [String: [UUID]]
    }
    @ObservationIgnored private var resetSnapshot: ResetSnapshot?
    @ObservationIgnored private var undoExpiry: DispatchWorkItem?
    /// Until when Reset can be undone (the Options row shows Undo till then).
    private(set) var undoResetUntil: Date?

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
    /// Where it's saved (the watchdog reads it to give that microphone back after a crash).
    nonisolated static let selectedMicrophoneKey = "selectedMicrophone"
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
        micBeforeHeadphones = nil // picked by hand: kept after the headphones go
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
        for device in feedingMics where !device.isCompanion { // a companion's level is a gain in the mix
            let ownMute = mutedMics.contains(device.uid)
            let canMute = DeviceVolume.canMute(device.id, scope: scope)
            guard settableMics.contains(device.uid) else {
                // No level to set from the Mac: only its own mute (Soundcheck Mic silences it too).
                if canMute, DeviceVolume.isMuted(device.id, scope: scope) != (micsMuted || ownMute) {
                    DeviceVolume.setMuted(device.id, scope: scope, micsMuted || ownMute)
                }
                continue
            }
            let volume = micLevels.value(device.uid)
            // Muted on its own but without a mute of its own: turned to zero (its level is kept).
            let target = ownMute && !canMute ? 0 : volume
            if abs((writtenMic[device.uid] ?? -1) - target) > 0.001 {
                writtenMic[device.uid] = target
                lastWrite[device.uid] = Date()
                VolumeWriter.shared.set(device.id, scope: scope, target)
            }
            let mute = micsMuted || ownMute || volume < 0.001
            if canMute, DeviceVolume.isMuted(device.id, scope: scope) != mute {
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
        for device in feedingMics + hearYourselfOnlyMics {
            let silent = micsMuted || mutedMics.contains(device.uid)
                || (settableMics.contains(device.uid) && micLevels.value(device.uid) < 0.001)
            // A companion's microphone has no level of its own to set: its slider is its gain.
            micGain(device.uid).value = silent ? 0 : (device.isCompanion ? Self.taper(micLevels.value(device.uid)) : 1)
        }
    }

    private func refreshInput() {
        // Companions' microphones go into Soundcheck Mic, so they're only listed with it.
        let devices = AudioDevice.list(.input) + (usesSoundcheckMic ? CompanionMics.devices : [])
        if devices.map(\.uid) != inputDevices.map(\.uid) || devices.map(\.id) != inputDevices.map(\.id) || settableMics.isEmpty {
            settableMics = Set(devices.filter { $0.isCompanion || DeviceVolume.canSet($0.id, scope: kAudioObjectPropertyScopeInput) }.map(\.uid))
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
        inputListeners = mics.filter { !$0.isCompanion }.compactMap { device in
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

    // MARK: Companions' microphones

    /// A companion paired, connected or left: its microphone comes and goes from the list.
    func companionsChanged() {
        let before = inputDevices.map(\.uid)
        refreshInput()
        if before != inputDevices.map(\.uid) { rebuildMixer() }
    }

    /// The microphone picked before a companion's, to go back to when it's turned off there.
    @ObservationIgnored private var micBeforeCompanion: String?

    /// "Use as Microphone" on a companion: its microphone becomes the one Soundcheck Mic carries
    /// (or joins Route's), and turning it off goes back to the one from before.
    func useCompanionMicrophone(_ device: String, _ on: Bool) {
        guard usesSoundcheckMic else { return }
        let uid = CompanionMics.uid(device)
        refreshInput()
        guard let microphone = inputDevices.first(where: { $0.uid == uid }) else { return }
        if isRouting {
            if routeMics.contains(uid) != on { toggleRouteMic(microphone) }
        } else if on {
            guard shownInput?.uid != uid else { return }
            let before = shownInput?.uid
            selectInput(microphone)
            micBeforeCompanion = before
        } else if shownInput?.uid == uid {
            let back = micBeforeCompanion.flatMap { saved in inputDevices.first { $0.uid == saved } }
                ?? inputDevices.first { !$0.isCompanion }
            if let back { selectInput(back) }
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
        micBeforeHeadphones = nil
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
    /// App meters only (no microphones), for companions: what's really making sound right now.
    @ObservationIgnored private var appMetering = false

    func setAppMetering(_ on: Bool) {
        guard on != appMetering else { return }
        appMetering = on
        updateAppMeters()
    }

    /// An app's meter, if it has one (whether or not it's muted here).
    func appMeterLevel(_ id: String) -> Float? { appMeters[id]?.level }

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
        // Companions whose microphone is picked keep it on (and send it).
        CompanionHub.shared.wantMicrophones(Set((feedingMics + hearYourselfOnlyMics).compactMap { CompanionMics.device(fromUID: $0.uid) }))
        mixerGeneration += 1
        let generation = mixerGeneration
        let old = mixer
        mixer = nil
        let monitorTargets = hearYourselfOutputs
        builtMonitorUIDs = monitorTargets.map(\.uid)
        let wanted = usesSoundcheckMic && !micsMuted && (microphoneInUse || metering || !monitorTargets.isEmpty)
            && HAL.device(forUID: MicDriver.feedUID).isValid
        let routed = isRouting ? apps.filter { routedApps.contains($0.id) } : []
        let appSources = routed.map { (id: $0.id, processes: $0.objects, gain: routeGain($0.id)) }
        // The microphones going into Soundcheck Mic, then any a speaker plays that don't.
        let microphones = feedingMics.map { (uid: $0.uid, gain: micGain($0.uid), shape: shapeControl(.mic($0.uid)),
                                             effects: Effects.shared.control(for: .mic($0.uid)), feeds: true) }
            + hearYourselfOnlyMics.map { (uid: $0.uid, gain: micGain($0.uid), shape: shapeControl(.mic($0.uid)),
                                          effects: Effects.shared.control(for: .mic($0.uid)), feeds: false) }
        let monitor = monitorTargets.isEmpty || microphones.isEmpty ? nil
            : MicMixer.Monitor(outputs: monitorTargets.map { (uid: $0.uid, gain: softwareGain($0.uid), microphones: hearYourselfMics[$0.uid]) },
                               level: monitorGain)
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
                made = try MicMixer(feedUID: MicDriver.feedUID, microphones: microphones, apps: appSources, monitor: monitor,
                                    voice: MicMixer.Voice(cleanup: self.cleanupFlag, duckApps: self.duckVoiceFlag))
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
        routeGain(id).value = mutedRouteApps.contains(id) ? 0 : Self.taper(level)
        save()
    }

    private func routeGain(_ id: String) -> SharedValue {
        if let gain = routeGains[id] { return gain }
        let gain = SharedValue(mutedRouteApps.contains(id) ? 0 : Self.taper(routeAppLevel(id)))
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
        let wanted = (metering || appMetering) && AudioCapturePermission.status == .allowed
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
        let seenBefore = before.union(inputDevices.map(\.uid))
        outputDevices = AudioDevice.list(.output)
        defer { rememberNames() }
        // A setup that applies when one of these connects (after everything else here settles).
        defer {
            let connected = Set((outputDevices + AudioDevice.list(.input)).map(\.uid)).subtracting(seenBefore)
            if !connected.isEmpty { applyAutomaticSetup { $0.kind == .deviceConnects && connected.contains($0.id) } }
        }
        // Headphones you hear yourself on came or went.
        defer { if hearYourselfOutputs.map(\.uid) != builtMonitorUIDs { rebuildMixer() } }
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
        // The speakers were changed while the headphones were on, but their microphone was still
        // in use when they went: the one from before comes back.
        if let gone = micBeforeHeadphones?.headphones, !outputDevices.contains(where: { $0.uid == gone }) {
            restoreMicrophoneAfterHeadphones(gone)
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
        if hearYourselfOutputs.map(\.uid) != builtMonitorUIDs { rebuildMixer() }
        for device in active { written[device.uid] = nil } // write the remembered level
        if let first = members.first, first.hasHardwareVolume, !mutedSpeakers.contains(first.uid) {
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
        // A speaker muted on its own: unmuted somewhere else (Control Center, its own buttons)
        // means it's back on; otherwise it's just Soundcheck's own mute.
        if mutedSpeakers.contains(device.uid) {
            if !muted && !isMuted {
                mutedSpeakers.remove(device.uid)
                volumesChanged()
            }
            return
        }
        guard muted != isMuted else { return }
        isMuted = muted
        volumesChanged()
    }

    private func processesChanged() {
        let ringingBefore = wasRinging
        wasRinging = monitor.isRinging
        if ringingBefore != monitor.isRinging { CompanionHub.shared.ringingChanged(monitor.isRinging) }
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
        if metering || appMetering { updateAppMeters() }
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
            || members.contains { !shape(.speaker($0.uid)).isFlat }
            || nightMode
            // Quiet Apps in Calls: carry the sound from when it starts playing, not from when a
            // call starts. Taking it over has a tiny gap (the tapped path is a few ms longer), and
            // there it'd land mid-song; this way a call only turns things down, which is smooth.
            || (duckMode != .off && monitor.anyProcessPlaying)
            || appLevels.base < 0.999
            || duckFactor < 0.999
    }

    // Making or removing a tap can make macOS restart the speaker's audio for a moment, which other
    // apps hear as a pause. So a tap that's stopped being needed (an app slider dragged back to
    // full, the apps' bar back to the top) stays a while first: at full it's inaudible, and a fast
    // drag back and forth doesn't make and remove one on every pass.
    private static let tapLinger: TimeInterval = 10
    @ObservationIgnored private var ownTapWanted: [String: Date] = [:]
    @ObservationIgnored private var globalTapWanted = Date.distantPast
    @ObservationIgnored private var tapCleanup: DispatchWorkItem?

    private func keepsOwnTap(_ id: String) -> Bool {
        if needsOwnTap(id) {
            ownTapWanted[id] = Date()
            return true
        }
        guard let wanted = ownTapWanted[id] else { return false }
        if Date().timeIntervalSince(wanted) < Self.tapLinger {
            scheduleTapCleanup()
            return true
        }
        ownTapWanted[id] = nil
        return false
    }

    private var keepsGlobalTap: Bool {
        if needsGlobalTap {
            globalTapWanted = Date()
            return true
        }
        if Date().timeIntervalSince(globalTapWanted) < Self.tapLinger {
            scheduleTapCleanup()
            return true
        }
        return false
    }

    /// Takes away the lingering taps once they've been unneeded for long enough.
    private func scheduleTapCleanup() {
        guard tapCleanup == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tapCleanup = nil
            self.syncTaps()
        }
        tapCleanup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapLinger + 0.5, execute: work)
    }

    private func syncTaps() {
        guard !members.isEmpty else { stopTaps(); return }
        let memberGains = members.map(tapOutput)

        // A tap without the System Audio Recording permission silences what it taps, so none
        // until macOS allows them (it asks the first time one is needed).
        let wantsTaps = keepsGlobalTap || apps.contains { keepsOwnTap($0.id) } || (isRouting && !routedApps.isEmpty)
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
        var wanted: [String: (app: AudioApp, outputs: [TapOutput])] = [:]
        for app in apps where keepsOwnTap(app.id) && (!mixing || isRouted(app.id)) {
            // An app sent only to AirPlay speakers plays through the main mixer instead.
            let own = outputs(for: app.id)
            guard !own.isEmpty else { continue }
            wanted[app.id] = (app, own.map(tapOutput))
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
            if let tap = makeTap(.processes(want.app.objects), outputs: want.outputs, gain: gains.gain, muted: gains.muted,
                                 shape: shapeControl(.app(id)), effects: Effects.shared.control(for: .app(id))) {
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
        if keepsGlobalTap && own.isValid {
            let excluded = ([own] + appTaps.values.flatMap { tap -> [AudioObjectID] in
                if case .processes(let objects) = tap.source { return objects }
                return []
            }).sorted()
            if let tap = globalTap, tap.outputUIDs == memberUIDs, tap.isAlive, tap.updateExcluded(excluded) {
                return
            }
            globalTap?.invalidate()
            globalTap = makeTap(.everythingExcept(excluded), outputs: memberGains, gain: othersGain, muted: unmuted, shape: nil)
        } else if let tap = globalTap {
            tap.invalidate()
            globalTap = nil
        }
    }

    /// The one mixer that carries the sound while AirPlay speakers play: each app with its own
    /// level, mute, boost or ducking as a source, then everything else at the apps' level.
    private func syncMainMixer(own: AudioObjectID) {
        let outputs = members.map(tapOutput)
        var sources: [MainMixer.Source] = []
        var claimed: [AudioObjectID] = [own]
        // AirPlay speakers get a mix of their own only while an app is sent to one of them.
        let slots = apps.contains { !airPlayRoute(for: $0.id).isEmpty } ? activeAirPlay.map(\.id) : []
        for app in apps where keepsOwnTap(app.id) {
            let airPlay = airPlayRoute(for: app.id)
            guard !airPlay.isEmpty || !isRouted(app.id) else { continue } // on the Mac's own outputs only: its own tap
            let gains = gains(for: app.id)
            gains.gain.value = appGain(app.id)
            sources.append(.init(tap: .processes(app.objects), gain: gains.gain, muted: gains.muted, shape: shapeControl(.app(app.id)),
                                 effects: Effects.shared.control(for: .app(app.id)),
                                 airPlay: airPlay.compactMap { slots.firstIndex(of: $0) }))
            claimed += app.objects
        }
        for tap in appTaps.values { if case .processes(let objects) = tap.source { claimed += objects } }
        sources.append(.init(tap: .everythingExcept(claimed.sorted()), gain: othersGain, muted: unmuted))

        let silent = !playsLocally
        if let mixer = mainMixer, mixer.outputUIDs == outputs.map(\.uid), mixer.sourceSignature == sources.map(\.tap),
           mixer.sourceRouting == sources.map(\.airPlay), mixer.airPlaySlots == slots, mainMixerSilent == silent, mixer.isAlive {
            return
        }
        mainMixer?.invalidate()
        mainMixer = nil
        do {
            mainMixer = try MainMixer(outputs: outputs, silent: silent, sources: sources, airPlaySlots: slots, night: nightFlag,
                                      timeline: airPlayTimeline)
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

    /// An output for a tap or the main mix: its software gain and its shape.
    private func tapOutput(_ device: AudioDevice) -> TapOutput {
        (uid: device.uid, gain: softwareGain(device.uid), shape: shapeControl(.speaker(device.uid)))
    }

    private func makeTap(_ source: TapPlayer.Source, outputs: [TapOutput], gain: SharedValue, muted: SharedValue,
                         shape: ShapeControl?, effects: EffectControl? = nil) -> TapPlayer? {
        do {
            let tap = try TapPlayer(source: source, outputs: outputs, gain: gain, muted: muted, shape: shape, effects: effects,
                                    night: nightFlag)
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

    // MARK: EQ, balance and mono

    /// What a shape belongs to: a speaker (device UID, or an AirPlay speaker's key), an app
    /// (bundle ID) or a microphone (device UID).
    enum ShapeTarget: Hashable {
        case speaker(String), app(String), mic(String)
    }

    /// Each speaker's, app's and microphone's shape (flat ones aren't kept).
    private(set) var speakerShapes: [String: SoundShape] = [:]
    private(set) var appShapes: [String: SoundShape] = [:]
    private(set) var micShapes: [String: SoundShape] = [:]
    /// The audio threads' copies, one per speaker, app and microphone, kept for as long as
    /// Soundcheck runs (taps and mixes made later pick up the same one).
    @ObservationIgnored private var shapeControls: [ShapeTarget: ShapeControl] = [:]

    func shape(_ target: ShapeTarget) -> SoundShape {
        switch target {
        case .speaker(let key): speakerShapes[key] ?? SoundShape()
        case .app(let id): appShapes[id] ?? SoundShape()
        case .mic(let uid): micShapes[uid] ?? SoundShape()
        }
    }

    /// Changes take effect straight away; a speaker or app going from flat to shaped (or back)
    /// gets (or loses) the tap that carries it.
    func setShape(_ shape: SoundShape, for target: ShapeTarget) {
        let before = self.shape(target)
        let kept: SoundShape? = shape.isFlat ? nil : shape
        switch target {
        case .speaker(let key): speakerShapes[key] = kept
        case .app(let id): appShapes[id] = kept
        case .mic(let uid): micShapes[uid] = kept
        }
        shapeControls[target]?.set(shape)
        switch target {
        case .speaker where before.isFlat != shape.isFlat: syncTaps()
        case .app where before.hasEQ != shape.hasEQ: syncTaps()
        default: break
        }
        save()
    }

    /// An effect was added, removed, or turned on or off: an app with an effect that's on needs a
    /// tap of its own (and one without may not any more).
    func effectsChanged() {
        syncTaps()
    }

    private func shapeControl(_ target: ShapeTarget) -> ShapeControl {
        if let control = shapeControls[target] { return control }
        let control = ShapeControl(shape(target))
        shapeControls[target] = control
        return control
    }

    // MARK: Night Mode, Voice Cleanup, and apps under your voice

    /// Night Mode: everything that plays is evened out (loud parts down, quiet ones up).
    private(set) var nightMode = false
    /// Voice Cleanup: the microphones in Soundcheck Mic lose rumble and room noise between words,
    /// and their level is evened out.
    private(set) var voiceCleanup = false
    /// Apps routed into Soundcheck Mic dip while you talk.
    private(set) var duckUnderVoice = false
    @ObservationIgnored private let nightFlag = SharedValue(0)
    @ObservationIgnored private let cleanupFlag = SharedValue(0)
    @ObservationIgnored private let duckVoiceFlag = SharedValue(0)

    func setNightMode(_ on: Bool) {
        nightMode = on
        nightFlag.value = on ? 1 : 0
        if on {
            syncTaps()
        } else {
            // The compressor fades out first; then the tap only Night Mode needed can go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.syncTaps() }
        }
        save()
    }

    func setVoiceCleanup(_ on: Bool) {
        voiceCleanup = on
        cleanupFlag.value = on ? 1 : 0
        save()
    }

    func setDuckUnderVoice(_ on: Bool) {
        duckUnderVoice = on
        duckVoiceFlag.value = on ? 1 : 0
        save()
    }

    // MARK: Volume limit (headphones)

    /// The loudest each pair of headphones goes (by device UID); none means no limit.
    private(set) var volumeLimits: [String: Float] = [:]

    func volumeLimit(_ uid: String) -> Float? { volumeLimits[uid] }

    func setVolumeLimit(_ limit: Float?, for uid: String) {
        volumeLimits[uid] = limit.map { min(max($0, 0.05), 1) }
        volumesChanged()
    }

    /// Headphones over their limit come down to it (the main slider and the volume keys stop
    /// there too, since they follow the loudest speaker).
    private func enforceVolumeLimits() {
        for device in activeOutputs {
            guard let limit = volumeLimits[device.uid], outputLevels.value(device.uid) > limit + 0.0005 else { continue }
            if speakerKeys == [device.uid] {
                outputLevels.offsets[device.uid] = nil
                outputLevels.level = limit
            } else {
                outputLevels.set(limit, for: device.uid)
            }
        }
    }

    // MARK: Hear Yourself

    /// The speakers you hear your microphones on (device UIDs), for streaming or podcasting. Kept
    /// while they're unplugged, so headphones pick it up again when they're back in use.
    private(set) var hearYourselfPicks: Set<String> = []
    /// How loud you hear yourself (0...1).
    private(set) var hearYourselfLevel: Float = 0.8
    @ObservationIgnored private let monitorGain = SharedValue(0)
    /// Where the last Soundcheck Mic mix plays you back.
    @ObservationIgnored private var builtMonitorUIDs: [String] = []

    /// Whether a speaker can play you back: one of the Mac's (AirPlay is seconds behind), with
    /// Soundcheck Mic carrying the microphones.
    func canHearYourself(on device: AudioDevice) -> Bool { usesSoundcheckMic && !device.isAirPlay }
    func isHearingYourself(on device: AudioDevice) -> Bool { hearYourselfPicks.contains(device.uid) }

    /// The speakers you hear yourself on right now: the ones you turned it on for that are in use
    /// and playing.
    var hearYourselfOutputs: [AudioDevice] {
        guard usesSoundcheckMic, playsLocally, !hearYourselfPicks.isEmpty else { return [] }
        return activeOutputs.filter { hearYourselfPicks.contains($0.uid) && !$0.isAirPlay }
    }
    /// Hearing yourself on speakers rather than headphones can echo.
    var hearYourselfOnSpeakers: Bool { hearYourselfOutputs.contains { !$0.isHeadphones } }

    /// The microphones a speaker plays when you've picked them (right-clicking its headphones
    /// button); a speaker that isn't listed plays what goes into Soundcheck Mic.
    private(set) var hearYourselfMics: [String: [String]] = [:]

    /// The microphones you can pick to hear: every one connected except Soundcheck Mic itself.
    var hearYourselfMicChoices: [AudioDevice] { inputDevices.filter { $0.uid != MicDriver.microphoneUID } }

    /// Picked microphones that don't go into Soundcheck Mic: opened only to be heard.
    var hearYourselfOnlyMics: [AudioDevice] {
        let feeding = Set(feedingMics.map(\.uid))
        var seen: Set<String> = []
        return hearYourselfOutputs.flatMap { hearYourselfMics[$0.uid] ?? [] }.compactMap { uid in
            guard !feeding.contains(uid), seen.insert(uid).inserted else { return nil }
            return hearYourselfMicChoices.first { $0.uid == uid }
        }
    }

    /// Whether a speaker plays what goes into Soundcheck Mic (as opposed to microphones picked for it).
    func hearsSoundcheckMic(on device: AudioDevice) -> Bool {
        hearYourselfPicks.contains(device.uid) && hearYourselfMics[device.uid] == nil
    }

    /// Whether a speaker plays a microphone you picked for it.
    func hearsMic(_ uid: String, on device: AudioDevice) -> Bool {
        hearYourselfPicks.contains(device.uid) && hearYourselfMics[device.uid]?.contains(uid) == true
    }

    /// The headphones button (left click): Soundcheck Mic on these speakers, or off.
    func setHearYourself(_ on: Bool, on devices: [AudioDevice]) {
        for device in devices {
            if on { hearYourselfPicks.insert(device.uid) } else { hearYourselfPicks.remove(device.uid) }
            hearYourselfMics[device.uid] = nil
        }
        rebuildMixer()
        save()
    }

    /// The list's Soundcheck Mic row: these speakers play what goes into Soundcheck Mic (off if
    /// they already all do).
    func toggleHearSoundcheckMic(on devices: [AudioDevice]) {
        setHearYourself(!devices.allSatisfy(hearsSoundcheckMic), on: devices)
    }

    /// A microphone's row: added to (or taken from) what these speakers play. Picking one moves a
    /// speaker off Soundcheck Mic to just the ones picked; with none left, it's off.
    func toggleHearMic(_ uid: String, on devices: [AudioDevice]) {
        let on = !devices.allSatisfy { hearsMic(uid, on: $0) }
        for device in devices {
            var picked = hearYourselfPicks.contains(device.uid) ? (hearYourselfMics[device.uid] ?? []) : []
            if on, !picked.contains(uid) { picked.append(uid) }
            if !on { picked.removeAll { $0 == uid } }
            if picked.isEmpty {
                hearYourselfPicks.remove(device.uid)
                hearYourselfMics[device.uid] = nil
            } else {
                hearYourselfPicks.insert(device.uid)
                hearYourselfMics[device.uid] = picked
            }
        }
        rebuildMixer()
        save()
    }

    func setHearYourselfLevel(_ level: Float) {
        hearYourselfLevel = min(max(level, 0), 1)
        monitorGain.value = hearYourselfMuted ? 0 : Self.taper(hearYourselfLevel)
        save()
    }

    // MARK: Muting one speaker, mic or routed app

    // Each bar's own mute (the icon at its end). It's separate from the level: muted stays muted
    // while the main slider or the volume keys move things, until it's clicked again.

    /// Speakers muted on their own (device UIDs and AirPlay speakers' keys).
    private(set) var mutedSpeakers: Set<String> = []
    /// Microphones muted on their own (device UIDs).
    private(set) var mutedMics: Set<String> = []
    /// Routed apps muted inside Soundcheck Mic (they still play on the speakers).
    private(set) var mutedRouteApps: Set<String> = []
    /// Hear Yourself muted (where it plays is kept).
    private(set) var hearYourselfMuted = false

    func isSpeakerMuted(_ key: String) -> Bool { mutedSpeakers.contains(key) }
    func isMicMuted(_ uid: String) -> Bool { mutedMics.contains(uid) }
    func isRouteAppMuted(_ id: String) -> Bool { mutedRouteApps.contains(id) }

    /// Every speaker in use is silent: muted together, or each on its own.
    var speakersSilent: Bool {
        isMuted || (!speakerKeys.isEmpty && speakerKeys.allSatisfy(mutedSpeakers.contains))
    }

    func setSpeakerMuted(_ muted: Bool, for key: String) {
        if muted { mutedSpeakers.insert(key) } else { mutedSpeakers.remove(key) }
        written[key] = nil
        volumesChanged()
    }

    /// The main bar's mute: when every speaker in use was muted on its own, it unmutes them;
    /// otherwise it mutes or unmutes them all together.
    func toggleSpeakersMuted() {
        if !isMuted && speakersSilent {
            for key in speakerKeys {
                mutedSpeakers.remove(key)
                written[key] = nil
            }
            volumesChanged()
        } else {
            setMuted(!isMuted)
        }
    }

    func setMicMuted(_ muted: Bool, for uid: String) {
        if muted { mutedMics.insert(uid) } else { mutedMics.remove(uid) }
        writtenMic[uid] = nil
        applyMicVolumes()
        NotificationCenter.default.post(name: Self.didChangeVolume, object: nil)
        save()
    }

    func setRouteAppMuted(_ muted: Bool, for id: String) {
        if muted { mutedRouteApps.insert(id) } else { mutedRouteApps.remove(id) }
        routeGain(id).value = muted ? 0 : Self.taper(routeAppLevel(id))
        save()
    }

    func setHearYourselfMuted(_ muted: Bool) {
        hearYourselfMuted = muted
        monitorGain.value = muted ? 0 : Self.taper(hearYourselfLevel)
        save()
    }

    // MARK: Automatic setups

    @ObservationIgnored private var appLaunchObserver: NSObjectProtocol?

    /// Puts in place the setup whose trigger this is (the last one made, if several share it),
    /// a moment later so macOS has finished switching things itself, and says so in the pill.
    private func applyAutomaticSetup(_ matches: (SavedSetup.Trigger) -> Bool) {
        guard let setup = SetupStore.shared.setups.last(where: { setup in
            setup.trigger.map { !$0.id.isEmpty && matches($0) } == true
        }) else { return }
        let id = setup.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                let engine = AudioEngine.shared
                guard let current = SetupStore.shared.setups.first(where: { $0.id == id }) else { return }
                engine.apply(current)
                engine.onNotice?(HUDNotice(symbol: "square.stack.3d.up", title: current.name, detail: "Applied"))
            }
        }
    }

    // MARK: Shortcuts

    /// Plays through exactly these speakers (device UIDs and AirPlay speakers' keys); the first
    /// regular one becomes macOS's output. AirPlay speakers on their own play without the others.
    func playThrough(_ ids: [String]) {
        let local = ids.compactMap { id in outputDevices.first { $0.uid == id } }
        let airPlay = ids.filter { $0.hasPrefix("airplay:") }.map { String($0.dropFirst("airplay:".count)) }
        guard !local.isEmpty || !airPlay.isEmpty else { return }
        beforeHeadphones = nil
        if let first = local.first {
            members = local
            if HAL.defaultOutput != first.id {
                HAL.write(.system, kAudioHardwarePropertyDefaultOutputDevice, value: first.id)
            }
        }
        if !airPlay.isEmpty { AirPlayBrowser.shared.start() }
        for id in airPlay where !knownOutputs.contains(Self.airPlayKey(id)) {
            knownOutputs.insert(Self.airPlayKey(id))
            outputLevels.set(min(speakersVolume, 0.5), for: Self.airPlayKey(id))
        }
        airPlayIDs = airPlay
        airPlayOnly = local.isEmpty
        outputsChanged()
    }

    /// Apps you might want to set: playing, pinned, with a level or EQ of their own, routed, or
    /// in a saved setup (bundle IDs).
    var knownAppIDs: [String] {
        var ids = apps.map(\.id) + [AudioApp.systemID] + Array(pinnedApps) + Array(appLevels.offsets.keys) + Array(appShapes.keys)
            + Array(mutedApps) + Array(routedApps)
        ids += SetupStore.shared.setups.flatMap { $0.apps.map(\.id) }
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
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
        static let selectedMic = AudioEngine.selectedMicrophoneKey
        static let routeAppLevels = "routeAppLevels"
        static let airPlay = "airPlaySpeakers"
        static let airPlayOnly = "airPlayOnly"
        static let airPlaySyncs = "airPlaySync"
        static let routedApps = "routedApps"
        static let speakerShapes = "speakerShapes"
        static let appShapes = "appShapes"
        static let micShapes = "micShapes"
        static let volumeLimits = "volumeLimits"
        static let hearYourselfLevel = "hearYourselfLevel"
        static let hearYourselfPicks = "hearYourselfSpeakers"
        static let mutedSpeakers = "mutedSpeakers"
        static let mutedMics = "mutedMics"
        static let mutedRouteApps = "mutedRouteApps"
        static let hearYourselfMuted = "hearYourselfMuted"
        static let hearYourselfMics = "hearYourselfMicrophones"
        static let nightMode = "nightMode"
        static let voiceCleanup = "voiceCleanup"
        static let duckUnderVoice = "duckUnderVoice"
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
        func shapes(_ key: String) -> [String: SoundShape] {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: SoundShape].self, from: $0) } ?? [:]
        }
        speakerShapes = shapes(Keys.speakerShapes)
        appShapes = shapes(Keys.appShapes)
        micShapes = shapes(Keys.micShapes)
        volumeLimits = ((defaults.dictionary(forKey: Keys.volumeLimits) as? [String: Double]) ?? [:]).mapValues { Float($0) }
        defaults.removeObject(forKey: "hearYourself") // a test build's on/off for all speakers
        hearYourselfLevel = (defaults.object(forKey: Keys.hearYourselfLevel) as? NSNumber)?.floatValue ?? 0.8
        hearYourselfPicks = Set(defaults.stringArray(forKey: Keys.hearYourselfPicks) ?? [])
        mutedSpeakers = Set(defaults.stringArray(forKey: Keys.mutedSpeakers) ?? [])
        mutedMics = Set(defaults.stringArray(forKey: Keys.mutedMics) ?? [])
        mutedRouteApps = Set(defaults.stringArray(forKey: Keys.mutedRouteApps) ?? [])
        hearYourselfMuted = defaults.bool(forKey: Keys.hearYourselfMuted)
        hearYourselfMics = (defaults.dictionary(forKey: Keys.hearYourselfMics) as? [String: [String]]) ?? [:]
        nightMode = defaults.bool(forKey: Keys.nightMode)
        voiceCleanup = defaults.bool(forKey: Keys.voiceCleanup)
        duckUnderVoice = defaults.bool(forKey: Keys.duckUnderVoice)
        nightFlag.value = nightMode ? 1 : 0
        cleanupFlag.value = voiceCleanup ? 1 : 0
        duckVoiceFlag.value = duckUnderVoice ? 1 : 0
        monitorGain.value = hearYourselfMuted ? 0 : Self.taper(hearYourselfLevel)
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
            defaults.set(try? JSONEncoder().encode(self.speakerShapes), forKey: Keys.speakerShapes)
            defaults.set(try? JSONEncoder().encode(self.appShapes), forKey: Keys.appShapes)
            defaults.set(try? JSONEncoder().encode(self.micShapes), forKey: Keys.micShapes)
            defaults.set(self.volumeLimits.mapValues { Double($0) }, forKey: Keys.volumeLimits)
            defaults.set(self.hearYourselfLevel, forKey: Keys.hearYourselfLevel)
            defaults.set(Array(self.hearYourselfPicks), forKey: Keys.hearYourselfPicks)
            defaults.set(Array(self.mutedSpeakers), forKey: Keys.mutedSpeakers)
            defaults.set(Array(self.mutedMics), forKey: Keys.mutedMics)
            defaults.set(Array(self.mutedRouteApps), forKey: Keys.mutedRouteApps)
            defaults.set(self.hearYourselfMuted, forKey: Keys.hearYourselfMuted)
            defaults.set(self.hearYourselfMics, forKey: Keys.hearYourselfMics)
            defaults.set(self.nightMode, forKey: Keys.nightMode)
            defaults.set(self.voiceCleanup, forKey: Keys.voiceCleanup)
            defaults.set(self.duckUnderVoice, forKey: Keys.duckUnderVoice)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
