import AppKit
import CoreAudio

/// An app that plays or records sound. Browsers and Electron apps play from helper processes;
/// those count as the app that started them.
struct AudioApp: Identifiable, Equatable {
    let id: String // bundle ID
    let pid: pid_t
    let name: String
    let objects: [AudioObjectID]
    let isPlaying: Bool
    let isListening: Bool

    /// macOS's own sounds, shown as one app called System (see ProcessMonitor.systemProcesses).
    static let systemID = "com.mylesdean.Soundcheck.system"
    var isSystem: Bool { id == Self.systemID }

    /// Looked up once per app: a new image on every redraw makes rows flicker.
    @MainActor var icon: NSImage {
        if let icon = Self.icons[id] { return icon }
        if isSystem {
            let icon = Self.systemIcon
            Self.icons[id] = icon
            return icon
        }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        Self.icons[id] = icon
        return icon
    }
    @MainActor private static var icons: [String: NSImage] = [:]

    /// System's icon: this Mac (a laptop, an iMac, a Mac mini…) on a grey app-shaped tile, the
    /// size and shape of other apps' icons (System Settings' gear would look like that app).
    @MainActor static let systemIcon: NSImage = {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size, flipped: false) { rect in
            // macOS's icon grid: the tile is 824/1024 of the canvas, centred, with continuous
            // corners (a superellipse).
            let side = rect.width * 824 / 1024
            let tile = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            let shape = NSBezierPath()
            let steps = 96
            for step in 0...steps {
                let angle = Double(step) / Double(steps) * 2 * .pi
                let c = cos(angle), s = sin(angle)
                let x = tile.midX + tile.width / 2 * CGFloat(copysign(pow(abs(c), 2 / 5), c))
                let y = tile.midY + tile.height / 2 * CGFloat(copysign(pow(abs(s), 2 / 5), s))
                if step == 0 { shape.move(to: NSPoint(x: x, y: y)) } else { shape.line(to: NSPoint(x: x, y: y)) }
            }
            shape.close()
            NSGradient(starting: NSColor(white: 0.66, alpha: 1), ending: NSColor(white: 0.46, alpha: 1))?.draw(in: shape, angle: -90)
            NSColor(white: 0, alpha: 0.12).setStroke()
            shape.lineWidth = 0.75
            shape.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
            if let symbol = NSImage(systemSymbolName: AudioDevice.macSymbol, accessibilityDescription: "System")?
                .withSymbolConfiguration(config) {
                let glyph = NSImage(size: symbol.size, flipped: false) { glyphRect in
                    symbol.draw(in: glyphRect)
                    NSColor.white.set()
                    glyphRect.fill(using: .sourceAtop)
                    return true
                }
                glyph.draw(in: NSRect(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2,
                                      width: symbol.size.width, height: symbol.size.height))
            }
            return true
        }
        return image
    }()

    /// A pinned app that isn't open or making sound yet, so it can still be set up: its volume
    /// and mute apply as soon as it plays.
    @MainActor static func pinned(_ id: String) -> AudioApp {
        if let app = placeholders[id] { return app }
        let name = id == systemID ? "System" : NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        let app = AudioApp(id: id, pid: 0, name: name, objects: [], isPlaying: false, isListening: false)
        placeholders[id] = app
        return app
    }
    @MainActor private static var placeholders: [String: AudioApp] = [:]
}

/// Watches Core Audio's list of processes: which apps are playing, which are listening to a
/// microphone, and which process objects belong to each (for taps).
@MainActor
final class ProcessMonitor {
    private(set) var apps: [AudioApp] = []
    /// Every audio process object that isn't Soundcheck, playing or not (for the global tap's
    /// "is anything playing" check).
    private(set) var anyProcessPlaying = false
    /// A call is ringing: the Mac's call service (FaceTime, and iPhone calls through Continuity) is
    /// playing its ringtone. Seen even when Soundcheck has System muted, since the service still
    /// plays into Soundcheck's tap.
    private(set) var isRinging = false
    static let callService = "com.apple.TelephonyUtilities"
    private(set) var ownProcessObject = AudioObjectID.unknown
    var onChange: (() -> Void)?
    /// After every check, changed or not.
    var onTick: (() -> Void)?

