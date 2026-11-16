import SwiftUI

/// Finding and pairing with a Mac, then the panel in tabs (a sidebar on iPad and on a foldable
/// opened up): Speakers, Apps and Mics, which are also what the main bar moves (picking a tab
/// picks it, as on the Mac, and the Mac picking it switches the tab), then Options.
struct RootView: View {
    private var link: MacLink { .shared }
    /// Get Started was tapped (the welcome shows until then).
    @AppStorage(WelcomeView.welcomedKey) private var welcomed = false
    @State private var tab = "speakers"
    /// When a tab was last picked here (the Mac's answers to the taps before it are ignored).
    @State private var pickedAt = Date.distantPast
    private static let knobs: Set<String> = ["speakers", "apps", "mics"]

    var body: some View {
        Group {
            if !welcomed {
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.35)) { welcomed = true }
                    MacLink.shared.activate()
                }
                .transition(.opacity)
            // A Mac that's gone (switched off, another network): back to choosing one.
            } else if let state = link.state, link.isConnected || link.chosenMacIsAround {
                TabView(selection: $tab) {
                    Tab("Speakers", systemImage: "speaker.wave.2.fill", value: "speakers") {
                        NavigationStack { SoundView(state: state, page: .speakers).toolbar { connectionBadge } }
                    }
                    Tab("Apps", systemImage: "square.grid.2x2.fill", value: "apps") {
                        NavigationStack { SoundView(state: state, page: .apps).toolbar { connectionBadge } }
                    }
                    Tab("Mics", systemImage: "mic.fill", value: "mics") {
                        NavigationStack { MicsView(state: state).toolbar { connectionBadge } }
                    }
                    // Three dots, as the Mac's ••• Options row.
                    Tab("Options", systemImage: "ellipsis", value: "options") {
                        NavigationStack { OptionsView(state: state).toolbar { connectionBadge } }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .disabled(!link.isConnected)
                .onAppear { if Self.knobs.contains(state.knob) { tab = state.knob } }
            } else {
                ConnectView()
            }
        }
        // A tab picks what the main bar moves; the Mac picking it switches the tab (not away
        // from Options).
        .onChange(of: tab) { _, tab in
            guard Self.knobs.contains(tab), link.state?.knob != tab else { return }
            pickedAt = Date()
            link.send(.setKnob(tab))
        }
        .onChange(of: link.state?.knob) { _, knob in
            guard let knob, Self.knobs.contains(knob), Self.knobs.contains(tab), knob != tab,
                  Date().timeIntervalSince(pickedAt) > 1 else { return }
            tab = knob
        }
        .onChange(of: link.isConnected) { _, connected in
            guard connected else { return }
            // Once paired: notifications (to start playing when the Mac asks) and Bluetooth (so the
            // Mac can wake the app).
            Notifications.requestPermission()
            BeaconCentral.shared.start()
        }
    }

    @ToolbarContentBuilder
    private var connectionBadge: some ToolbarContent {
        if !link.isConnected {
            ToolbarItem(placement: .topBarTrailing) {
                Label("Reconnecting", systemImage: "wifi.exclamationmark")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Before there's a Mac: looking for one, connecting, or pairing (with the code both show).
struct ConnectView: View {
    private var link: MacLink { .shared }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                MacTile(symbol: link.currentMac?.symbol ?? "laptopcomputer")
                switch link.status {
                case .pairing(let name, let code):
                    Text("Allow on \(name)").font(.title2.bold())
                    Text("On your Mac, check it shows this code, then click Allow.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text(code).font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                case .refused(let message):
                    Text(message).font(.headline).multilineTextAlignment(.center)
                    Button("Try Again") { link.tryAgain() }.buttonStyle(.borderedProminent)
                case .connecting(let name):
                    ProgressView()
                    Text("Connecting to \(name)…").foregroundStyle(.secondary)
                case .searching, .connected:
                    if link.found.isEmpty {
                        ProgressView()
                        Text("Looking for your Mac…").font(.title3.weight(.semibold))
                        Text("Open Soundcheck on your Mac (version 1.2 or later), on the same Wi-Fi as this \(PairingStore.deviceKind).")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Link("Get Soundcheck for Mac", destination: WelcomeView.soundcheckURL)
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Text("Choose Your Mac").font(.title3.weight(.semibold))
                        VStack(spacing: 10) {
                            ForEach(link.found) { mac in
                                Button {
                                    link.choose(mac)
                                } label: {
                                    Label(mac.name, systemImage: mac.symbol)
                                        .frame(maxWidth: 320)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                        }
                    }
                }
                Spacer()
                Text("Soundcheck Companion controls Soundcheck on your Mac: speakers, apps, mics and options. It can also play your Mac's sound here, or be its microphone.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .navigationTitle("Soundcheck")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
