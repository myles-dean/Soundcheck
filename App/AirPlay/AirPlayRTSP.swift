// AirPlay audio sender for Soundcheck.
//
// RTSP/HTTP over TCP to the speaker, optionally HAP-encrypted, and the AirPlay 2 event channel.
// Ported from pyatv (pyatv/support/rtsp.py, support/http.py, auth/hap_channel.py,
// protocols/airplay/channels.py): https://github.com/postlund/pyatv, MIT License, © Pierre Ståhl.

import Foundation
import Network

// MARK: - Messages

struct AirPlayHTTPMessage: Sendable {
    /// "RTSP/1.0 200 OK" or "POST /command RTSP/1.0".
    let firstLine: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// For responses: the status code (0 if this isn't a response).
    var code: Int {
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].contains("/") else { return 0 }
        return Int(parts[1]) ?? 0
    }

    var reason: String {
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        return parts.count == 3 ? String(parts[2]) : ""
    }

    /// The body as a binary (or XML) property list dictionary.
    var plist: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
    }

    /// pyatv's _format_message.
    static func format(_ firstLine: String, userAgent: String?, contentType: String?,
                       headers: [(String, String)], body: Data?) -> Data {
        var lines = [firstLine]
        if let userAgent, !headers.contains(where: { $0.0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            lines.append("User-Agent: \(userAgent)")
        }
        if let contentType { lines.append("Content-Type: \(contentType)") }
        if let body, !body.isEmpty { lines.append("Content-Length: \(body.count)") }
        for (name, value) in headers { lines.append("\(name): \(value)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { data.append(body) }
        return data
    }

    /// Takes one complete message off the front of `buffer`, or returns nil if it isn't all there.
    static func parse(_ buffer: inout Data) throws -> AirPlayHTTPMessage? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 65_536 { throw AirPlayError.protocolError("oversized message header") }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<separator.lowerBound], encoding: .utf8) else {
            throw AirPlayError.protocolError("message header isn't text")
        }
        let lines = head.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.range(of: ":") else { continue }
            let name = line[line.startIndex..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])
        return AirPlayHTTPMessage(firstLine: lines.first ?? "", headers: headers, body: body)
    }
}

// MARK: - TCP

/// An NWConnection with a connect timeout, a receive loop and a single close notification.
/// Everything runs on `queue`.
final class AirPlayTCPLink: @unchecked Sendable {
    let queue: DispatchQueue
    private let connection: NWConnection
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var connectTimeout: DispatchWorkItem?
    private var isOpen = false
    private var isClosed = false
    /// Called on `queue` with each chunk received.
    var onData: ((Data) -> Void)?
    /// Called on `queue` once if the connection fails or the speaker closes it (not after close()).
    var onClose: ((AirPlayError) -> Void)?

    init(host: NWEndpoint.Host, port: UInt16, ipv4Only: Bool, queue: DispatchQueue) {
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if ipv4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port) ?? .any, using: parameters)
    }

    var localHost: NWEndpoint.Host? {
        if case .hostPort(let host, _) = connection.currentPath?.localEndpoint { return host }
        return nil
    }

    var remoteHost: NWEndpoint.Host? {
        if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint { return host }
        return nil
    }

    func connect(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { self.beginConnect(continuation, timeout: timeout) }
        }
    }

    private func beginConnect(_ continuation: CheckedContinuation<Void, Error>, timeout: TimeInterval) {
        connectWaiter = continuation
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        let work = DispatchWorkItem { [weak self] in self?.finishConnect(.timedOut("connecting")) }
        connectTimeout = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
        connection.start(queue: queue)
    }

    private func finishConnect(_ error: AirPlayError?) {
        connectTimeout?.cancel()
        connectTimeout = nil
        guard let waiter = connectWaiter else { return }
        connectWaiter = nil
        if let error {
            isClosed = true
            connection.cancel()
            waiter.resume(throwing: error)
        } else {
            isOpen = true
            waiter.resume()
            receive()
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finishConnect(nil)
        case .waiting(let error), .failed(let error):
            if connectWaiter != nil {
                finishConnect(.connectionFailed(Self.describe(error)))
            } else {
                closeUnexpectedly(.disconnected(Self.describe(error)))
            }
        default:
            break
        }
    }

    static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return "connection refused"
            case .ETIMEDOUT: return "timed out"
            case .EHOSTUNREACH, .ENETUNREACH: return "not reachable"
            case .ECONNRESET: return "connection reset"
            default: break
            }
        }
        return error.debugDescription
    }

    static func isRefused(_ error: Error) -> Bool {
        if case AirPlayError.connectionFailed(let detail) = error { return detail == "connection refused" }
        return false
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty { self.onData?(data) }
            if let error {
                self.closeUnexpectedly(.disconnected(Self.describe(error)))
            } else if isComplete {
                self.closeUnexpectedly(.disconnected("the speaker closed the connection"))
            } else if !self.isClosed {
                self.receive()
            }
        }
    }

    /// Must be called on `queue`.
    func send(_ data: Data) {
        guard isOpen, !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.closeUnexpectedly(.disconnected(Self.describe(error))) }
        })
    }

    /// Must be called on `queue`.
    func closeUnexpectedly(_ error: AirPlayError) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        let handler = onClose
        onClose = nil
        onData = nil
        handler?(error)
    }

    /// Safe from any thread; no onClose.
    func close() {
        queue.async {
            self.onClose = nil
            self.onData = nil
            if !self.isClosed {
                self.isClosed = true
                self.connection.cancel()
            }
            self.finishConnect(.cancelled)
        }
    }
}

