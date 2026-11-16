import AppKit
import ServiceManagement

/// What a companion is shown (all of it read from the engine and the rest of Soundcheck, so
/// watching this tells the hub when to send it again), and what it asks for.
extension CompanionHub {
    func buildState() -> RemoteState {
        let engine = AudioEngine.shared
        let tabs = BrowserTabs.shared
        var state = RemoteState()
        state.macName = Self.macName
        state.macShortName = Self.macShortName
        state.macSymbol = AudioDevice.macSymbol
        state.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        state.effectChoices = Effects.shared.choices.map {
            RemoteEffectChoice(id: $0.id, name: $0.name, maker: $0.maker.isEmpty ? nil : $0.maker, symbol: $0.symbol)
        }
        state.knob = engine.knob.rawValue
        state.knobValue = engine.knobValue
        state.speakersMuted = engine.speakersSilent
        state.mixing = engine.isMixing
        state.airPlayOnly = engine.airPlayOnly
        state.needsPermission = engine.needsPermission

        // Speakers: the Mac's, then companions, then AirPlay.
        let members = Set(engine.memberUIDs)
        for device in engine.outputDevices where !device.isAirPlay {
            state.speakers.append(RemoteSpeaker(
                id: device.uid, name: device.name, symbol: device.symbol(.output), kind: .device,
                isOn: members.contains(device.uid), volume: engine.outputVolume(device), muted: engine.isSpeakerMuted(device.uid),
                shape: engine.shape(.speaker(device.uid)), limit: engine.volumeLimit(device.uid), isHeadphones: device.isHeadphones,
                canHearYourself: engine.canHearYourself(on: device), hearsSoundcheckMic: engine.hearsSoundcheckMic(on: device),
                hearsMics: engine.hearYourselfMicChoices.filter { engine.hearsMic($0.uid, on: device) }.map(\.uid),
                status: nil, sync: nil, companion: nil))
        }
        let speakers = AirPlayBrowser.shared.speakers
        for speaker in speakers.filter(\.isCompanion) + speakers.filter({ !$0.isCompanion }) {
            let key = AudioEngine.airPlayKey(speaker.id)
            let device = Self.device(fromSpeakerID: speaker.id)
            var status: String?
            switch engine.airPlayStates[speaker.id] {
            case .connecting: status = device.flatMap { notes[$0] } ?? "Connecting…"
            case .failed(let reason): status = device != nil ? reason : "Couldn't connect"
            default: status = nil
            }
            state.speakers.append(RemoteSpeaker(
                id: key, name: speaker.name, symbol: speaker.symbol, kind: speaker.isCompanion ? .companion : .airPlay,
                isOn: engine.airPlayIDs.contains(speaker.id), volume: engine.airPlayVolume(speaker), muted: engine.isSpeakerMuted(key),
                shape: engine.shape(.speaker(key)), limit: nil, isHeadphones: false, canHearYourself: false,
                hearsSoundcheckMic: false, hearsMics: [], status: status,
                sync: engine.airPlaySync(speaker.id), companion: device))
        }

        // Apps as the panel lists them (System is already there, at the end).
        state.split = engine.isSplit
        for app in engine.visibleApps {
            let browserTabs = tabs.connected.contains(app.id) ? (tabs.tabs[app.id] ?? []).map { tab in
                RemoteTab(id: tab.id, title: tab.title, host: tab.host, playing: tab.playing, call: tab.call, muted: tab.muted,
                          level: tabs.level(tab, in: app.id))
            } : nil
            state.apps.append(RemoteApp(
                id: app.id, name: app.isSystem ? "System" : app.name, isSystem: app.isSystem, isPlaying: sounding.contains(app.id),
                isListening: app.isListening, volume: engine.appSliderValue(app.id), muted: engine.isAppMuted(app.id),
                pinned: engine.pinnedApps.contains(app.id), shape: engine.shape(.app(app.id)),
                routes: engine.routes[app.id] ?? [], isSplitOff: engine.routes[app.id] == nil, tabs: browserTabs,
                effects: app.isSystem ? nil : remoteEffects(.app(app.id))))
        }

        // Microphones.
        state.micInstalled = engine.isMicrophoneInstalled
        state.installingMic = engine.isInstallingMicrophone
        let shown = engine.shownInput?.uid
        for device in engine.inputDevices {
            state.mics.append(RemoteMic(
                id: device.uid, name: device.name, symbol: device.symbol(.input), volume: engine.micVolume(device),
                muted: engine.isMicMuted(device.uid), isSelected: device.uid == shown, isRouted: engine.routeMics.contains(device.uid),
                shape: engine.shape(.mic(device.uid)), companion: CompanionMics.device(fromUID: device.uid),
                effects: remoteEffects(.mic(device.uid)), isContinuity: device.isContinuity))
        }
        state.routing = engine.isRouting
        state.routeApps = engine.routableApps.map { app in
            RemoteRouteApp(id: app.id, name: app.isSystem ? "System" : app.name, isRouted: engine.routedApps.contains(app.id),
                           level: engine.routeAppLevel(app.id), muted: engine.isRouteAppMuted(app.id))
        }
        state.micsMuted = engine.micsMuted
        state.hearYourselfLevel = engine.hearYourselfLevel
        state.hearYourselfMuted = engine.hearYourselfMuted

        state.options = RemoteOptions(
            duckMode: engine.duckMode.rawValue, switchToHeadphones: engine.switchToHeadphones, allowBoost: engine.allowBoost,
            keepInMenuBar: engine.keepInMenuBar, nightMode: engine.nightMode, voiceCleanup: engine.voiceCleanup,
            duckUnderVoice: engine.duckUnderVoice, launchAtLogin: SMAppService.mainApp.status == .enabled)

        // Saved setups, and what they can apply themselves on.
        state.setups = SetupStore.shared.setups.map { setup in
            RemoteSetup(id: setup.id, name: setup.name,
                        triggerKind: setup.trigger.map { RemoteSetup.TriggerKind(rawValue: $0.kind.rawValue) ?? .deviceConnects },
                        triggerID: setup.trigger?.id, summary: Self.summary(of: setup))
        }
        var seen: Set<String> = []
        for device in engine.knownSpeakers + engine.knownMicrophones where !device.id.hasPrefix("airplay:") && seen.insert(device.id).inserted {
            state.triggerChoices.append(RemoteTriggerChoice(kind: .deviceConnects, id: device.id, name: device.name))
        }
        var appIDs: Set<String> = []
        for app in engine.apps where !app.isSystem && appIDs.insert(app.id).inserted {
            state.triggerChoices.append(RemoteTriggerChoice(kind: .appOpens, id: app.id, name: app.name))
        }
        for setup in SetupStore.shared.setups {
            if let trigger = setup.trigger, trigger.kind == .appOpens, !trigger.id.isEmpty, appIDs.insert(trigger.id).inserted {
                state.triggerChoices.append(RemoteTriggerChoice(kind: .appOpens, id: trigger.id, name: Self.appName(trigger.id)))
            }
        }

        state.canUndoReset = engine.undoResetUntil.map { $0 > Date() } ?? false
        state.playing = engine.playingApps.filter { sounding.contains($0.id) }.map { $0.isSystem ? "System" : $0.name }
        state.onCall = engine.onCall
        state.browsers = tabs.connected.sorted().map { RemoteBrowser(id: $0, name: Self.appName($0), connected: true) }
        state.companions = devices.map { device in
            RemoteCompanion(id: device.id, name: device.name, kind: device.kind, connected: connected.contains(device.id),
                            isSpeaker: engine.airPlayIDs.contains(Self.speakerID(device.id)),
                            isMicrophone: engine.feedingMics.contains { $0.uid == CompanionMics.uid(device.id) })
        }
        return state
    }

