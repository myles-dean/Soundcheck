import AppKit
import SwiftUI

/// Names and icons of apps by bundle ID, running or not.
@MainActor
enum AppLookup {
    static func name(_ id: String) -> String {
        if id == AudioApp.systemID { return "System" }
        if let app = AudioEngine.shared.apps.first(where: { $0.id == id }) { return app.name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ id: String) -> NSImage {
        if id == AudioApp.systemID { return AudioApp.systemIcon }
        if let app = AudioEngine.shared.apps.first(where: { $0.id == id }) { return app.icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Finder's open panel, in Applications, for picking apps; calls back with their bundle IDs.
    static func choose(title: String, prompt: String, _ picked: @escaping @MainActor ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            MainActor.assumeIsolated { picked(ids) }
        }
    }
}

/// The pinned apps (to unpin) and the ones making sound (to pin), plus Choose App… for any other.
struct PinnedAppsList: View {
    private var engine = AudioEngine.shared
    private let expand = Animation.easeInOut(duration: PanelController.animationDuration)

    var body: some View {
        let pinned = engine.pinnedApps.sorted { AppLookup.name($0).localizedCaseInsensitiveCompare(AppLookup.name($1)) == .orderedAscending }
        let playing = engine.playingApps.filter { !engine.pinnedApps.contains($0.id) }
        VStack(spacing: 2) {
            ForEach(pinned, id: \.self) { id in
                row(id: id, name: AppLookup.name(id), icon: AppLookup.icon(id))
            }
            ForEach(playing) { app in
                row(id: app.id, name: app.name, icon: app.icon)
            }
            HoverRow(action: {
                AppLookup.choose(title: "Pin an App", prompt: "Pin") { ids in
                    for id in ids where !engine.pinnedApps.contains(id) { engine.togglePin(id) }
                }
            }) {
                IconCircle(symbol: "plus", isOn: false, size: 22)
                Text("Choose App…").font(.system(size: 12))
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 12)
    }

    private func row(id: String, name: String, icon: NSImage) -> some View {
        let isOn = engine.pinnedApps.contains(id)
        return HoverRow(action: { withAnimation(expand) { engine.togglePin(id) } }) {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            Text(name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: isOn ? "pin.fill" : "pin")
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.7))
                .frame(width: 22)
        }
    }
}
