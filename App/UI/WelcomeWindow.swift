import AppKit
import AVFoundation
import SwiftUI

/// Shown the first time someone opens Soundcheck: what it does, its settings, the permissions it
/// asks for, adding Soundcheck Mic, and hiding macOS's own Sound icon (Soundcheck's speaker
/// replaces it).
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let seenKey = "hasSeenWelcome"
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }
    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView(done: { [weak self] in self?.window?.close() }))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to Soundcheck"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        window = nil // start again from the first step if it's shown again
    }
}

private struct WelcomeView: View {
    let done: () -> Void
    @State private var page = 0
    private var keys = VolumeKeys.shared
    private var engine = AudioEngine.shared
    private var airPlay = AirPlayBrowser.shared

    init(done: @escaping () -> Void) { self.done = done }

    private let pages = 6
    private var buttonTitle: String {
        switch page {
        case 0: "Get Started"
        case pages - 1: "Done"
        default: "Continue"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                switch page {
                case 0: welcome.transition(slide)
                case 1: settings.transition(slide)
                case 2: permissions.transition(slide)
                case 3: microphone.transition(slide)
                case 4: menuBar.transition(slide)
                default: allSet.transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()

            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 16)

            Button(buttonTitle) {
                if page < pages - 1 {
                    withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                } else {
                    done()
                }
            }
            .buttonStyle(AccentCapsuleButtonStyle(large: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(width: 460, height: 620)
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }

    // 1: what it does.
    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            title("Welcome to Soundcheck")
            subtitle("Every speaker, app and microphone on your Mac, from one speaker in the menu bar.")
            VStack(alignment: .leading, spacing: 16) {
                Step(symbol: "hifispeaker.2", title: "Speakers",
                     text: "Play through one or several at once, AirPlay speakers like HomePod included, all in sync. Mix gives each its own volume.")
                Step(symbol: "square.grid.2x2", title: "Apps",
                     text: "A volume for every app making sound; click an app's icon to mute it. Split sends an app to its own speakers.")
                Step(symbol: "mic", title: "Mics",
                     text: "Route mixes microphones and apps into Soundcheck Mic, for calls and streams.")
                Step(symbol: "speaker.wave.3", title: "The volume keys",
                     text: "Choose Speakers, Apps or Mics at the top, and the keys move that group together.")
            }
            .padding(.top, 22)
        }
    }

    // 2: the settings (the same rows as in Options).
    private var settings: some View {
        VStack(spacing: 0) {
            title("Settings")
            subtitle("Choose how Soundcheck behaves (they're under Options anytime). Open Saved Setups to set up pre-configured layouts.")
            ScrollView {
                SettingsRows()
                    .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
            .padding(.top, 18)
        }
    }

    // 3: the permissions.
    private var permissions: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 0) {
                title("Permissions")
                subtitle("macOS asks before an app can do any of these. Allow the ones you'll use; you can change them later in System Settings › Privacy & Security.")
                VStack(spacing: 10) {
                    Permission(symbol: "speaker.wave.2", title: "Volume keys",
                               text: "Lets Soundcheck show its own volume pill and move the group you choose. Turn on Soundcheck under Accessibility.",
                               allowed: keys.isActive) { keys.requestPermission() }
                    Permission(symbol: "waveform", title: "App volumes",
                               text: "Lets Soundcheck change each app's volume, play through several speakers and AirPlay, and route apps into Soundcheck Mic. While it does, macOS shows its recording icon next to Control Center. Nothing is recorded.",
                               allowed: AudioCapturePermission.status == .allowed,
                               denied: AudioCapturePermission.status == .denied) {
                        if AudioCapturePermission.status == .denied {
                            openPrivacy("Privacy_AudioCapture")
                        } else {
                            AudioCapturePermission.request { _ in }
                        }
                    }
                    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
                    Permission(symbol: "mic", title: "Microphones",
                               text: "Lets Soundcheck carry the mic you pick into Soundcheck Mic, with its level meter.",
                               allowed: mic == .authorized, denied: mic == .denied || mic == .restricted) {
                        if mic == .notDetermined {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        } else {
                            openPrivacy("Privacy_Microphone")
                        }
                    }
                    Permission(symbol: "airplay.audio", title: "AirPlay speakers",
                               text: "Lets Soundcheck find HomePods, Apple TVs and other AirPlay speakers on your network and play to them. An Apple TV shows a code the first time; type it into Soundcheck's AirPlay list.",
                               allowed: airPlay.isBrowsing && airPlay.problem == nil && !airPlay.speakers.isEmpty,
                               denied: airPlay.isDenied,
                               waiting: airPlay.isBrowsing && airPlay.problem == nil && airPlay.speakers.isEmpty) {
                        if airPlay.isDenied {
                            openPrivacy("Privacy_LocalNetwork")
                        } else {
                            airPlay.start() // the first look on the network brings up macOS's question
                        }
                    }
                }
                .padding(.top, 18)
            }
        }
    }

    private func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // 4: Soundcheck Mic (can be skipped; the Microphone section offers it later).
    private var microphone: some View {
        VStack(spacing: 0) {
            Image(systemName: "mic.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.accentColor))
                .padding(.top, 30)
            title("Add Soundcheck Mic")
            subtitle("Soundcheck Mic becomes your Mac's microphone. It carries whichever mic you pick in Soundcheck (and apps' sound, with Route), so apps and browsers never need their microphone changed: you change it once, in Soundcheck.")
            Group {
                if engine.isMicrophoneInstalled {
                    Label("Soundcheck Mic is added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13, weight: .semibold))
                } else if engine.isInstallingMicrophone {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add Soundcheck Mic") { engine.installMicrophone() }
                        .buttonStyle(AccentCapsuleButtonStyle())
                }
            }
            .padding(.top, 22)
            Text("Adding it asks for your password once, and your sound pauses for a moment. You can also skip this and add it later from the mic list in Soundcheck.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }

    // 5: hiding macOS's Sound icon.
    private var menuBar: some View {
        VStack(spacing: 0) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.accentColor))
                .padding(.top, 30)
            title("Hide the Sound icon")
            subtitle("Soundcheck's speaker takes the place of macOS's Sound icon, so you only need one.")
            VStack(alignment: .leading, spacing: 16) {
                Step(symbol: "1.circle", title: "Open Menu Bar settings", text: "In System Settings, choose Menu Bar.")
                Step(symbol: "2.circle", title: "Find Sound", text: "Set it to Don't Show.")
            }
            .padding(.top, 22)
            Button("Open Menu Bar Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
            }
            .buttonStyle(.link)
            .padding(.top, 18)
        }
    }

    // 6: where to find it.
    private var allSet: some View {
        VStack(spacing: 0) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.accentColor))
                .padding(.top, 60)
            title("You're all set")
            subtitle("Soundcheck's speaker appears in the menu bar whenever something plays or a mic is in use (or always, with Keep in Menu Bar). Open Soundcheck anytime to see it.")
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .padding(.top, 10)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }
}

/// A symbol in a blue circle, a bold line and a note.
private struct Step: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A permission: what it's for, and Allow (Open Settings once it's been turned down, a spinner
/// while it's being checked, a tick once it's allowed).
private struct Permission: View {
    let symbol: String
    let title: String
    let text: String
    let allowed: Bool
    var denied = false
    var waiting = false
    let allow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if allowed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            } else if waiting {
                ProgressView().controlSize(.small)
            } else {
                Button(denied ? "Open Settings" : "Allow", action: allow)
                    .buttonStyle(AccentCapsuleButtonStyle())
                    .fixedSize()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

/// A capsule in the accent blue (the welcome window's buttons).
struct AccentCapsuleButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 28 : 14)
            .padding(.vertical, large ? 8 : 5)
            .background(Capsule().fill(Color.accentColor))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