extension NWEndpoint.Host {
    /// The address as text, without an IPv6 scope.
    var addressString: String {
        switch self {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address):
            let text = "\(address)"
            return text.split(separator: "%").first.map(String.init) ?? text
        case .name(let name, _): return name
        @unknown default: return "\(self)"
        }
    }
}

// MARK: - RTSP

/// pyatv's HttpConnection + RtspSession: requests go out in order and responses are matched
/// first-in, first-out. A request that times out closes the connection (a late response would
/// otherwise be taken as the answer to the next one).
final class AirPlayRTSPConnection: @unchecked Sendable {
    /// What macOS 26.5 sends; HomePods answer 403 to `GET /info` below AirPlay/300 (tuxplay).
    static let rtspUserAgent = "AirPlay/950.7.1"
    static let defaultTimeout: TimeInterval = 10

    let queue: DispatchQueue
    private let link: AirPlayTCPLink
    private var hap: HAPSession?
    private var buffer = Data()
    private var pending: [Pending] = []
    private var failure: AirPlayError?
    private let lock = NSLock()
    private var cseq = 0
    private var closeHandler: (@Sendable (AirPlayError) -> Void)?

    /// Random per connection, as in pyatv's RtspSession.
    let sessionID = UInt32.random(in: .min ... .max)
    let dacpID = String(format: "%llX", UInt64.random(in: .min ... .max))
    let activeRemote = UInt32.random(in: .min ... .max)
    private(set) var localIP = ""
    private(set) var remoteIP = ""
    private(set) var remoteHost: NWEndpoint.Host = .ipv4(.loopback)

    /// rtsp://<local ip>/<session id>
    var uri: String { "rtsp://\(localIP)/\(sessionID)" }

    private final class Pending {
        let label: String
        let continuation: CheckedContinuation<AirPlayHTTPMessage, Error>
        var timeout: DispatchWorkItem?
        init(label: String, continuation: CheckedContinuation<AirPlayHTTPMessage, Error>) {
            self.label = label
            self.continuation = continuation
        }
    }

    /// Called once (on an arbitrary queue) if the connection drops after connecting.
    var onClose: (@Sendable (AirPlayError) -> Void)? {
        get { lock.withLock { closeHandler } }
        set { lock.withLock { closeHandler = newValue } }
    }

    private init(link: AirPlayTCPLink) {
        self.link = link
        queue = link.queue
    }

    /// Connects over IPv4 if the speaker has an IPv4 address, otherwise over whatever works.
    static func connect(host: String, port: UInt16, timeout: TimeInterval = 20) async throws -> AirPlayRTSPConnection {
        do {
            return try await connect(host: host, port: port, ipv4Only: true, timeout: timeout)
        } catch AirPlayError.timedOut(let detail) {
            throw AirPlayError.timedOut(detail)
        } catch {
            AirPlayLog.debug("IPv4 connection to \(host) failed (\(error.localizedDescription)), trying any address")
            return try await connect(host: host, port: port, ipv4Only: false, timeout: timeout)
        }
    }

    private static func connect(host: String, port: UInt16, ipv4Only: Bool, timeout: TimeInterval) async throws -> AirPlayRTSPConnection {
        let queue = DispatchQueue(label: "AirPlay RTSP \(host)", qos: .userInitiated)
        let link = AirPlayTCPLink(host: NWEndpoint.Host(host), port: port, ipv4Only: ipv4Only, queue: queue)
        let rtsp = AirPlayRTSPConnection(link: link)
        // Set before connecting so nothing that arrives early is missed.
        link.onData = { [weak rtsp] data in rtsp?.received(data) }
        link.onClose = { [weak rtsp] error in rtsp?.fail(error, notify: true) }
        try await link.connect(timeout: timeout)
        queue.sync {
            rtsp.localIP = link.localHost?.addressString ?? "0.0.0.0"
            rtsp.remoteHost = link.remoteHost ?? NWEndpoint.Host(host)
            rtsp.remoteIP = rtsp.remoteHost.addressString
        }
        AirPlayLog.debug("Connected to \(host) (\(rtsp.remoteIP):\(port)) from \(rtsp.localIP)")
        return rtsp
    }

