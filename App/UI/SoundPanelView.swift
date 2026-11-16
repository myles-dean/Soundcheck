import ServiceManagement
import SwiftUI

/// The panel's contents: the main volume (for the outputs or the apps), the output dropdown, a
/// slider for every app making sound (with its own outputs while split), and the microphone
/// (with apps routed into it).
struct SoundPanelView: View {
    private var engine = AudioEngine.shared
    private var keys = VolumeKeys.shared
    private var state = PanelState.shared

    private let expand = Animation.easeInOut(duration: PanelController.animationDuration)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sound")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // What the main slider and the volume keys move.
                PillPicker(options: [(AudioEngine.Knob.speakers, "Speakers"), (.apps, "Apps"), (.mics, "Mics")],
                           selection: engine.knob) { engine.setKnob($0) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // With Mix off, the main bar stands for the speakers in use: its EQ and Hear Yourself
            // buttons change all of them (with one speaker, just that one).
            if let speakers = mainSpeakers {
                ShapedBar(targets: speakers.keys.map { .speaker($0) }, name: speakers.name, devices: speakers.devices, place: .main) {
                    mainSlider
                }
                .padding(.horizontal, 16)
            } else {
                mainSlider
                    .padding(.horizontal, 16)
            }

            PanelDivider()
            outputSection

            if !engine.visibleApps.isEmpty {
                PanelDivider()
                appsSection
            }

            PanelDivider()
            microphoneSection

            if engine.needsPermission || !keys.isActive {
                PanelDivider()
                VStack(spacing: 2) {
                    if engine.needsPermission {
                        OptionRow(symbol: "waveform.badge.exclamationmark", title: "Allow app volumes…", isOn: false) {
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                        }
                    }
                    if !keys.isActive {
                        OptionRow(symbol: "speaker.wave.2", title: "Use the volume keys…", isOn: false) {
                            keys.requestPermission()
                        }
                    }
                }
            }

            PanelDivider()
            optionsSection
                .padding(.bottom, 8)
        }
    }

    private var mainSlider: some View {
        LevelSlider(value: engine.knob == .speakers && engine.speakersSilent ? 0 : engine.knobValue,
                    low: engine.knob == .mics ? "mic.fill" : (engine.knob == .speakers && engine.speakersSilent ? "speaker.slash.fill" : "speaker.fill"),
                    high: engine.knob == .mics ? "mic.and.signal.meter.fill" : "speaker.wave.3.fill",
                    lowAction: engine.knob == .speakers ? { engine.toggleSpeakersMuted() } : nil,
                    meter: engine.knob == .mics ? { engine.micsLiveLevel } : nil,
                    onChange: { engine.setKnobValue($0) })
    }

    /// The speakers the main bar stands for (the ones in use), while it moves them and Mix is off.
    private var mainSpeakers: (keys: [String], name: String, devices: [AudioDevice])? {
        let keys = engine.speakerKeys
        guard engine.knob == .speakers, !engine.isMixing, !keys.isEmpty else { return nil }
        let devices = keys.compactMap { key in engine.activeOutputs.first { $0.uid == key } }
        let airPlay = keys.compactMap { key in engine.activeAirPlay.first { AudioEngine.airPlayKey($0.id) == key } }
        let names = devices.map(\.name) + airPlay.map(\.name)
        return (keys, names.formatted(.list(type: .and)), devices)
    }

    // MARK: Options

    /// ••• Options: opens in place.
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HoverRow(action: { withAnimation(expand) { state.optionsOpen.toggle() } }) {
                IconCircle(symbol: "ellipsis", isOn: false)
                Text("Options").font(.system(size: 13))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(state.optionsOpen ? 180 : 0))
            }
            if state.optionsOpen {
                // Three sections, full width (no step in), opening one at a time; then Reset and Quit.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsGroup.allCases) { group in
                        let isOpen = state.optionsGroup == group
                        HoverRow(action: { withAnimation(expand) { state.optionsGroup = isOpen ? nil : group } }) {
                            IconCircle(symbol: group.symbol, isOn: false)
                            Text(group.title).font(.system(size: 13))
                            Spacer(minLength: 0)
                            Chevron(isOpen: isOpen)
                        }
                        if isOpen {
                            VStack(alignment: .leading, spacing: 2) {
                                SettingsRows(group: group)
                                if group == .soundcheck {
                                    // Saved setups: one click puts one in place.
                                    ForEach(SetupStore.shared.setups) { setup in
                                        HoverRow(action: { engine.apply(setup) }) {
                                            IconCircle(symbol: "square.stack.3d.up", isOn: false, size: 24)
                                            Text(setup.name).font(.system(size: 12)).lineLimit(1)
                                            Spacer(minLength: 0)
                                            Text("Apply").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        .padding(.leading, 34)
                                    }
                                    TextRow(title: "Check for Updates…") { Updater.shared.checkForUpdates() }
                                    TextRow(title: "Sound Settings…") { open("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
                                }
                            }
                            .padding(.leading, 12)
                            .transition(.opacity)
                        }
                    }
                    // For 5 seconds after Reset, the row undoes it (a ring counts down around it).
                    if let until = engine.undoResetUntil {
                        HoverRow(action: { withAnimation(expand) { engine.undoReset() } }) {
                            IconCircle(symbol: "arrow.uturn.backward", isOn: true)
                                .overlay { UndoCountdown(until: until, length: 5) }
                            Text("Undo Reset").font(.system(size: 13))
                        }
                        .transition(.opacity)
                    } else {
                        OptionRow(symbol: "arrow.counterclockwise", title: "Reset", isOn: false) {
                            withAnimation(expand) { engine.reset() }
                        }
                        .help("Turn off Route, Split, Mix and Hear Yourself, set every EQ flat and every app back to full, and the volume keys back to Speakers")
                    }
                    TextRow(title: "Quit Soundcheck") { NSApp.terminate(nil) }
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel("Speakers")
                Spacer()
                CapsuleToggle(title: "Mix", symbol: Glyph.mix, isOn: engine.isMixing) {
                    withAnimation(expand) {
                        let on = !engine.isMixing
                        engine.setMixing(on)
                        state.shaping = nil // the bars it was open under move
                        // Each speaker's own bar is under its row, so turning it on opens the list.
                        if on {
                            state.outputsOpen = true
                            if !engine.activeAirPlay.isEmpty { state.airPlayOpen = true }
                        }
                    }
                }
                .help("Give each speaker its own volume, EQ and Hear Yourself")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            let local = engine.playsLocally ? engine.members : []
            DropdownRow(symbols: local.map { $0.symbol(.output) } + engine.activeAirPlay.map(\.symbol),
                        title: (local.map(\.name) + engine.activeAirPlay.map(\.name)).joined(separator: " + "),
                        isOpen: state.outputsOpen) {
                withAnimation(expand) { state.outputsOpen.toggle() }
            }

            if state.outputsOpen {
                VStack(spacing: 2) {
                    ForEach(engine.outputDevices) { device in
                        let isOn = engine.playsLocally && engine.members.contains { $0.uid == device.uid }
                        // Click to play through it alone; its circle adds it to the others.
                        DeviceRow(device: device, direction: .output, isOn: isOn,
                                  toggle: (isOn, { withAnimation(expand) { engine.toggleOutput(device) } })) {
                            withAnimation(expand) {
                                engine.selectOnly(device)
                                state.outputsOpen = false
                            }
                        }
                        // Mix: its own bar right under it, lined up with its name (apps split to
                        // it count as in use too).
                        if engine.isMixing && engine.playsLocally && engine.activeOutputs.contains(where: { $0.uid == device.uid }) {
                            ShapedBar(target: .speaker(device.uid), name: device.name, device: device) {
                                let muted = engine.isSpeakerMuted(device.uid)
                                LevelSlider(value: engine.outputVolume(device), low: nil,
                                            mute: MuteControl(isMuted: muted) { engine.setSpeakerMuted(!muted, for: device.uid) },
                                            onChange: { engine.setOutputVolume($0, for: device) })
                            }
                            .padding(.horizontal, 16) // as wide as the speaker's row
                            .padding(.bottom, 4)
                            .transition(.opacity)
                        }
                    }
                    airPlayGroup
                }
                .padding(.leading, 12)
                .transition(.opacity)
            }

        }
    }

    /// AirPlay: one row whose icon is how many AirPlay speakers are on, opening to the speakers on
    /// the network (Soundcheck streams to them itself, in sync with the regular speakers).
    private var airPlayGroup: some View {
        let count = engine.activeAirPlay.filter { !$0.isCompanion }.count
        return VStack(spacing: 2) {
            // iPhones and iPads with Soundcheck Companion, above AirPlay (they play the same way).
            ForEach(AirPlayBrowser.shared.speakers.filter(\.isCompanion)) { speaker in
                airPlayRow(speaker)
            }
            HoverRow(action: {
                AirPlayBrowser.shared.start()
                withAnimation(expand) { state.airPlayOpen.toggle() }
            }) {
                Group {
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.accentColor))
                    } else {
                        IconCircle(symbol: "airplay.audio", isOn: false)
                    }
                }
                Text("AirPlay").font(.system(size: 13))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(state.airPlayOpen ? 180 : 0))
            }
            if state.airPlayOpen {
                VStack(spacing: 2) {
                    let speakers = AirPlayBrowser.shared.speakers.filter { !$0.isCompanion }
                    if let problem = AirPlayBrowser.shared.problem, speakers.isEmpty {
                        Button {
                            if AirPlayBrowser.shared.isDenied {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                            }
                        } label: {
                            Text(problem)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    } else if speakers.isEmpty {
                        Text("Looking for AirPlay speakers…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                    ForEach(speakers) { speaker in
                        airPlayRow(speaker)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// One AirPlay speaker (or companion) row, and its bar with Mix.
    @ViewBuilder
    private func airPlayRow(_ speaker: AirPlaySpeaker) -> some View {
        let isOn = engine.airPlayIDs.contains(speaker.id)
        // Laid out like the Mac's speakers above, the full width of the list.
        HoverRow(action: { withAnimation(expand) { engine.toggleAirPlay(speaker) } }) {
            IconCircle(symbol: speaker.symbol, isOn: isOn)
            VStack(alignment: .leading, spacing: 0) {
                Text(speaker.name).font(.system(size: 13)).lineLimit(1)
                let companion = CompanionHub.device(fromSpeakerID: speaker.id)
                switch engine.airPlayStates[speaker.id] {
                case .connecting:
                    Text(companion.flatMap { CompanionHub.shared.notes[$0] } ?? "Connecting…")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                case .failed(let reason):
                    Text(companion != nil ? reason : "Couldn't connect").font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
            Checkmark(isOn: isOn)
        }
        // Mix: its own bar under it, as for the Mac's speakers.
        if isOn && engine.isMixing && engine.activeAirPlay.contains(where: { $0.id == speaker.id }) {
            ShapedBar(target: .speaker(AudioEngine.airPlayKey(speaker.id)), name: speaker.name) {
                let key = AudioEngine.airPlayKey(speaker.id)
                let muted = engine.isSpeakerMuted(key)
                LevelSlider(value: engine.airPlayVolume(speaker), low: nil,
                            mute: MuteControl(isMuted: muted) { engine.setSpeakerMuted(!muted, for: key) },
                            onChange: { engine.setAirPlayVolume($0, for: speaker) })
            }
            .padding(.horizontal, 16) // as wide as the speaker's row
            .padding(.bottom, 4)
            .transition(.opacity)
        }
        if engine.airPlayCodeRequest == speaker.id {
            AirPlayCodeField(name: speaker.name)
                .padding(.leading, 54)
                .padding(.trailing, 16)
                .transition(.opacity)
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel("Apps")
                Spacer()
                CapsuleToggle(title: "Split", symbol: Glyph.split, rotation: Glyph.sideways, isOn: engine.isSplit) {
                    withAnimation(expand) {
                        let on = !engine.isSplit
                        engine.setSplit(on)
                        state.routingApp = nil
                        // Like Mix for the speakers: turning it on opens the list.
                        if on { state.appsOpen = true }
                    }
                }
                .help("Send apps to different outputs")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            AppStackRow(apps: engine.summaryApps, isOpen: state.appsOpen) {
                withAnimation(expand) { state.appsOpen.toggle() }
            }
            if state.appsOpen {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.visibleApps) { app in
                        AppRow(app: app, expand: expand)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .animation(expand, value: engine.visibleApps.map(\.id))
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel("Microphone")
                Spacer()
                CapsuleToggle(title: "Route", symbol: Glyph.route, rotation: Glyph.sideways, isOn: engine.isRouting) {
                    withAnimation(expand) {
                        engine.setRouting(!engine.isRouting)
                        state.inputsOpen = false
                    }
                }
                .help("Mix microphones and apps' sound into Soundcheck Mic")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            if engine.micsMuted {
                HoverRow(action: { engine.setMicsMuted(false) }) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.red))
                    Text("Mics Muted").font(.system(size: 13))
                    Spacer(minLength: 0)
                    Text("Unmute").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            // Not added yet (skipped in the walkthrough): offer it here.
            if !engine.isMicrophoneInstalled {
                addMicrophoneRow
            }
            if engine.isRouting {
                routeList
                    .transition(.opacity)
            } else {
                if let input = engine.shownInput {
                    DropdownRow(symbols: [input.symbol(.input)], title: input.name, isOpen: state.inputsOpen) {
                        withAnimation(expand) { state.inputsOpen.toggle() }
                    }
                }
                if state.inputsOpen {
                    VStack(spacing: 2) {
                        ForEach(engine.inputDevices) { device in
                            DeviceRow(device: device, direction: .input, isOn: device.uid == engine.shownInput?.uid) {
                                withAnimation(expand) {
                                    engine.selectInput(device)
                                    state.inputsOpen = false
                                }
                            }
                        }
                    }
                    .padding(.leading, 12)
                    .transition(.opacity)
                }
                if let input = engine.shownInput {
                    micBar(input, meter: { engine.liveLevel(input) })
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
            }
            if !engine.hearYourselfOutputs.isEmpty {
                hearYourselfLevel
            }
            if !engine.listeningApps.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    ForEach(engine.listeningApps) { app in
                        Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                    }
                    Text("In use by " + engine.listeningApps.map(\.name).formatted(.list(type: .and)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    /// How loud you hear yourself, while a speaker plays you back (its headphones button).
    private var hearYourselfLevel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Hear Yourself on " + engine.hearYourselfOutputs.map(\.name).formatted(.list(type: .and)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if engine.hearYourselfOnSpeakers {
                    Text("· can echo").foregroundStyle(.orange)
                        .help("Your mic can pick up the speakers. Headphones don't echo.")
                }
            }
            .font(.system(size: 11))
            LevelSlider(value: engine.hearYourselfLevel, low: nil,
                        meter: { engine.micsLiveLevel },
                        mute: MuteControl(isMuted: engine.hearYourselfMuted) { engine.setHearYourselfMuted(!engine.hearYourselfMuted) },
                        onChange: { engine.setHearYourselfLevel($0) })
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.opacity)
    }

    /// Adds Soundcheck Mic (the walkthrough offers it too).
    private var addMicrophoneRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            OptionRow(symbol: "mic.badge.plus",
                      title: engine.isInstallingMicrophone ? "Adding Soundcheck Mic…" : "Add Soundcheck Mic…",
                      isOn: false) {
                engine.installMicrophone()
            }
            .disabled(engine.isInstallingMicrophone)
            Text("Soundcheck Mic becomes your Mac's microphone, carrying the mic you pick here (and apps, with Route), so apps never need theirs changed. Adding it needs your password once.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }

    /// While routing: every microphone and every app making sound, each switched into Soundcheck
    /// Mic or not (with no microphone it's just the apps). The first time, adding Soundcheck Mic.
    private var routeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !engine.isMicrophoneInstalled {
                EmptyView() // the Add Soundcheck Mic row above covers it
            } else {
                Text("Microphones")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                ForEach(engine.inputDevices) { device in
                    let isOn = engine.routeMics.contains(device.uid)
                    HoverRow(action: { withAnimation(expand) { engine.toggleRouteMic(device) } }) {
                        IconCircle(symbol: device.symbol(.input), isOn: isOn, size: 24)
                        Text(device.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                        Checkmark(isOn: isOn)
                    }
                    if isOn {
                        micBar(device, meter: { engine.routeLiveLevel(device.uid) })
                            .padding(.leading, 50)
                            .padding(.trailing, 16)
                            .padding(.bottom, 2)
                    }
                }
                Text("Apps")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                if engine.routableApps.allSatisfy(\.isSystem) {
                    Text("Other apps appear here when they play sound.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
                ForEach(engine.routableApps) { app in
                    let isOn = engine.routedApps.contains(app.id)
                    HoverRow(action: { withAnimation(expand) { engine.toggleRoutedApp(app.id) } }) {
                        Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                        Text(app.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                        Checkmark(isOn: isOn)
                    }
                    // Its level inside Soundcheck Mic (it plays at its own level on the speakers).
                    if isOn {
                        let muted = engine.isRouteAppMuted(app.id)
                        LevelSlider(value: engine.routeAppLevel(app.id), low: nil,
                                    meter: { engine.routeLiveLevel(app.id) },
                                    mute: MuteControl(isMuted: muted) { engine.setRouteAppMuted(!muted, for: app.id) },
                                    onChange: { engine.setRouteAppLevel($0, for: app.id) })
                            .padding(.leading, 50)
                            .padding(.trailing, 16)
                            .padding(.bottom, 2)
                    }
                }
            }
        }
    }

    /// A microphone's level, with its EQ button when Soundcheck Mic carries it (the EQ lives in
    /// Soundcheck Mic's mix). A microphone whose level can't be set from the Mac still gets its EQ.
    @ViewBuilder
    private func micBar(_ device: AudioDevice, meter: @escaping () -> Float) -> some View {
        let volume = engine.micVolume(device)
        let muted = engine.isMicMuted(device.uid)
        let mute = MuteControl(kind: .mic, isMuted: muted) { engine.setMicMuted(!muted, for: device.uid) }
        if engine.usesSoundcheckMic {
            ShapedBar(target: .mic(device.uid), name: device.name) {
                if let volume {
                    LevelSlider(value: volume, low: nil, meter: meter, mute: mute,
                                onChange: { engine.setMicVolume($0, for: device) })
                } else {
                    // Its level is set on the device itself; it can still be muted here.
                    Text("Level set on the device").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    MuteButton(control: mute, value: 1)
                }
            }
        } else if let volume {
            LevelSlider(value: volume, low: nil, meter: meter, mute: mute,
                        onChange: { engine.setMicVolume($0, for: device) })
        }
    }

    // MARK: Actions

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

}

/// A ring around Undo Reset's icon that runs down over the seconds left.
private struct UndoCountdown: View {
    let until: Date
    let length: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let left = max(0, min(1, until.timeIntervalSince(context.date) / length))
            Circle()
                .trim(from: 0, to: left)
                .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(-3)
        }
        .allowsHitTesting(false)
    }
}

/// An app's icon (click it to mute), its name and its own level. While split, a button at the
/// end opens the list of outputs it plays through.
private struct AppRow: View {
    let app: AudioApp
    let expand: Animation
    private var engine = AudioEngine.shared
    private var state = PanelState.shared

    init(app: AudioApp, expand: Animation) {
        self.app = app
        self.expand = expand
    }

    var body: some View {
        let muted = engine.isAppMuted(app.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button { engine.setAppMuted(!muted, for: app.id) } label: {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .opacity(muted ? 0.4 : 1)
                        .overlay(alignment: .bottomTrailing) {
                            if muted {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(2)
                                    .background(Circle().fill(.regularMaterial))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                // A browser with Soundcheck's extension: its name opens its tabs.
                let tabs = BrowserTabs.shared.tabs[app.id] ?? []
                if tabs.isEmpty {
                    Text(app.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(width: engine.isSplit ? 62 : 74, alignment: .leading)
                } else {
                    let open = state.openBrowsers.contains(app.id)
                    Button {
                        withAnimation(expand) {
                            if open { state.openBrowsers.remove(app.id) } else { state.openBrowsers.insert(app.id) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(app.name).font(.system(size: 12)).lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(open ? 180 : 0))
                            Spacer(minLength: 0)
                        }
                        .frame(width: engine.isSplit ? 62 : 74, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(open ? "Hide \(app.name)'s tabs" : "Show \(app.name)'s tabs")
                }
                // EQ and FX together, as a speaker's EQ and Hear Yourself are.
                HStack(spacing: 6) {
                    ShapeButton(spot: EQSpot(target: .app(app.id)), name: app.name)
                    EffectsButton(target: .app(app.id), name: app.name)
                }
                // Muted, the bar dims but still sets the level it comes back at.
                AppSlider(id: app.id)
                    .opacity(muted ? 0.45 : 1)
                // Like the speakers' bars: shows how loud it is, and mutes it (as its icon does).
                MuteButton(control: MuteControl(isMuted: muted) { engine.setAppMuted(!muted, for: app.id) },
                           value: min(engine.appSliderValue(app.id), 1))
                if engine.isSplit {
                    splitButton
                }
            }
            .padding(.horizontal, 16)

            if state.shaping == EQSpot(target: .app(app.id)) {
                ShapePanel(target: .app(app.id))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.opacity)
            }

            if state.effecting == .app(app.id) {
                EffectsPanel(target: .app(app.id), name: app.name)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.opacity)
            }

            if state.openBrowsers.contains(app.id), let tabs = BrowserTabs.shared.tabs[app.id], !tabs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tabs) { tab in
                        TabRow(tab: tab, browser: app.id)
                    }
                }
                .padding(.leading, 32)
                .padding(.trailing, 16)
                .padding(.top, 4)
                .transition(.opacity)
            }

            if engine.isSplit && state.routingApp == app.id {
                outputList
                    .transition(.opacity)
            }
        }
        .transition(.opacity)
    }

    /// The app's own Split button: shows the output it plays through, blue when that's not the
    /// main outputs.
    private var splitButton: some View {
        let routed = engine.isRouted(app.id)
        let device = engine.outputs(for: app.id).first
        let airPlay = engine.activeAirPlay.filter { engine.isRouted(app.id, to: $0) }
        let names = engine.outputs(for: app.id).map(\.name) + airPlay.map(\.name)
        return Button {
            withAnimation(expand) { state.routingApp = state.routingApp == app.id ? nil : app.id }
        } label: {
            Image(systemName: routed ? (device?.symbol(.output) ?? airPlay.first?.symbol ?? "speaker.wave.2") : Glyph.split)
                .rotationEffect(.degrees(routed ? 0 : Glyph.sideways))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(routed ? Color.white : Color.primary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(routed ? Color.accentColor : Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(routed ? names.joined(separator: " + ") : "Choose where \(app.name) plays")
    }

    private var outputList: some View {
        let routed = engine.isRouted(app.id)
        return VStack(spacing: 2) {
            HoverRow(action: { withAnimation(expand) { engine.followMainOutputs(app.id) } }) {
                IconCircle(symbol: "speaker.wave.2", isOn: !routed, size: 24)
                Text("Same as Output").font(.system(size: 12))
                Spacer(minLength: 0)
            }
            ForEach(engine.outputDevices) { device in
                let isOn = routed && engine.outputs(for: app.id).contains { $0.uid == device.uid }
                HoverRow(action: { withAnimation(expand) { engine.toggleRoute(device, for: app.id) } }) {
                    IconCircle(symbol: device.symbol(.output), isOn: isOn, size: 24)
                    Text(device.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
                }
            }
            // AirPlay speakers that are on (Soundcheck is already streaming to them).
            ForEach(engine.activeAirPlay) { speaker in
                let isOn = engine.isRouted(app.id, to: speaker)
                HoverRow(action: { withAnimation(expand) { engine.toggleRoute(speaker, for: app.id) } }) {
                    IconCircle(symbol: speaker.symbol, isOn: isOn, size: 24)
                    Text(speaker.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
                }
            }
        }
        .padding(.leading, 40)
        .padding(.top, 4)
    }
}

/// A browser tab (from Soundcheck's extension): its icon, its title, its own level and mute. Its
/// level multiplies the browser's; a tab on a call says so.
private struct TabRow: View {
    let tab: BrowserTabs.Tab
    let browser: String
    private var tabs = BrowserTabs.shared

    init(tab: BrowserTabs.Tab, browser: String) {
        self.tab = tab
        self.browser = browser
    }

    var body: some View {
        let level = tabs.level(tab, in: browser)
        HStack(spacing: 8) {
            Group {
                if let icon = tabs.icons[BrowserTabs.key(browser, tab.id)] {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .opacity(tab.muted ? 0.4 : 1)
            HStack(spacing: 4) {
                if tab.call {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                        .help("On a call")
                }
                Text(tab.title.isEmpty ? tab.host : tab.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 94, alignment: .leading)
            .help(tab.title + (tab.host.isEmpty ? "" : " — \(tab.host)"))
            Slider(value: Binding(get: { Double(level) }, set: { tabs.setLevel(Float($0), for: tab, in: browser) }), in: 0...1)
                .controlSize(.mini)
                .opacity(tab.muted ? 0.45 : 1)
            MuteButton(control: MuteControl(isMuted: tab.muted) { tabs.setMuted(!tab.muted, for: tab, in: browser) }, value: level)
        }
    }
}

/// An app's level. With Boost on it goes to 200%: a mark at 100%, and orange past it.
private struct AppSlider: View {
    let id: String
    private var engine = AudioEngine.shared

    init(id: String) { self.id = id }

    var body: some View {
        let binding = Binding(get: { Double(engine.appSliderValue(id)) }, set: { engine.setAppLevel(Float($0), for: id) })
        Group {
            if engine.allowBoost {
                Slider(value: binding, in: 0...2) {
                    EmptyView()
                } ticks: {
                    SliderTick(1.0)
                }
                .controlSize(.small)
                .tint(engine.appSliderValue(id) > 1.001 ? .orange : .accentColor)
            } else {
                Slider(value: binding, in: 0...1)
                    .controlSize(.small)
            }
        }
        // Scaled by where the slider is (with Boost the bar runs to 200%).
        .overlay {
            MeterShade(read: { engine.appLiveLevel(id) },
                       scale: engine.appSliderValue(id) / (engine.allowBoost ? 2 : 1))
        }
    }
}

/// The code an Apple TV shows on its screen the first time Soundcheck plays to it.
private struct AirPlayCodeField: View {
    let name: String
    @State private var code = ""
    @FocusState private var focused: Bool
    private var engine = AudioEngine.shared

    init(name: String) { self.name = name }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Type the code shown on \(name)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 80)
                    .focused($focused)
                    .onSubmit { engine.answerAirPlayCode(code) }
                Button("Pair") { engine.answerAirPlayCode(code) }
                    .buttonStyle(AccentCapsuleButtonStyle())
                    .disabled(code.count < 4)
                Button("Cancel") { engine.answerAirPlayCode(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
        }
        .padding(.vertical, 4)
        .onAppear { focused = true }
    }
}
