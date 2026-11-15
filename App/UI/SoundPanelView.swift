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

            LevelSlider(value: engine.knob == .speakers && engine.isMuted ? 0 : engine.knobValue,
                        low: engine.knob == .mics ? "mic.fill" : (engine.knob == .speakers && engine.isMuted ? "speaker.slash.fill" : "speaker.fill"),
                        high: engine.knob == .mics ? "mic.and.signal.meter.fill" : "speaker.wave.3.fill",
                        lowAction: engine.knob == .speakers ? { engine.setMuted(!engine.isMuted) } : nil,
                        meter: engine.knob == .mics ? { engine.micsLiveLevel } : nil,
                        onChange: { engine.setKnobValue($0) })
                .padding(.horizontal, 16)

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
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRows()
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
                    OptionRow(symbol: "arrow.counterclockwise", title: "Reset", isOn: false) {
                        withAnimation(expand) { engine.reset() }
                    }
                    .help("Turn off Route, Split and Mix, and set the volume back to Speakers")
                    TextRow(title: "Quit Soundcheck") { NSApp.terminate(nil) }
                    TextRow(title: "Sound Settings…") { open("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
                }
                .padding(.leading, 12)
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
                CapsuleToggle(title: "Mix", symbol: "slider.horizontal.3", isOn: engine.isMixing) {
                    withAnimation(expand) { engine.setMixing(!engine.isMixing) }
                }
                .help("Set each speaker's own volume")
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
                    }
                    airPlayGroup
                }
                .padding(.leading, 12)
                .transition(.opacity)
            }

            // Mix: each speaker in use has its own level; on Speakers the main slider and the
            // volume keys move them together.
            if engine.isMixing {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(engine.playsLocally ? engine.activeOutputs : []) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            LevelSlider(value: engine.outputVolume(device), low: device.symbol(.output),
                                        onChange: { engine.setOutputVolume($0, for: device) })
                        }
                    }
                    ForEach(engine.activeAirPlay) { speaker in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(speaker.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            LevelSlider(value: engine.airPlayVolume(speaker), low: speaker.symbol,
                                        onChange: { engine.setAirPlayVolume($0, for: speaker) })
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
    }

    /// AirPlay: one row whose icon is how many AirPlay speakers are on, opening to the speakers on
    /// the network (Soundcheck streams to them itself, in sync with the regular speakers).
    private var airPlayGroup: some View {
        let count = engine.activeAirPlay.count
        return VStack(spacing: 2) {
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
                    let speakers = AirPlayBrowser.shared.speakers
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
                        let isOn = engine.airPlayIDs.contains(speaker.id)
                        HoverRow(action: { withAnimation(expand) { engine.toggleAirPlay(speaker) } }) {
                            IconCircle(symbol: speaker.symbol, isOn: isOn, size: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(speaker.name).font(.system(size: 12)).lineLimit(1)
                                switch engine.airPlayStates[speaker.id] {
                                case .connecting:
                                    Text("Connecting…").font(.system(size: 10)).foregroundStyle(.secondary)
                                case .failed:
                                    Text("Couldn't connect").font(.system(size: 10)).foregroundStyle(.red)
                                default:
                                    EmptyView()
                                }
                            }
                            Spacer(minLength: 0)
                            Checkmark(isOn: isOn)
                        }
                        if engine.airPlayCodeRequest == speaker.id {
                            AirPlayCodeField(name: speaker.name)
                                .padding(.leading, 46)
                                .padding(.trailing, 16)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.leading, 12)
                .transition(.opacity)
            }
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

            AppStackRow(apps: engine.visibleApps, isOpen: state.appsOpen) {
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
                if let input = engine.shownInput, let volume = engine.micVolume(input) {
                    LevelSlider(value: volume, low: "mic.fill", high: "mic.and.signal.meter.fill",
                                meter: { engine.liveLevel(input) },
                                onChange: { engine.setMicVolume($0, for: input) })
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
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
                    if isOn, let volume = engine.micVolume(device) {
                        LevelSlider(value: volume, low: "mic.fill", high: "mic.and.signal.meter.fill",
                                    meter: { engine.routeLiveLevel(device.uid) },
                                    onChange: { engine.setMicVolume($0, for: device) })
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
                if engine.routableApps.isEmpty {
                    Text("Apps appear here when they play sound.")
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
                        LevelSlider(value: engine.routeAppLevel(app.id), low: "speaker.fill", high: "speaker.wave.3.fill",
                                    meter: { engine.routeLiveLevel(app.id) },
                                    onChange: { engine.setRouteAppLevel($0, for: app.id) })
                            .padding(.leading, 50)
                            .padding(.trailing, 16)
                            .padding(.bottom, 2)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
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
                Text(app.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(width: engine.isSplit ? 70 : 84, alignment: .leading)
                AppSlider(id: app.id)
                    .disabled(muted)
                if engine.isSplit {
                    splitButton
                }
            }
            .padding(.horizontal, 16)

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
        return Button {
            withAnimation(expand) { state.routingApp = state.routingApp == app.id ? nil : app.id }
        } label: {
            Image(systemName: routed ? (device?.symbol(.output) ?? "speaker.wave.2") : Glyph.split)
                .rotationEffect(.degrees(routed ? 0 : Glyph.sideways))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(routed ? Color.white : Color.primary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(routed ? Color.accentColor : Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(routed ? engine.outputs(for: app.id).map(\.name).joined(separator: " + ") : "Choose where \(app.name) plays")
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
        }
        .padding(.leading, 40)
        .padding(.top, 4)
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
