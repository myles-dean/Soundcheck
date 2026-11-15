import AppKit
import ApplicationServices
import Observation

/// Takes over the volume up, down and mute keys, so they move every output at once (and the
/// outputs macOS can't set the volume of) and show Soundcheck's volume pill. Needs the
/// Accessibility permission; without it the keys keep working the way macOS handles them.
@MainActor
@Observable
final class VolumeKeys {
    static let shared = VolumeKeys()

    enum Key { case up, down, mute }
    /// `fine` is true with Option-Shift held: quarter steps, like macOS.
    @ObservationIgnored var onKey: ((Key, _ fine: Bool) -> Void)?

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private(set) var isActive = false
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Starts listening if macOS allows it; otherwise checks back every couple of seconds (for
    /// when the permission is granted in System Settings).
    func start() {
        guard tap == nil else { return }
        if AXIsProcessTrusted(), install() { return }
        guard trustTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.install() else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    /// Shows macOS's Accessibility prompt (which links to System Settings).
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { start() }
    }

    private func install() -> Bool {
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED: media and volume keys
        // At the HID level: on macOS 26 the system acts on the volume keys before a session-level
        // tap sees them.
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: volumeKeyCallback, userInfo: nil)
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        isActive = true
        // Taps can come back from sleep switched off.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VolumeKeys.shared.reenable() }
        }
        return true
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

/// Runs on the main run loop. Volume and mute key presses are handled and swallowed (both the
/// press and the release); everything else passes through untouched.
private func volumeKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { VolumeKeys.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let code = (nsEvent.data1 & 0xFFFF_0000) >> 16
    let isDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0xA
    // Which media keys arrive (a keyboard's own keys, or a volume knob), for
    // `log show --info --predicate 'subsystem == "com.mylesdean.Soundcheck"'`.
    log.info("Media key \(code, privacy: .public) \(isDown ? "down" : "up", privacy: .public) flags \(nsEvent.data1 & 0xFFFF, privacy: .public)")
    let key: VolumeKeys.Key
    switch code { // NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE
    case 0: key = .up
    case 1: key = .down
    case 7: key = .mute
    default: return Unmanaged.passUnretained(event)
    }
    if isDown {
        let fine = nsEvent.modifierFlags.contains([.option, .shift])
        MainActor.assumeIsolated { VolumeKeys.shared.onKey?(key, fine) }
    }
    return nil
}
