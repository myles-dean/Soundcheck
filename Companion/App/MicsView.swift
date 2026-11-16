import SwiftUI

/// The Mics tab, under what's playing and the main bar: which microphone Soundcheck Mic carries,
/// or with Route on, the microphones and apps mixed into it (all in one list). Mute Mics is in
/// Options.
struct MicsView: View {
    let state: RemoteState
    @State private var shaping: ShapeEditing?
    @State private var effecting: EffectsEditing?
    private var link: MacLink { .shared }

    var body: some View {
        List {
            SoundHeader(state: state)
            if !state.micInstalled {
                Section {
                    Text("Soundcheck Mic lets every app hear the microphone you pick here, with apps mixed in. Adding it needs your Mac's password, typed on the Mac.")
                        .font(.subheadline)
                    Button(state.installingMic ? "Adding on Your Mac…" : "Add Soundcheck Mic on Your Mac") { link.send(.installMic) }
                        .disabled(state.installingMic)
                } header: {
                    Text("Soundcheck Mic")
                }
            }
            Section {
                if state.micInstalled {
                    Toggle("Route", isOn: Binding(get: { state.routing }, set: { link.send(.setRouting($0)) }))
                }
                ForEach(shownMics) { mic in micRow(mic) }
                if state.micInstalled && state.routing {
                    ForEach(state.routeApps) { app in routeAppRow(app) }
                }
            } header: {
                Text(state.routing ? "In Soundcheck Mic" : "Microphone")
            }
        }
        .navigationTitle(state.soundTitle)
        .sheet(item: $shaping) { ShapeSheet(editing: $0) }
        .sheet(item: $effecting) { EffectsSheet(editing: $0) }
    }

    /// The microphones to pick from. An iPhone doesn't list its own microphone through Continuity
    /// (it's already here as This iPhone), unless it's the one in use.
    private var shownMics: [RemoteMic] {
        guard PairingStore.deviceKind == "iPhone" else { return state.mics }
        return state.mics.filter { mic in
            mic.isContinuity != true || (state.routing ? mic.isRouted : mic.isSelected)
        }
    }

    @ViewBuilder
    private func micRow(_ mic: RemoteMic) -> some View {
        let picked = state.routing ? mic.isRouted : mic.isSelected
        let isMe = mic.companion == PairingStore.deviceID
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    link.send(state.routing ? .toggleRouteMic(mic.id) : .selectMic(mic.id))
                } label: {
                    HStack(spacing: 12) {
                        DeviceCircle(symbol: mic.symbol, isOn: picked)
                        Text(isMe ? "This \(PairingStore.deviceKind)" : mic.name).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if picked {
                    EQButton(shape: mic.shape) { shaping = ShapeEditing(target: .mic(mic.id), name: mic.name) }
                    // Effects run in Soundcheck Mic.
                    if state.micInstalled, let effects = mic.effects {
                        FXButton(effects: effects) { effecting = EffectsEditing(target: .mic(mic.id), name: mic.name) }
                    }
                }
                Group {
                    if state.routing {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked ? Color.accentColor : .secondary)
                    } else if picked {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 22)
            }
            if picked {
                if let volume = mic.volume {
                    LevelSlider(value: volume, muted: mic.muted, kind: .mic,
                                onMute: { link.send(.setMicMuted(id: mic.id, muted: !mic.muted)) }) {
                        link.send(.setMicVolume(id: mic.id, volume: $0), coalescing: "mic:" + mic.id)
                    }
                    .padding(.leading, 44)
                } else {
                    Button(mic.muted ? "Unmute" : "Mute") { link.send(.setMicMuted(id: mic.id, muted: !mic.muted)) }
                        .font(.footnote)
                        .padding(.leading, 44)
                }
            }
        }
    }

    /// An app playing sound, to mix into Soundcheck Mic (Route), laid out like a microphone.
    private func routeAppRow(_ app: RemoteRouteApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                link.send(.toggleRoutedApp(app.id))
            } label: {
                HStack(spacing: 12) {
                    AppIcon(id: app.id, size: 32, fallback: app.id == "com.mylesdean.Soundcheck.system" ? "gearshape.fill" : "app.fill")
                    Text(app.name).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: app.isRouted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(app.isRouted ? Color.accentColor : .secondary)
                        .frame(width: 22)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if app.isRouted {
                LevelSlider(value: app.level, muted: app.muted,
                            onMute: { link.send(.setRouteAppMuted(id: app.id, muted: !app.muted)) }) {
                    link.send(.setRouteAppLevel(id: app.id, level: $0), coalescing: "route:" + app.id)
                }
                .padding(.leading, 44)
            }
        }
    }
}
