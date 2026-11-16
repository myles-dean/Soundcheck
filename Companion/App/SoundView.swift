import SwiftUI

extension RemoteState {
    /// Every tab's title: "MacBook Sound".
    var soundTitle: String { "\(macShortName) Sound" }
}

/// The top of the Speakers, Apps and Mics tabs: what's playing, then the main bar. The tab picks
/// what the bar moves (as the switch above it does on the Mac).
struct SoundHeader: View {
    let state: RemoteState
    private var link: MacLink { .shared }

    var body: some View {
        nowPlayingSection
        mainSection
    }

    // MARK: Now playing

    private var nowPlayingSection: some View {
        Section("Now Playing") {
            HStack(spacing: 12) {
                let playing = state.apps.filter(\.isPlaying)
                if playing.isEmpty {
                    AppIcon(id: "system", size: 40)
                    Text("Nothing playing").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: -10) {
                        ForEach(playing.prefix(3)) { app in AppIcon(id: app.id, size: 40) }
                    }
                    Text(ListFormatter.localizedString(byJoining: playing.map(\.name)))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                HStack(spacing: 18) {
                    Button { link.send(.previousTrack) } label: { Image(systemName: "backward.fill") }
                    Button { link.send(.playPause) } label: {
                        Image(systemName: state.playing.isEmpty ? "play.fill" : "pause.fill").font(.title2)
                    }
                    Button { link.send(.nextTrack) } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Main volume

    private var mainSection: some View {
        Section {
            // Its icon only shows the level (muting is on each bar, and Mute Mics is in Options).
            LevelSlider(value: state.knobValue, muted: state.knob == "speakers" && state.speakersMuted,
                        kind: state.knob == "mics" ? .mic : .speaker, showsIcon: true) {
                link.setKnobValueLocally($0)
                link.send(.setKnobValue($0), coalescing: "knob")
            }
            if state.onCall && state.options.duckMode != "off" {
                Label("On a call: other apps are \(state.options.duckMode == "mute" ? "muted" : "lowered")", systemImage: "phone.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if state.needsPermission {
                OnTheMacNote(text: "Soundcheck needs the System Audio Recording permission on the Mac.")
            }
        }
    }
}

/// The Speakers or the Apps tab, under what's playing and the main bar.
struct SoundView: View {
    enum Page { case speakers, apps }
    let state: RemoteState
    let page: Page
    @State private var shaping: ShapeEditing?
    @State private var effecting: EffectsEditing?
    private var link: MacLink { .shared }

    init(state: RemoteState, page: Page) {
        self.state = state
        self.page = page
    }

    var body: some View {
        List {
            SoundHeader(state: state)
            switch page {
            case .speakers: speakersSection
            case .apps: appsSection
            }
        }
        .navigationTitle(state.soundTitle)
        .sheet(item: $shaping) { ShapeSheet(editing: $0) }
        .sheet(item: $effecting) { EffectsSheet(editing: $0) }
    }

    // MARK: Speakers

    private var speakersSection: some View {
        Section {
            ForEach(state.speakers.filter { $0.kind != .airPlay || $0.isOn }) { speaker in speakerRow(speaker) }
            let airPlay = state.speakers.filter { $0.kind == .airPlay && !$0.isOn }
            if !airPlay.isEmpty {
                DisclosureGroup("AirPlay") {
                    ForEach(airPlay) { speaker in speakerRow(speaker) }
                }
            }
            if state.speakers.contains(where: { $0.kind != .device && $0.isOn }) {
                Toggle("Only AirPlay & iPhones", isOn: Binding(get: { state.airPlayOnly }, set: { link.send(.setAirPlayOnly($0)) }))
            }
        } header: {
            Text("Speakers")
        }
    }

    @ViewBuilder
    private func speakerRow(_ speaker: RemoteSpeaker) -> some View {
        let isMe = speaker.companion == PairingStore.deviceID
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if speaker.kind == .device { link.send(.selectOnlySpeaker(speaker.id)) } else { link.send(.toggleSpeaker(speaker.id)) }
                } label: {
                    HStack(spacing: 12) {
                        DeviceCircle(symbol: speaker.symbol, isOn: speaker.isOn)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(isMe ? "This \(PairingStore.deviceKind)" : speaker.name).foregroundStyle(.primary)
                            if let status = speaker.status {
                                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if speaker.canHearYourself && state.micInstalled {
                    Button {
                        link.send(.toggleHearSoundcheckMic(speakers: [speaker.id]))
                    } label: {
                        RoundButtonFace(isOn: speaker.hearsSoundcheckMic) {
                            Image(systemName: "headphones").font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Hear Yourself")
                }
                EQButton(shape: speaker.shape) { shaping = ShapeEditing(target: .speaker(speaker.id), name: speaker.name) }
                Button {
                    link.send(.toggleSpeaker(speaker.id))
                } label: {
                    Image(systemName: speaker.isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(speaker.isOn ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(speaker.isOn ? "Remove" : "Add")
            }
            // Each speaker in use has its own volume (the Mac opens Mix as soon as they differ).
            if speaker.isOn && state.speakers.filter(\.isOn).count > 1 {
                LevelSlider(value: speaker.volume, muted: speaker.muted,
                            onMute: { link.send(.setSpeakerMuted(id: speaker.id, muted: !speaker.muted)) }) {
                    link.send(.setSpeakerVolume(id: speaker.id, volume: $0), coalescing: "speaker:" + speaker.id)
                }
                .padding(.leading, 44)
            }
            // Playing here: line it up with the Mac's other speakers by ear.
            if isMe && speaker.isOn {
                TimingRow(speaker: speaker)
                    .padding(.leading, 44)
            }
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        Section {
            ForEach(state.apps) { app in AppRow(app: app, state: state, shaping: $shaping, effecting: $effecting) }
        } header: {
            Text("Apps")
        }
    }
}

private struct AppRow: View {
    let app: RemoteApp
    let state: RemoteState
    @Binding var shaping: ShapeEditing?
    @Binding var effecting: EffectsEditing?
    @State private var showsTabs = false
    private var link: MacLink { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AppIcon(id: app.id, size: 30, fallback: app.isSystem ? "gearshape.fill" : "app.fill")
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name).lineLimit(1)
                    // Split: say where it plays, so it isn't a mystery why it's quiet elsewhere.
                    if isRouted {
                        let names = app.routes.compactMap { key in state.speakers.first { $0.id == key }.map { $0.companion == PairingStore.deviceID ? "This \(PairingStore.deviceKind)" : $0.name } }
                        Text(names.isEmpty ? "Split" : "Only on " + ListFormatter.localizedString(byJoining: names))
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }
                if app.isListening {
                    Image(systemName: "mic.fill").font(.caption).foregroundStyle(.orange)
                }
                if let tabs = app.tabs, !tabs.isEmpty {
                    Button {
                        withAnimation { showsTabs.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsTabs ? 180 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Tabs")
                }
                Spacer(minLength: 0)
                EQButton(shape: app.shape) { shaping = ShapeEditing(target: .app(app.id), name: app.name) }
                if let effects = app.effects {
                    FXButton(effects: effects) { effecting = EffectsEditing(target: .app(app.id), name: app.name) }
                }
                menu
            }
            LevelSlider(value: app.volume, range: 0...(state.options.allowBoost ? 2 : 1), muted: app.muted,
                        onMute: { link.send(.setAppMuted(id: app.id, muted: !app.muted)) }) {
                link.send(.setAppVolume(id: app.id, volume: $0), coalescing: "app:" + app.id)
            }
            .padding(.leading, 40)
            if showsTabs, let tabs = app.tabs {
                ForEach(tabs) { tab in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            AppIcon(id: app.id + "#\(tab.id)", size: 18, fallback: "globe")
                            Text(tab.title.isEmpty ? tab.host : tab.title).font(.subheadline).lineLimit(1)
                            if tab.call { Image(systemName: "phone.fill").font(.caption2).foregroundStyle(.green) }
                        }
                        LevelSlider(value: tab.level, muted: tab.muted,
                                    onMute: { link.send(.setTabMuted(browser: app.id, tab: tab.id, muted: !tab.muted)) }) {
                            link.send(.setTabVolume(browser: app.id, tab: tab.id, volume: $0), coalescing: "tab:\(app.id)#\(tab.id)")
                        }
                    }
                    .padding(.leading, 40)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// It plays on speakers of its own (with Split on, on the Mac).
    private var isRouted: Bool { !app.isSplitOff && state.split }

    private var menu: some View {
        Menu {
            Section("Play On") {
                Button {
                    link.send(.followMainSpeakers(app.id))
                } label: {
                    if isRouted { Text("Main Speakers") } else { Label("Main Speakers", systemImage: "checkmark") }
                }
                ForEach(state.speakers.filter { $0.kind == .device || $0.isOn }) { speaker in
                    Button {
                        // The Mac turns Split on for it.
                        link.send(.toggleAppSpeaker(app: app.id, speaker: speaker.id))
                    } label: {
                        Label(speaker.name, systemImage: isRouted && app.routes.contains(speaker.id) ? "checkmark" : speaker.symbol)
                    }
                }
            }
            if !app.isSystem {
                Button {
                    link.send(.togglePin(app.id))
                } label: {
                    Label(app.pinned ? "Unpin" : "Keep in List", systemImage: app.pinned ? "pin.slash" : "pin")
                }
            }
        } label: {
            Image(systemName: isRouted ? "arrow.triangle.branch" : "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundStyle(isRouted ? Color.accentColor : .secondary)
        }
        .accessibilityLabel("Speakers for \(app.name)")
    }
}

/// Lines this device up with the Mac's other speakers by ear: later (left) or earlier (right),
/// up to a third of a second either way. Kept on the Mac.
private struct TimingRow: View {
    let speaker: RemoteSpeaker
    @State private var dragging: Double?
    private var value: Double { dragging ?? speaker.sync ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Timing", systemImage: "metronome")
                Spacer()
                Text(abs(value) < 0.0005 ? "As measured" : String(format: "%.0f ms %@", abs(value) * 1000, value > 0 ? "earlier" : "later"))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Later").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { value }, set: { new in
                    let snapped = abs(new) < 0.004 ? 0 : (new * 1000).rounded() / 1000
                    dragging = snapped
                    MacLink.shared.send(.setAirPlaySync(id: speaker.id, seconds: snapped), coalescing: "sync")
                }), in: -0.33...0.33) { editing in
                    if !editing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dragging = nil } }
                }
                Text("Earlier").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
