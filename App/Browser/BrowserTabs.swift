import AppKit
import Foundation
import Observation

/// Browser tabs, from Soundcheck's extensions in Dia, Chrome and Safari: which tabs are playing
/// or on a call (with their titles and icons), each tab's own level and mute, and lowering the
/// other tabs while one is on a call. A browser's tabs share one process, so Soundcheck can only
/// tell them apart (and set them) through the extension in the page.
@MainActor
@Observable
final class BrowserTabs {
    static let shared = BrowserTabs()

    struct Tab: Identifiable, Equatable {
        let id: Int
        var title: String
        var host: String
        var playing: Bool
        var call: Bool
        var muted: Bool
    }

    /// Each browser's tabs that are playing, on a call, played recently or have a level of their
    /// own (by the browser's bundle ID).
    private(set) var tabs: [String: [Tab]] = [:]
    /// Tab icons, by `key(browser, tab)`.
    private(set) var icons: [String: NSImage] = [:]
    /// Tabs' own levels (0...1; full when not set), by `key(browser, tab)`.
    private(set) var levels: [String: Float] = [:]
    /// Browsers whose extension has checked in lately.
    private(set) var connected: Set<String> = []
    /// Calls on or off in a tab (Quiet Apps in Calls follows them).
    @ObservationIgnored var onCallsChanged: (() -> Void)?

    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    @ObservationIgnored private var helperPorts: [String: String] = [:]
    @ObservationIgnored private var pending: [String: [[String: Any]]] = [:]
    @ObservationIgnored private var lastCommand: [String: Date] = [:]
    @ObservationIgnored private var hasState: Set<String> = []
    @ObservationIgnored private var server: BrowserPortServer?
    @ObservationIgnored private var sweep: Timer?
    /// Lowering for the tabs that aren't on the call, and what each tab was last sent.
    @ObservationIgnored private var duckGain: Float = 1
    @ObservationIgnored private var duckSeconds: Double = 0
    @ObservationIgnored private var sentDuck: [String: Float] = [:]

    private init() {}

    static func key(_ browser: String, _ tab: Int) -> String { "\(browser)#\(tab)" }

    /// Browsers with a tab on a call.
    var callBrowsers: Set<String> { Set(tabs.filter { $0.value.contains(where: \.call) }.map(\.key)) }

