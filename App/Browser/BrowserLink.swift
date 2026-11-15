import CoreFoundation
import Foundation

/// How Soundcheck and its browser extensions reach each other on this Mac: named Core Foundation
/// message ports. Their names start with Soundcheck's app group, which lets the sandboxed Safari
/// extension use them. Used by the app, its native messaging helper (for Chrome-based browsers)
/// and the Safari extension.
enum BrowserLink {
    static let group = "3N7MVP4K42.com.mylesdean.Soundcheck"
    /// Soundcheck's own port: extensions send their tabs here and get Soundcheck's requests back.
    static let appPort = group + ".browser"
    /// A native messaging helper's port, where Soundcheck sends requests the moment it has them.
    static func helperPort(_ pid: pid_t) -> String { group + ".helper.\(pid)" }
    /// Chrome's native messaging name for Soundcheck, and the extension it lets in.
    static let nativeHost = "com.mylesdean.soundcheck"
    /// The extension loaded with Load unpacked (its manifest's "key" fixes this ID).
    static let chromiumExtensionID = "hbgopkcdlnelkfdgnilgbmdlnmmhbiik"
    /// The Chrome Web Store's copy, once it's listed (the store gives it its own ID); nil until then.
    static let storeExtensionID: String? = nil
    /// Every copy of the extension Soundcheck's helper lets in.
    static var chromiumExtensionIDs: [String] { [chromiumExtensionID] + (storeExtensionID.map { [$0] } ?? []) }
    /// The extension's page in the Chrome Web Store, once it's listed.
    static var storeURL: URL? { storeExtensionID.flatMap { URL(string: "https://chromewebstore.google.com/detail/\($0)") } }
    static let safariExtensionID = "com.mylesdean.Soundcheck.Safari"

    /// Sends `data` to a named port and returns its reply; nil when nothing's listening there.
    static func request(_ data: Data, to name: String, timeout: TimeInterval = 1) -> Data? {
        guard let port = CFMessagePortCreateRemote(nil, name as CFString) else { return nil }
        defer { CFMessagePortInvalidate(port) }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, data as CFData, timeout, timeout, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess else { return nil }
        return reply?.takeRetainedValue() as Data? ?? Data()
    }

    /// Sends `data` without waiting for a reply. False when nothing's listening there.
    @discardableResult
    static func post(_ data: Data, to name: String) -> Bool {
        guard let port = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
        defer { CFMessagePortInvalidate(port) }
        return CFMessagePortSendRequest(port, 0, data as CFData, 1, 0, nil, nil) == kCFMessagePortSuccess
    }
}

/// A named port that answers requests on the main run loop.
final class BrowserPortServer {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    fileprivate let handler: (Data) -> Data?

    init?(name: String, handler: @escaping (Data) -> Data?) {
        self.handler = handler
        var context = CFMessagePortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        var shouldFree: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, { _, _, data, info in
            guard let info else { return nil }
            let server = Unmanaged<BrowserPortServer>.fromOpaque(info).takeUnretainedValue()
            guard let reply = server.handler((data as Data?) ?? Data()) else { return nil }
            return Unmanaged.passRetained(reply as CFData)
        }, &context, &shouldFree) else { return nil }
        self.port = port
        source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit { invalidate() }

    func invalidate() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        source = nil
    }
}
