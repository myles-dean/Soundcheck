import Foundation

/// macOS's "System Audio Recording" permission, which process taps need. Without it a tap
/// still mutes the app it taps but hands Soundcheck silence, so Soundcheck checks first and only
/// taps once it's allowed.
///
/// There's no public API to ask, so this uses the TCC framework's own preflight and request
/// calls (private but long-standing, and what other open-source tap apps use). If they're ever
/// missing, Soundcheck behaves as if allowed and macOS asks on the first tap.
enum AudioCapturePermission {
    enum Status { case allowed, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .allowed }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows macOS's prompt (only when it hasn't been answered yet).
    static func request(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            Task { @MainActor in done(true) }
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            Task { @MainActor in done(granted) }
        }
    }
}
