// AirPlay audio sender for Soundcheck.
//
// Errors, logging and byte helpers shared by the AirPlay files. The protocol logic in this folder
// is a Swift port of pyatv's AirPlay/RAOP sender: https://github.com/postlund/pyatv
// (MIT License, © Pierre Ståhl).

import Foundation
import os

/// Why an AirPlay session couldn't start or stopped.
enum AirPlayError: LocalizedError, Sendable {
    case connectionFailed(String)
    case timedOut(String)
    case disconnected(String)
    case protocolError(String)
    case httpError(code: Int, message: String)
    case authenticationFailed(String)
    /// The speaker asks for a one-time code (shown on its screen) and no `requestPIN` handler was
    /// set, or the stored pairing stopped working.
    case pairingRequired(String)
    case pairingCancelled
    case unsupported(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail): "Couldn't connect to the speaker: \(detail)"
        case .timedOut(let detail): "The speaker didn't answer (\(detail))."
        case .disconnected(let detail): "The speaker disconnected: \(detail)"
        case .protocolError(let detail): "AirPlay error: \(detail)"
        case .httpError(let code, let message): "The speaker refused the request (\(code) \(message))."
        case .authenticationFailed(let detail): "The speaker didn't accept Soundcheck: \(detail)"
        case .pairingRequired(let detail): "The speaker needs to be paired: \(detail)"
        case .pairingCancelled: "Pairing was cancelled."
        case .unsupported(let detail): "This speaker isn't supported: \(detail)"
        case .cancelled: "Stopped."
        }
    }
}

/// Logging for the AirPlay code: os_log always, plus an optional handler (the test tool prints).
enum AirPlayLog {
    static let logger = Logger(subsystem: "com.mylesdean.Soundcheck", category: "AirPlay")
    /// Receives every debug line as well (set it before starting sessions).
    nonisolated(unsafe) static var handler: (@Sendable (String) -> Void)?

    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
        handler?(text)
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        handler?(text)
    }
}

/// A once-only flag that's safe to use from any thread.
final class AirPlayOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Returns true the first time only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, count >= offset + size else { return nil }
        var value: T = 0
        for byte in self[(startIndex + offset)..<(startIndex + offset + size)] {
            value = value << 8 | T(byte)
        }
        return value
    }
}
