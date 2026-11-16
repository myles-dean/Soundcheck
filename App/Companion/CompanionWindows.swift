import AppKit
import SwiftUI

/// "Allow “Myles's iPhone” to control Soundcheck?", the first time a companion connects. A small
/// floating window rather than an alert, so the menu bar and the sound keep working meanwhile.
@MainActor
final class CompanionPairingPrompt: NSObject, NSWindowDelegate {
    static let shared = CompanionPairingPrompt()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
                                 styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.level = .floating
            // Soundcheck lives in the menu bar and is rarely the active app (macOS won't make it
            // so by itself), and panels hide while their app isn't: this one mustn't.
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.delegate = self
            window.contentView = NSHostingView(rootView: PairingPromptView())
            window.center()
            self.window = window
        }
        window?.center()
        window?.orderFrontRegardless()
        NSApp.activate()
        window?.makeKey()
    }

    func close() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if CompanionHub.shared.request != nil { CompanionHub.shared.answerPairing(false) }
    }
}

private struct PairingPromptView: View {
    private var hub: CompanionHub { .shared }

    var body: some View {
        VStack(spacing: 12) {
            if let request = hub.request {
                Image(systemName: request.kind == "iPad" ? "ipad" : "iphone")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Allow “\(request.name)” to control Soundcheck?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Check that your \(request.kind) shows the same code:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(request.code)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                HStack {
                    Button("Don't Allow") {
                        hub.answerPairing(false)
                        CompanionPairingPrompt.shared.close()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Allow") {
                        hub.answerPairing(true)
                        CompanionPairingPrompt.shared.close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            } else {
                Text("No one's asking to connect.").foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

/// Options › Soundcheck › iPhone & iPad: the companions paired with this Mac.
@MainActor
final class CompanionsWindowController: NSObject, NSWindowDelegate {
    static let shared = CompanionsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "iPhone & iPad"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: CompanionsView())
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct CompanionsView: View {
    private var hub: CompanionHub { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Control Soundcheck from your iPhone or iPad, play your Mac's sound on it, or use it as a microphone, with the Soundcheck Companion app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hub.devices.isEmpty {
                Text("Open Soundcheck Companion on an iPhone or iPad on the same Wi-Fi. The first time, you'll be asked here to allow it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(hub.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: device.symbol)
                                .font(.system(size: 18))
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                Text(hub.connected.contains(device.id) ? "Connected" : "Last seen \(device.lastSeen.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") { hub.forget(device.id) }
                        }
                        .padding(.vertical, 8)
                        if device.id != hub.devices.last?.id { Divider() }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Waking a companion that's in the background (to play on it, use its microphone, or keep the sound down while you're on a call on your iPhone) uses Bluetooth, so macOS asks to allow that the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420, height: 360, alignment: .topLeading)
    }
}