    /// Encrypts everything from now on (HAP framing), after a successful pair-verify.
    func enableEncryption(outputKey: Data, inputKey: Data) {
        queue.sync { hap = HAPSession(outputKey: outputKey, inputKey: inputKey) }
    }

    func close() {
        queue.async { self.fail(.cancelled, notify: false) }
        link.close()
    }

    /// Must be called on `queue`.
    private func fail(_ error: AirPlayError, notify: Bool) {
        guard failure == nil else { return }
        failure = error
        let waiting = pending
        pending.removeAll()
        for request in waiting {
            request.timeout?.cancel()
            request.continuation.resume(throwing: error)
        }
        if notify, let handler = onClose {
            onClose = nil
            AirPlayLog.debug("RTSP connection to \(remoteIP) lost: \(error.localizedDescription)")
            handler(error)
        }
        link.close()
    }

    private func received(_ data: Data) {
        do {
            if let hap { buffer.append(try hap.decrypt(data)) } else { buffer.append(data) }
            while let message = try AirPlayHTTPMessage.parse(&buffer) {
                guard !pending.isEmpty else {
                    AirPlayLog.debug("Response without a request: \(message.firstLine)")
                    continue
                }
                let request = pending.removeFirst()
                request.timeout?.cancel()
                request.continuation.resume(returning: message)
            }
        } catch {
            fail(.protocolError("bad data from the speaker: \(error.localizedDescription)"), notify: true)
        }
    }

    /// Sends a raw message and waits for the next response.
    func send(_ message: Data, label: String, timeout: TimeInterval = defaultTimeout) async throws -> AirPlayHTTPMessage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AirPlayHTTPMessage, Error>) in
            queue.async { self.enqueue(message, label: label, timeout: timeout, continuation: continuation) }
        }
    }

    /// On `queue`: encrypts and sends a request, and waits for its response.
    private func enqueue(_ message: Data, label: String, timeout: TimeInterval,
                         continuation: CheckedContinuation<AirPlayHTTPMessage, Error>) {
        if let failure {
            continuation.resume(throwing: failure)
            return
        }
        let payload: Data
        do {
            payload = try hap?.encrypt(message) ?? message
        } catch {
            continuation.resume(throwing: AirPlayError.protocolError("encryption failed"))
            return
        }
        let request = Pending(label: label, continuation: continuation)
        let work = DispatchWorkItem { [weak self] in self?.fail(.timedOut(label), notify: true) }
        request.timeout = work
        pending.append(request)
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
        link.send(payload)
    }

    /// pyatv's HttpConnection.send_and_receive status handling.
    private static func check(_ response: AirPlayHTTPMessage, label: String, allowError: Bool) throws -> AirPlayHTTPMessage {
        let code = response.code
        if code == 403 { throw AirPlayError.authenticationFailed("\(label): 403 \(response.reason)") }
        if code == 401 {
            if allowError { return response }
            throw AirPlayError.authenticationFailed("\(label): 401 \(response.reason)")
        }
        if (200..<300).contains(code) || allowError { return response }
        if code == 470 { throw AirPlayError.authenticationFailed("\(label): 470 \(response.reason)") }
        throw AirPlayError.httpError(code: code, message: "\(label): \(response.reason)")
    }

    /// pyatv's HttpConnection.post (plain HTTP/1.1, no RTSP headers): used for pairing.
    func post(_ path: String, headers: [(String, String)], body: Data? = nil, allowError: Bool = false,
              timeout: TimeInterval = defaultTimeout) async throws -> AirPlayHTTPMessage {
        let message = AirPlayHTTPMessage.format("POST \(path) HTTP/1.1", userAgent: "Soundcheck",
                                                contentType: nil, headers: headers, body: body)
        let label = "POST \(path)"
        let response = try await send(message, label: label, timeout: timeout)
        AirPlayLog.debug("\(label) → \(response.firstLine)")
        return try Self.check(response, label: label, allowError: allowError)
    }

    /// pyatv's RtspSession.exchange. A `plist` body is sent as a binary property list.
    func exchange(_ method: String, uri: String? = nil, contentType: String? = nil,
                  headers extra: [(String, String)] = [], body: Data? = nil, plist: [String: Any]? = nil,
                  allowError: Bool = false, protocolName: String = "RTSP/1.0",
                  timeout: TimeInterval = defaultTimeout) async throws -> AirPlayHTTPMessage {
        let sequence = lock.withLock { () -> Int in
            defer { cseq += 1 }
            return cseq
        }
        var headers: [(String, String)] = [
            ("CSeq", "\(sequence)"),
            ("DACP-ID", dacpID),
            ("Active-Remote", "\(activeRemote)"),
            ("Client-Instance", dacpID),
        ]
        func set(_ name: String, _ value: String) {
            if let index = headers.firstIndex(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) {
                headers[index].1 = value
            } else {
                headers.append((name, value))
            }
        }
        for (name, value) in extra { set(name, value) }
        var payload = body
        if let plist {
            set("Content-Type", "application/x-apple-binary-plist")
            payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        let target = uri ?? self.uri
        let message = AirPlayHTTPMessage.format("\(method) \(target) \(protocolName)", userAgent: Self.rtspUserAgent,
                                                contentType: contentType, headers: headers, body: payload)
        let label = "\(method) \(uri ?? "")".trimmingCharacters(in: .whitespaces)
        let response = try await send(message, label: label, timeout: timeout)
        if method != "POST" || uri != "/feedback" {
            AirPlayLog.debug("\(label) → \(response.firstLine)")
        }
        return try Self.check(response, label: label, allowError: allowError)
    }
}

