import SwiftUI

/// The panel's Options, in its three groups, then which Mac this is with.
struct OptionsView: View {
    let state: RemoteState
    @State private var choosingMac = false
    @State private var confirmForget = false
    private var link: MacLink { .shared }

    private func toggle(_ title: String, _ symbol: String, _ value: Bool, _ command: @escaping (Bool) -> RemoteCommand) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { link.send(command($0)) })) {
            Label(title, systemImage: symbol)
        }
    }

    var body: some View {
        Form {
            Section("Speakers & Apps") {
                toggle("Switch to Headphones", "headphones", state.options.switchToHeadphones) { .setSwitchToHeadphones($0) }
                toggle("Night Mode", state.options.nightMode ? "moon.fill" : "moon", state.options.nightMode) { .setNightMode($0) }
                Picker(selection: Binding(get: { state.options.duckMode }, set: { link.send(.setDuckMode($0)) })) {
                    Text("Off").tag("off")
                    Text("Lower").tag("lower")
                    Text("Mute").tag("mute")
                } label: {
                    Label("Quiet Apps in Calls", systemImage: "phone")
                }
                toggle("Boost Apps", "speaker.wave.3", state.options.allowBoost) { .setAllowBoost($0) }
            }
            Section("Microphones") {
                toggle("Voice Cleanup", "wand.and.stars", state.options.voiceCleanup) { .setVoiceCleanup($0) }
                toggle("Lower Apps When You Talk", "music.note", state.options.duckUnderVoice) { .setDuckUnderVoice($0) }
                toggle("Mute Mics", state.micsMuted ? "mic.slash.fill" : "mic.slash", state.micsMuted) { .setMicsMuted($0) }
            }
            Section {
                toggle("Open at Login", "power", state.options.launchAtLogin) { .setLaunchAtLogin($0) }
                toggle("Keep in Menu Bar", "menubar.rectangle", state.options.keepInMenuBar) { .setKeepInMenuBar($0) }
                Button {
                    link.send(.checkForUpdates)
                } label: {
                    Label("Check for Updates on Mac", systemImage: "arrow.down.circle")
                }
                Button {
                    link.send(.openOnMac("sound"))
                } label: {
                    Label("Open Sound Settings on Mac", systemImage: "gear")
                }
            } header: {
                Text("Soundcheck")
            } footer: {
                Text("Soundcheck \(state.version) on \(state.macName)")
            }
            Section {
                if state.canUndoReset {
                    Button {
                        link.send(.undoReset)
                    } label: {
                        Label("Undo Reset", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button(role: .destructive) {
                        link.send(.reset)
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                }
            } footer: {
                Text("Reset puts every level back, flattens the EQs, and turns off Split, Route and Hear Yourself. You have 5 seconds to undo it.")
            }
            Section {
                LabeledContent("Mac", value: state.macName)
                if link.found.count > 1 {
                    Button("Switch Mac…") { choosingMac = true }
                }
                Button("Forget This Mac", role: .destructive) { confirmForget = true }
                    // Anchored to the button, so it opens from there.
                    .confirmationDialog("Forget \(state.macName)?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) { link.forgetMac() }
                    } message: {
                        Text("You'll need to allow this \(PairingStore.deviceKind) on the Mac again to use it.")
                    }
            }
        }
        .navigationTitle(state.soundTitle)
        .sheet(isPresented: $choosingMac) { MacPicker() }
    }
}

/// The Macs on the network running Soundcheck.
struct MacPicker: View {
    @Environment(\.dismiss) private var dismiss
    private var link: MacLink { .shared }

    var body: some View {
        NavigationStack {
            List(link.found) { mac in
                Button {
                    link.choose(mac)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: mac.symbol)
                        Text(mac.name).foregroundStyle(.primary)
                        Spacer()
                        if mac.id == link.macID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
            }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

