import AppKit
import Carbon.HIToolbox
import Observation

/// The keyboard shortcut that mutes and unmutes every microphone, set in Options. A system-wide
/// hot key (Carbon's, which needs no permission).
@MainActor
@Observable
final class MicMuteShortcut {
    static let shared = MicMuteShortcut()

    /// Like "⌃⌥M"; nil when there's no shortcut.
    private(set) var display: String?
    @ObservationIgnored var onPress: (() -> Void)?
    @ObservationIgnored private var keyCode: UInt32 = 0
    @ObservationIgnored private var modifiers: UInt32 = 0
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    private enum Keys {
        static let keyCode = "micMuteKeyCode"
        static let modifiers = "micMuteModifiers"
        static let display = "micMuteDisplay"
    }

    func start() {
        let defaults = UserDefaults.standard
        guard let display = defaults.string(forKey: Keys.display) else { return }
        keyCode = UInt32(defaults.integer(forKey: Keys.keyCode))
        modifiers = UInt32(defaults.integer(forKey: Keys.modifiers))
        self.display = display
        register()
    }

    /// From a key press while recording. Needs a modifier (⌘, ⌥ or ⌃), except for F-keys.
    @discardableResult
    func record(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = Self.functionKeys[Int(event.keyCode)] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return false }

        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon

        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += isFunctionKey ? Self.functionKeyName(event.keyCode) : (event.charactersIgnoringModifiers?.uppercased() ?? "?")
        display = text

        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Keys.keyCode)
        defaults.set(Int(modifiers), forKey: Keys.modifiers)
        defaults.set(text, forKey: Keys.display)
        register()
        return true
    }

    func clear() {
        unregister()
        display = nil
        for key in [Keys.keyCode, Keys.modifiers, Keys.display] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func register() {
        unregister()
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { MicMuteShortcut.shared.onPress?() } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5343_4D4D) /* 'SCMM' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    private static func functionKeyName(_ code: UInt16) -> String { functionKeys[Int(code)] ?? "?" }
}
