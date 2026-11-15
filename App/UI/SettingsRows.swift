import ServiceManagement
import SwiftUI

/// The settings, in three groups, shared by the Options menu (as dropdowns) and the welcome window.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case sound, microphones, soundcheck
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: "Speakers & Apps"
        case .microphones: "Microphones"
        case .soundcheck: "Soundcheck"
        }
    }

    var symbol: String {
        switch self {
        case .sound: "hifispeaker.2"
        case .microphones: "mic"
        case .soundcheck: "gearshape"
        }
    }
}

struct SettingsRows: View {
    let group: SettingsGroup
    private var engine = AudioEngine.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var pinsOpen = false
    private let expand = Animation.easeInOut(duration: PanelController.animationDuration)

    init(group: SettingsGroup) { self.group = group }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch group {
            case .sound: sound
            case .microphones: microphones
            case .soundcheck: soundcheck
            }
        }
    }

    // MARK: Speakers & Apps

    @ViewBuilder private var sound: some View {
        OptionRow(symbol: "headphones", title: "Switch to Headphones", isOn: engine.switchToHeadphones) {
            engine.setSwitchToHeadphones(!engine.switchToHeadphones)
        }
        .help("When headphones connect, everything plays through them until they disconnect")
        OptionRow(symbol: engine.nightMode ? "moon.fill" : "moon", title: "Night Mode", isOn: engine.nightMode) {
            engine.setNightMode(!engine.nightMode)
        }
        .help("Evens out loud and quiet parts, so explosions don't wake anyone and dialogue stays clear")
        OptionRow(symbol: "phone", title: "Quiet Apps in Calls", isOn: engine.duckMode != .off) {
            withAnimation(expand) { engine.setDuckMode(engine.duckMode == .off ? .lower : .off) }
        }
        .help("While a call rings or an app uses a microphone, lower or mute the other apps")
        if engine.duckMode != .off {
            PillPicker(options: [(AudioEngine.DuckMode.lower, "Lower"), (.mute, "Mute")],
                       selection: engine.duckMode) { engine.setDuckMode($0) }
                .padding(.leading, 54)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
        OptionRow(symbol: "speaker.wave.3", title: "Boost Apps", isOn: engine.allowBoost) {
            engine.setAllowBoost(!engine.allowBoost)
        }
        .help("App sliders go up to 200%, for apps that are too quiet")
        HoverRow(action: { withAnimation(expand) { pinsOpen.toggle() } }) {
            IconCircle(symbol: "pin", isOn: !engine.pinnedApps.isEmpty)
            Text("Pinned Apps").font(.system(size: 13))
            Spacer(minLength: 0)
            Chevron(isOpen: pinsOpen)
        }
        .help("Apps that always show in the Apps list, even when they're quiet or closed")
        if pinsOpen {
            PinnedAppsList()
                .transition(.opacity)
        }
    }

    // MARK: Microphones

    @ViewBuilder private var microphones: some View {
        OptionRow(symbol: "wand.and.stars", title: "Voice Cleanup", isOn: engine.voiceCleanup) {
            engine.setVoiceCleanup(!engine.voiceCleanup)
        }
        .help("In Soundcheck Mic: cuts rumble, quiets the room between your words and evens out your level")
        OptionRow(symbol: "music.note", title: "Lower Apps When You Talk", isOn: engine.duckUnderVoice) {
            engine.setDuckUnderVoice(!engine.duckUnderVoice)
        }
        .help("Apps routed into Soundcheck Mic dip while you talk, so you're heard over the music (they don't change on your speakers)")
        HoverRow(action: { engine.setMicsMuted(!engine.micsMuted) }) {
            IconCircle(symbol: engine.micsMuted ? "mic.slash.fill" : "mic.slash", isOn: engine.micsMuted)
            Text("Mute Mics").font(.system(size: 13))
            Spacer(minLength: 0)
            ShortcutField()
        }
    }

    // MARK: Soundcheck

    @ViewBuilder private var soundcheck: some View {
        OptionRow(symbol: "power", title: "Open at Login", isOn: launchAtLogin) { setLaunchAtLogin(!launchAtLogin) }
        OptionRow(symbol: "menubar.rectangle", title: "Keep in Menu Bar", isOn: engine.keepInMenuBar) {
            engine.setKeepInMenuBar(!engine.keepInMenuBar)
        }
        // Opens its own window (hence the arrow).
        HoverRow(action: { SetupsWindowController.shared.show() }) {
            IconCircle(symbol: "square.stack.3d.up", isOn: !SetupStore.shared.setups.isEmpty)
            Text("Saved Setups").font(.system(size: 13))
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .help("Save and switch between layouts of speakers, apps and mics, by hand or automatically")
        HoverRow(action: { BrowserSetupWindowController.shared.show() }) {
            IconCircle(symbol: "globe", isOn: !BrowserTabs.shared.connected.isEmpty)
            Text("Browser Tabs").font(.system(size: 13))
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .help("Add Soundcheck's extension to Safari, Dia and Chrome, for each tab's own volume")
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Couldn't change the login item: \(error.localizedDescription, privacy: .public)")
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// A dropdown's chevron, turned up while it's open.
struct Chevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isOpen ? 180 : 0))
    }
}

/// The Mute Mics shortcut: click, then type it (Delete clears it, Escape cancels).
struct ShortcutField: View {
    private var shortcut = MicMuteShortcut.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Type Shortcut…" : (shortcut.display ?? "Set Shortcut"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(recording ? Color.white : Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(recording ? Color.accentColor : Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("A keyboard shortcut that mutes and unmutes every microphone")
        .onDisappear(perform: stop)
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stop() // Escape
            case 51, 117: // Delete
                shortcut.clear()
                stop()
            default:
                if shortcut.record(event) { stop() }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