    private var listener: HALListener?
    private var timer: Timer?
    private var nameCache: [pid_t: (bundleID: String, name: String)] = [:]
    /// Each process object's bundle ID (or its name, for a daemon), read once.
    private var processBundles: [AudioObjectID: String] = [:]

    /// The processes that play macOS's own sounds, all shown as one app, System: alerts, UI sound
    /// effects and notification sounds (systemsoundserverd), the charging chime, Control Center's
    /// volume click, ringtones for calls, and the login window.
    static let systemProcesses: Set<String> = [
        "systemsoundserverd", "com.apple.PowerChime", "com.apple.controlcenter",
        "com.apple.TelephonyUtilities", "com.apple.loginwindow",
    ]

    func start() {
        listener = HALListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.nameCache.removeAll() // process IDs get reused
            self?.processBundles.removeAll()
            self?.refresh()
        }
        // Whether a process is playing isn't announced (on macOS 26 the per-process flags change
        // without notifications), so it's checked twice a second; reading a few dozen flags is cheap.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        let ownPID = getpid()
        struct Group { var pid: pid_t; var bundleID: String; var name: String; var objects: [AudioObjectID] = []; var playing = false; var listening = false }
        var groups: [String: Group] = [:]
        var anyPlaying = false
        var ringing = false
        let previousOwn = ownProcessObject

        for object in HAL.array(.system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID.unknown) {
            guard let pid = HAL.read(object, kAudioProcessPropertyPID, initial: pid_t(0)) else { continue }
            if pid == ownPID { ownProcessObject = object; continue }
            let playing = (HAL.read(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            let listening = (HAL.read(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0) != 0
            anyPlaying = anyPlaying || playing

            // macOS's own sounds: one app, System.
            let bundle = processBundles[object] ?? HAL.string(object, kAudioProcessPropertyBundleID) ?? ""
            processBundles[object] = bundle
            if bundle == Self.callService && playing { ringing = true }
            if Self.systemProcesses.contains(bundle) {
                var group = groups[AudioApp.systemID] ?? Group(pid: pid, bundleID: AudioApp.systemID, name: "System")
                group.objects.append(object)
                group.playing = group.playing || playing
                group.listening = group.listening || listening
                groups[AudioApp.systemID] = group
                continue
            }

            // Helpers answer to the app you know (a browser tab's sound belongs to the browser).
            let owner = Self.responsiblePID(for: pid)
            guard owner != ownPID, let app = appInfo(owner) ?? appInfo(pid) else { continue }
            var group = groups[app.bundleID] ?? Group(pid: owner, bundleID: app.bundleID, name: app.name)
            group.objects.append(object)
            group.playing = group.playing || playing
            group.listening = group.listening || listening
            groups[app.bundleID] = group
        }

        let next = groups.values
            .map { AudioApp(id: $0.bundleID, pid: $0.pid, name: $0.name, objects: $0.objects.sorted(), isPlaying: $0.playing, isListening: $0.listening) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if next != apps || anyPlaying != anyProcessPlaying || ownProcessObject != previousOwn || ringing != isRinging {
            apps = next
            anyProcessPlaying = anyPlaying
            isRinging = ringing
            onChange?()
        }
        onTick?()
    }

    /// Only processes Launch Services knows as apps (with a bundle ID) are shown; daemons such as
    /// Siri's listener stay out, like they do from macOS's own microphone indicator.
    private func appInfo(_ pid: pid_t) -> (bundleID: String, name: String)? {
        if let cached = nameCache[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier else { return nil }
        let info = (bundleID, app.localizedName ?? bundleID)
        nameCache[pid] = info
        return info
    }

    // MARK: Responsible process

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` maps a helper to the app that launched it (the
    /// same attribution privacy prompts use). It isn't in a public header but has been stable for
    /// years; without it, helpers just show as themselves.
    private static let responsiblePIDFunction: ResponsiblePID? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let function = responsiblePIDFunction else { return pid }
        let owner = function(pid)
        return owner > 0 ? owner : pid
    }
}