// MARK: - Event channel

/// The AirPlay 2 event channel (pyatv's EventChannel): the speaker connects requests to us over a
/// HAP-encrypted TCP connection and we answer each with 200 OK.
final class AirPlayEventChannel: @unchecked Sendable {
    private let link: AirPlayTCPLink
    private let hap: HAPSession
    private var buffer = Data()
    /// The speaker's own volume changed (0...1): its buttons, Siri, an iPhone or the Home app.
    /// Called on the channel's queue.
    var onVolume: (@Sendable (Float) -> Void)?

    private init(link: AirPlayTCPLink, outputKey: Data, inputKey: Data) {
        self.link = link
        hap = HAPSession(outputKey: outputKey, inputKey: inputKey)
    }

    /// Retries a refused connection a few times, as pyatv does (some receivers open the port a
    /// moment after announcing it).
    static func connect(host: NWEndpoint.Host, port: UInt16, outputKey: Data, inputKey: Data,
                        queue: DispatchQueue) async throws -> AirPlayEventChannel {
        var attempts = 5
        while true {
            let link = AirPlayTCPLink(host: host, port: port, ipv4Only: false, queue: queue)
            let channel = AirPlayEventChannel(link: link, outputKey: outputKey, inputKey: inputKey)
            link.onData = { [weak channel] data in channel?.received(data) }
            link.onClose = { error in AirPlayLog.debug("Event channel closed: \(error.localizedDescription)") }
            do {
                try await link.connect(timeout: 10)
                AirPlayLog.debug("Event channel connected on port \(port)")
                return channel
            } catch let error where AirPlayTCPLink.isRefused(error) && attempts > 1 {
                attempts -= 1
                AirPlayLog.debug("Event channel refused, retrying")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func close() { link.close() }

    /// A volume change reported by the speaker: a "dvlc" event with "volume" (0...1) at the top
    /// level or in "params", the way OwnTone reads them from HomePods.
    static func reportedVolume(_ plist: [String: Any]) -> Float? {
        let params = plist["params"] as? [String: Any]
        guard (plist["value"] as? String ?? params?["value"] as? String) == "dvlc",
              let number = (plist["volume"] ?? params?["volume"]) as? NSNumber else { return nil }
        let volume = number.floatValue
        return (0...1).contains(volume) ? volume : nil
    }

    private func received(_ data: Data) {
        do {
            buffer.append(try hap.decrypt(data))
            while let request = try AirPlayHTTPMessage.parse(&buffer) {
                AirPlayLog.debug("Event from speaker: \(request.firstLine)")
                if let plist = request.plist {
                    let params = plist["params"] as? [String: Any]
                    let type = plist["type"] as? String ?? "-"
                    let value = plist["value"] as? String ?? params?["value"] as? String ?? "-"
                    AirPlayLog.logger.notice("Speaker event: type \(type, privacy: .public), value \(value, privacy: .public), keys \(plist.keys.sorted().joined(separator: ","), privacy: .public)")
                    if let volume = Self.reportedVolume(plist) { onVolume?(volume) }
                }
                // Reply with the request's protocol ("RTSP/1.0"), like pyatv.
                let proto = request.firstLine.split(separator: " ").last.map(String.init) ?? "RTSP/1.0"
                var headers: [(String, String)] = [("Content-Length", "0"), ("Audio-Latency", "0")]
                headers.insert(("Server", request.header("Server") ?? "Soundcheck"), at: 0)
                if let cseq = request.header("CSeq") { headers.append(("CSeq", cseq)) }
                let reply = AirPlayHTTPMessage.format("\(proto) 200 OK", userAgent: nil, contentType: nil,
                                                      headers: headers, body: nil)
                link.send(try hap.encrypt(reply))
            }
        } catch {
            AirPlayLog.error("Event channel: \(error.localizedDescription)")
        }
    }
}