    static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func summary(of setup: SavedSetup) -> String {
        let engine = AudioEngine.shared
        let speakers = setup.speakers.compactMap { level in engine.knownSpeakers.first { $0.id == level.id }?.name }
        var parts: [String] = []
        if !speakers.isEmpty { parts.append(speakers.joined(separator: " + ")) }
        if !setup.apps.isEmpty { parts.append(setup.apps.count == 1 ? "1 app" : "\(setup.apps.count) apps") }
        if setup.route.isOn { parts.append("Route") }
        return parts.joined(separator: ", ")
    }

    // MARK: Commands

    func perform(_ command: RemoteCommand, from device: String) {
        let engine = AudioEngine.shared
        func output(_ key: String) -> AudioDevice? { engine.outputDevices.first { $0.uid == key } }
        func airPlay(_ key: String) -> AirPlaySpeaker? {
            guard key.hasPrefix("airplay:") else { return nil }
            let id = String(key.dropFirst("airplay:".count))
            return AirPlayBrowser.shared.speakers.first { $0.id == id }
        }
        func input(_ uid: String) -> AudioDevice? { engine.inputDevices.first { $0.uid == uid } }
        func speakers(_ keys: [String]) -> [AudioDevice] { keys.compactMap(output) }

        switch command {
        case .setKnob(let knob):
            if let knob = AudioEngine.Knob(rawValue: knob) { engine.setKnob(knob) }
        case .setKnobValue(let value):
            engine.setKnobValue(min(max(value, 0), 1))
        case .step(let knob, let delta):
            engine.step(delta, knob: AudioEngine.Knob(rawValue: knob) ?? .speakers)
        case .toggleSpeakersMuted:
            engine.toggleSpeakersMuted()
        case .selectOnlySpeaker(let key):
            if let device = output(key) {
                for speaker in engine.activeAirPlay { engine.toggleAirPlay(speaker) }
                engine.selectOnly(device)
            } else if let speaker = airPlay(key) {
                for other in engine.activeAirPlay where other.id != speaker.id { engine.toggleAirPlay(other) }
                if !engine.airPlayIDs.contains(speaker.id) { engine.toggleAirPlay(speaker) }
                engine.setAirPlayOnly(true)
            }
        case .toggleSpeaker(let key):
            if let device = output(key) { engine.toggleOutput(device) } else if let speaker = airPlay(key) { engine.toggleAirPlay(speaker) }
        case .setSpeakerVolume(let key, let volume):
            if let device = output(key) { engine.setOutputVolume(volume, for: device) } else if let speaker = airPlay(key) { engine.setAirPlayVolume(volume, for: speaker) }
        case .setSpeakerMuted(let key, let muted):
            engine.setSpeakerMuted(muted, for: key)
        case .setMixing(let on):
            engine.setMixing(on)
        case .setAirPlayOnly(let on):
            engine.setAirPlayOnly(on)
        case .setAirPlaySync(let key, let seconds):
            engine.setAirPlaySync(seconds, for: String(key.dropFirst("airplay:".count)))
        case .setVolumeLimit(let id, let limit):
            engine.setVolumeLimit(limit, for: id)

        case .setAppVolume(let id, let volume):
            engine.setAppLevel(min(max(volume, 0), engine.allowBoost ? 2 : 1), for: id)
        case .setAppMuted(let id, let muted):
            engine.setAppMuted(muted, for: id)
        case .togglePin(let id):
            engine.togglePin(id)
        case .setSplit(let on):
            engine.setSplit(on)
        case .toggleAppSpeaker(let app, let key):
            if !engine.isSplit {
                // The companion has no Split switch: picking a speaker turns it on, with that
                // speaker as the app's own (not added to one it had from before).
                engine.setSplit(true)
                if engine.routes[app] != nil { engine.followMainOutputs(app) }
            }
            if let device = output(key) { engine.toggleRoute(device, for: app) } else if let speaker = airPlay(key) { engine.toggleRoute(speaker, for: app) }
        case .followMainSpeakers(let app):
            engine.followMainOutputs(app)
        case .setTabVolume(let browser, let id, let volume):
            if let tab = BrowserTabs.shared.tabs[browser]?.first(where: { $0.id == id }) { BrowserTabs.shared.setLevel(volume, for: tab, in: browser) }
        case .setTabMuted(let browser, let id, let muted):
            if let tab = BrowserTabs.shared.tabs[browser]?.first(where: { $0.id == id }) { BrowserTabs.shared.setMuted(muted, for: tab, in: browser) }

        case .selectMic(let uid):
            if let device = input(uid) { engine.selectInput(device) }
        case .setMicVolume(let uid, let volume):
            if let device = input(uid) { engine.setMicVolume(volume, for: device) }
        case .setMicMuted(let uid, let muted):
            engine.setMicMuted(muted, for: uid)
        case .setMicsMuted(let muted):
            engine.setMicsMuted(muted)
        case .setRouting(let on):
            engine.setRouting(on)
        case .toggleRouteMic(let uid):
            if let device = input(uid) { engine.toggleRouteMic(device) }
        case .toggleRoutedApp(let id):
            engine.toggleRoutedApp(id)
        case .setRouteAppLevel(let id, let level):
            engine.setRouteAppLevel(level, for: id)
        case .setRouteAppMuted(let id, let muted):
            engine.setRouteAppMuted(muted, for: id)
        case .installMic:
            engine.installMicrophone() // macOS asks for the password on the Mac

        case .toggleHearSoundcheckMic(let keys):
            engine.toggleHearSoundcheckMic(on: speakers(keys))
        case .toggleHearMic(let mic, let keys):
            engine.toggleHearMic(mic, on: speakers(keys))
        case .setHearYourselfLevel(let level):
            engine.setHearYourselfLevel(level)
        case .setHearYourselfMuted(let muted):
            engine.setHearYourselfMuted(muted)

        case .setShape(let target, let shape):
            switch target {
            case .speaker(let key): engine.setShape(shape, for: .speaker(key))
            case .app(let id): engine.setShape(shape, for: .app(id))
            case .mic(let uid): engine.setShape(shape, for: .mic(uid))
            }

        case .addEffect(let target, let choice):
            guard let choice = Effects.shared.choices.first(where: { $0.id == choice }) else { return }
            effectRack(target)?.add(choice)
        case .removeEffect(let target, let effect):
            if let id = UUID(uuidString: effect) { effectRack(target)?.remove(id) }
        case .moveEffect(let target, let effect, let offset):
            if let id = UUID(uuidString: effect) { effectRack(target)?.move(id, by: offset) }
        case .setEffectOn(let target, let effect, let on):
            if let id = UUID(uuidString: effect) { effectRack(target)?.setOn(id, on) }
        case .setEffectValue(let target, let effect, let control, let value):
            if let id = UUID(uuidString: effect) { effectRack(target)?.setValue(value, address: control, for: id) }
        case .setEffectPreset(let target, let effect, let index):
            if let id = UUID(uuidString: effect) { effectRack(target)?.choosePreset(index, for: id) }

        case .setDuckMode(let mode):
            if let mode = AudioEngine.DuckMode(rawValue: mode) { engine.setDuckMode(mode) }
        case .setSwitchToHeadphones(let on):
            engine.setSwitchToHeadphones(on)
        case .setAllowBoost(let on):
            engine.setAllowBoost(on)
        case .setKeepInMenuBar(let on):
            engine.setKeepInMenuBar(on)
        case .setNightMode(let on):
            engine.setNightMode(on)
        case .setVoiceCleanup(let on):
            engine.setVoiceCleanup(on)
        case .setDuckUnderVoice(let on):
            engine.setDuckUnderVoice(on)
        case .setLaunchAtLogin(let on):
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("Couldn't change the login item: \(error.localizedDescription, privacy: .public)")
            }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            publishSoon()

        case .applySetup(let id):
            if let setup = SetupStore.shared.setups.first(where: { $0.id == id }) { engine.apply(setup) }
        case .saveSetup(let name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            SetupStore.shared.add(engine.captureSetup(named: trimmed.isEmpty ? "Setup" : trimmed))
        case .renameSetup(let id, let name):
            if var setup = SetupStore.shared.setups.first(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty {
                setup.name = name.trimmingCharacters(in: .whitespaces)
                SetupStore.shared.update(setup)
            }
        case .deleteSetup(let id):
            SetupStore.shared.remove(id)
        case .setSetupTrigger(let id, let kind, let triggerID):
            if var setup = SetupStore.shared.setups.first(where: { $0.id == id }) {
                setup.trigger = kind.flatMap { kind in
                    SavedSetup.Trigger.Kind(rawValue: kind.rawValue).map { SavedSetup.Trigger(kind: $0, id: triggerID ?? "") }
                }
                SetupStore.shared.update(setup)
            }
        case .updateSetup(let id):
            if let setup = SetupStore.shared.setups.first(where: { $0.id == id }) {
                var current = engine.captureSetup(named: setup.name)
                current.id = setup.id
                current.trigger = setup.trigger
                SetupStore.shared.update(current)
            }

        case .reset:
            engine.reset()
        case .undoReset:
            engine.undoReset()
        case .checkForUpdates:
            NSApp.activate()
            Updater.shared.checkForUpdates()
        case .openOnMac(let window):
            NSApp.activate()
            switch window {
            case "setups": SetupsWindowController.shared.show()
            case "browsers": BrowserSetupWindowController.shared.show()
            case "companions": CompanionsWindowController.shared.show()
            default:
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            }

        case .playPause:
            MediaKeys.press(.playPause)
        case .nextTrack:
            MediaKeys.press(.next)
        case .previousTrack:
            MediaKeys.press(.previous)

        case .useAsSpeaker(let on):
            let id = Self.speakerID(device)
            if on != engine.airPlayIDs.contains(id), let speaker = AirPlayBrowser.shared.speakers.first(where: { $0.id == id }) {
                engine.toggleAirPlay(speaker)
            }
        case .useAsMicrophone(let on):
            engine.useCompanionMicrophone(device, on)
        case .forget(let id):
            forget(id)
        }
    }

    // MARK: Effects

    /// An app's or microphone's effects, as a companion shows them.
    private func remoteEffects(_ target: AudioEngine.ShapeTarget) -> [RemoteEffect] {
        _ = Effects.shared.revision
        guard let rack = Effects.shared.existingRack(target) else { return [] }
        _ = rack.revision
        return rack.slots.map { slot in
            let builtIn = BuiltInEffect.named(slot.builtIn)
            return RemoteEffect(
                id: slot.id.uuidString, name: slot.name, maker: slot.maker.isEmpty ? nil : slot.maker,
                symbol: builtIn?.symbol ?? "puzzlepiece.extension", isOn: slot.isOn, help: builtIn?.help,
                presets: rack.presets(slot.id), preset: slot.preset,
                controls: rack.controls(slot.id).map { control in
                    RemoteEffectControl(id: control.address, name: control.name, style: control.style,
                                        min: control.range.lowerBound, max: control.range.upperBound, value: control.value,
                                        step: control.step, choices: control.choices, unit: control.unit)
                },
                problem: rack.problems[slot.id] ?? (rack.loading.contains(slot.id) ? "Opening…" : nil),
                isPlugIn: builtIn == nil)
        }
    }

    private func effectRack(_ target: RemoteShapeTarget) -> EffectRack? {
        switch target {
        case .app(let id): Effects.shared.rack(.app(id))
        case .mic(let uid): Effects.shared.rack(.mic(uid))
        case .speaker: nil
        }
    }
}

extension AirPlaySpeaker {
    /// An iPhone or iPad with Soundcheck Companion, playing as a speaker.
    var isCompanion: Bool { model == CompanionHub.speakerModel }
}
