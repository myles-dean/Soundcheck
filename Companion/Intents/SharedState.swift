import Foundation
import WidgetKit

/// What the widgets and Control Center controls show, shared with them through the app group:
/// the Mac's name, whether this device is playing as its speaker or its microphone, and what's
/// playing on the Mac.
enum SharedState {
    static let group = "group.com.mylesdean.Soundcheck.Companion"
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    /// "MacBook"
    static var macName: String {
        get { defaults.string(forKey: "macName") ?? "Mac" }
        set { set(newValue, "macName") }
    }

    static var macID: String? {
        get { defaults.string(forKey: "macID") }
        set { defaults.set(newValue, forKey: "macID") }
    }

    static var speakerOn: Bool {
        get { defaults.bool(forKey: "speakerOn") }
        set { set(newValue, "speakerOn") }
    }

    static var micOn: Bool {
        get { defaults.bool(forKey: "micOn") }
        set { set(newValue, "micOn") }
    }

    /// The apps playing on the Mac, by name.
    static var playing: [String] {
        get { defaults.stringArray(forKey: "playing") ?? [] }
        set { set(newValue, "playing") }
    }

    /// The Mac's tile (PNG), as on the lock screen.
    static var macTile: Data? {
        get { defaults.data(forKey: "macTile") }
        set { set(newValue, "macTile") }
    }

    private static func set<Value: Equatable>(_ value: Value, _ key: String) {
        if defaults.object(forKey: key) as? Value == value { return }
        defaults.set(value, forKey: key)
        reload()
    }

    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
