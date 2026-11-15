import AppKit
import SafariServices
import SwiftUI

/// The Browser Tabs window: turning on Soundcheck's extension in Safari, and adding it to Dia,
/// Chrome and other Chrome-based browsers, with whether each one is connected.
@MainActor
final class BrowserSetupWindowController: NSObject, NSWindowDelegate {
    static let shared = BrowserSetupWindowController()
    var onOpen: (() -> Void)?
    private var window: NSWindow?

    func show() {
        onOpen?()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: BrowserSetupView()))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.title = "Browser Tabs"
            window.setContentSize(NSSize(width: 520, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

private struct BrowserSetupView: View {
    private var tabs = BrowserTabs.shared
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text("With Soundcheck's extension, a browser's tabs show up under it in the Apps list, each with its own volume and mute. When a tab joins a call (Meet, Zoom, Teams, Discord…), Quiet Apps in Calls lowers the other tabs and apps too.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                status("Safari", "com.apple.Safari")
                Button("Turn On in Safari…") {
                    SFSafariApplication.showPreferencesForExtension(withIdentifier: BrowserLink.safariExtensionID) { _ in }
                }
            } header: {
                Text("Safari")
            } footer: {
                Text("Tick Soundcheck in Safari's Extensions settings, then allow it on every website, so it can see which tab is on a call.")
            }

            Section {
                status("Dia", "company.thebrowser.dia")
                status("Google Chrome", "com.google.Chrome")
                if let store = BrowserLink.storeURL {
                    // Listed in the Chrome Web Store: one click (Dia, Edge, Brave and Arc install from there too).
                    Button("Add to Chrome…") { NSWorkspace.shared.open(store) }
                    Text("Opens Soundcheck's page in the Chrome Web Store. In Dia or another browser, open the same page in it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Open the browser's extensions page (paste chrome://extensions into the address bar) and turn on Developer mode.")
                        Text("2. Click Load unpacked, and choose the Browser Extension folder.")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Show Extension Folder") {
                        BrowserTabs.installExtensionFolder()
                        NSWorkspace.shared.activateFileViewerSelecting([BrowserTabs.extensionFolder])
                    }
                    Button(copied ? "Copied" : "Copy chrome://extensions") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("chrome://extensions", forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                }
            } header: {
                Text("Dia, Chrome and other Chrome-based browsers")
            } footer: {
                Text("Works the same in Edge, Brave and Arc. Keep the folder where it is: the browser loads the extension from it.")
            }
        }
        .formStyle(.grouped)
    }

    private func status(_ name: String, _ id: String) -> some View {
        let on = tabs.connected.contains(id)
        return HStack {
            Text(name)
            Spacer()
            Circle().fill(on ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(on ? "Connected" : "Not connected").foregroundStyle(.secondary)
        }
    }
}
