import AppKit
import Foundation

/// The native messaging helper for Chrome-based browsers (Dia, Chrome, Edge, Brave, Arc): the
/// browser starts Soundcheck's own executable, passing the extension's origin, and talks to it
/// over stdin and stdout (a 4-byte length, then JSON). It passes the extension's messages to
/// Soundcheck's port, with which browser they're from, and hands Soundcheck's replies and
/// requests back. No window or menu bar icon; it ends when the browser lets go of it.
enum BrowserHelper {
    /// Chrome starts native messaging helpers with the calling extension's origin.
    static func isLaunch(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("chrome-extension://") }
    }

    private static let output = FileHandle.standardOutput
    private static let outputLock = NSLock()

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let browser = browserBundleID()
        let helperPort = BrowserLink.helperPort(getpid())
        // Soundcheck sends its requests straight here.
        let server = BrowserPortServer(name: helperPort) { data in
            write(data)
            return nil
        }
        _ = server
        Thread.detachNewThread {
            while let message = readMessage() {
                let envelope: [String: Any] = [
                    "browser": browser,
                    "helperPort": helperPort,
                    "message": (try? JSONSerialization.jsonObject(with: message)) ?? [:],
                ]
                guard let body = try? JSONSerialization.data(withJSONObject: envelope),
                      let reply = BrowserLink.request(body, to: BrowserLink.appPort), !reply.isEmpty else { continue }
                write(reply)
            }
            exit(0) // the browser closed the connection
        }
        RunLoop.main.run()
        exit(0)
    }

    /// The browser that started this helper (its bundle ID).
    private static func browserBundleID() -> String {
        let parent = getppid()
        if let id = NSRunningApplication(processIdentifier: parent)?.bundleIdentifier { return id }
        if let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") {
            typealias Responsible = @convention(c) (pid_t) -> pid_t
            let owner = unsafeBitCast(symbol, to: Responsible.self)(parent)
            if let id = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier { return id }
        }
        return "chromium"
    }

    private static func readMessage() -> Data? {
        guard let header = readExactly(4) else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self) } // native byte order
        guard length > 0, length < 64 * 1024 * 1024 else { return length == 0 ? Data() : nil }
        return readExactly(Int(length))
    }

    private static func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
            if chunk.isEmpty { return nil }
            data.append(chunk)
        }
        return data
    }

    private static func write(_ message: Data) {
        outputLock.lock()
        defer { outputLock.unlock() }
        var length = UInt32(message.count)
        let header = Data(bytes: &length, count: 4)
        try? output.write(contentsOf: header + message)
    }
}