    func start() {
        guard server == nil else { return }
        server = BrowserPortServer(name: BrowserLink.appPort) { data in
            MainActor.assumeIsolated { BrowserTabs.shared.handle(data) }
        }
        if server == nil { log.error("Couldn't open the browser extensions' port") }
        let sweep = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { BrowserTabs.shared.forgetQuietBrowsers() }
        }
        RunLoop.main.add(sweep, forMode: .common)
        self.sweep = sweep
        DispatchQueue.global(qos: .utility).async {
            Self.installNativeHosts()
            Self.installExtensionFolder()
        }
    }

    // MARK: Messages from the extensions

    private func handle(_ data: Data) -> Data? {
        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let browser = envelope["browser"] as? String,
              let message = envelope["message"] as? [String: Any] else { return nil }
        lastSeen[browser] = Date()
        if !connected.contains(browser) { connected.insert(browser) }
        if let port = envelope["helperPort"] as? String { helperPorts[browser] = port }
        var resend = false
        if message["type"] as? String == "state", let list = message["tabs"] as? [[String: Any]] {
            update(browser, list)
            hasState.insert(browser)
        } else if !hasState.contains(browser) {
            resend = true // Soundcheck started after the browser: ask for everything, icons too
        }
        let recent = Date().timeIntervalSince(lastCommand[browser] ?? .distantPast) < 3
        let reply: [String: Any] = ["commands": pending.removeValue(forKey: browser) ?? [], "poll": recent ? 0.15 : 1.0, "resend": resend]
        return try? JSONSerialization.data(withJSONObject: reply)
    }

    private func update(_ browser: String, _ list: [[String: Any]]) {
        let callsBefore = callBrowsers
        var next: [Tab] = []
        for entry in list {
            guard let id = entry["id"] as? Int else { continue }
            let tab = Tab(id: id, title: entry["title"] as? String ?? "", host: entry["host"] as? String ?? "",
                          playing: entry["playing"] as? Bool ?? false, call: entry["call"] as? Bool ?? false,
                          muted: entry["muted"] as? Bool ?? false)
            next.append(tab)
            if let icon = entry["icon"] as? String, let image = Self.image(fromDataURL: icon) {
                icons[Self.key(browser, id)] = image
            }
        }
        if tabs[browser] != next {
            log.debug("Tabs from \(browser, privacy: .public): \(next.count), \(next.filter(\.call).count) on a call")
            tabs[browser] = next
        }
        let gone = Set(icons.keys.filter { $0.hasPrefix(browser + "#") }).subtracting(next.map { Self.key(browser, $0.id) })
        for key in gone { icons[key] = nil; levels[key] = nil; sentDuck[key] = nil }
        applyDucking()
        if callBrowsers != callsBefore { onCallsChanged?() }
    }

    private static func image(fromDataURL url: String) -> NSImage? {
        guard let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    /// A browser whose extension hasn't checked in for a while has closed (or lost its extension).
    private func forgetQuietBrowsers() {
        let callsBefore = callBrowsers
        for (browser, seen) in lastSeen where Date().timeIntervalSince(seen) > 12 {
            lastSeen[browser] = nil
            tabs[browser] = nil
            helperPorts[browser] = nil
            hasState.remove(browser)
            connected.remove(browser)
        }
        if callBrowsers != callsBefore { onCallsChanged?() }
    }

    // MARK: Requests to the extensions

    private func send(_ command: [String: Any], to browser: String) {
        lastCommand[browser] = Date()
        // A Chrome-based browser's helper takes it straight away; Safari picks it up when it checks in.
        if let port = helperPorts[browser],
           let body = try? JSONSerialization.data(withJSONObject: ["commands": [command], "poll": 0.15]),
           BrowserLink.post(body, to: port) {
            return
        }
        helperPorts[browser] = nil
        pending[browser, default: []].append(command)
    }

    func level(_ tab: Tab, in browser: String) -> Float { levels[Self.key(browser, tab.id)] ?? 1 }

    /// A tab's own level (taken like the app sliders: the gain is its cube).
    func setLevel(_ level: Float, for tab: Tab, in browser: String) {
        let level = min(max(level, 0), 1)
        levels[Self.key(browser, tab.id)] = level >= 0.999 ? nil : level
        send(["type": "level", "tab": tab.id, "gain": Double(level * level * level)], to: browser)
    }

    func setMuted(_ muted: Bool, for tab: Tab, in browser: String) {
        if let index = tabs[browser]?.firstIndex(where: { $0.id == tab.id }) { tabs[browser]?[index].muted = muted }
        send(["type": "mute", "tab": tab.id, "muted": muted], to: browser)
    }

    /// Quiet Apps in Calls: in a browser with a tab on a call, the other tabs go to `gain` (and
    /// back to full once it's over), fading over `seconds` in the page.
    func duckOtherTabs(gain: Float, seconds: Double) {
        duckGain = gain
        duckSeconds = seconds
        applyDucking()
    }

    private func applyDucking() {
        let calling = callBrowsers
        for (browser, list) in tabs {
            for tab in list {
                let key = Self.key(browser, tab.id)
                let wanted: Float = calling.contains(browser) && !tab.call ? duckGain : 1
                guard abs((sentDuck[key] ?? 1) - wanted) > 0.001 else { continue }
                sentDuck[key] = wanted
                send(["type": "duck", "tab": tab.id, "gain": Double(wanted), "seconds": duckSeconds], to: browser)
            }
        }
    }

    // MARK: Setting up the extensions

    /// Where Chrome-based browsers look for native messaging helpers (their user data folders).
    nonisolated static let chromiumFolders = [
        "Google/Chrome", "Chromium", "Microsoft Edge", "BraveSoftware/Brave-Browser", "Arc/User Data", "Dia", "Dia/User Data",
    ]

    /// Tells every Chrome-based browser here how to start Soundcheck's helper (and which
    /// extension may), so the extension can reach Soundcheck.
    nonisolated static func installNativeHosts() {
        guard let executable = Bundle.main.executablePath else { return }
        let manifest: [String: Any] = [
            "name": BrowserLink.nativeHost,
            "description": "Soundcheck",
            "path": executable,
            "type": "stdio",
            "allowed_origins": BrowserLink.chromiumExtensionIDs.map { "chrome-extension://\($0)/" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for folder in chromiumFolders {
            let base = support.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            let hosts = base.appendingPathComponent("NativeMessagingHosts")
            let file = hosts.appendingPathComponent(BrowserLink.nativeHost + ".json")
            guard (try? Data(contentsOf: file)) != data else { continue }
            try? FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }

    /// The Chrome extension's folder, for "Load unpacked": a copy outside the app, so it stays put
    /// when Soundcheck updates.
    nonisolated static var extensionFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soundcheck/Browser Extension")
    }

    nonisolated static func installExtensionFolder() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("Browser Extension"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: source.path) else { return }
        let destination = extensionFolder
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files {
            let from = source.appendingPathComponent(file), to = destination.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: from), (try? Data(contentsOf: to)) != data else { continue }
            try? data.write(to: to)
        }
    }
}
