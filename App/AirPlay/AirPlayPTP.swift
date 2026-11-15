// AirPlay audio sender for Soundcheck.
//
// The process's PTP (IEEE 1588) clock for AirPlay 2 timing, shared by every session. Like a Mac,
// it announces an ordinary clock, loses the best-master election to the receivers (HomePods and
// Apple TVs announce a better one), follows their grandmaster with Delay_Req exchanges, and
// publishes the mapping from this Mac's clock to the grandmaster's timeline, which every session's
// sync packets name. Multi-room sync then comes from every receiver being on that one timeline.
// When no receiver offers a clock, it becomes the grandmaster itself.
//
// A port of OwnTone's libairptp with tuxplay's follower role (tuxplayd/vendor/airptp: airptp.c,
// daemon.c, ptp_msg_handle.c, ptp_definitions.h, utils.c; MIT, © 2026 OwnTone) and of tuxplay's
// timeline.c (https://github.com/ksha23/tuxplay, MIT, © 2026 Kyle Sha). Differences: one thread with poll() instead of
// libevent; peers are reference-counted by address (several sessions may share one) and are sent
// to while registered (no 15-second "not heard from" skip); and the follower falls back to
// announcing as a strong grandmaster once its lock wait passes with no receiver clock to follow.

import Darwin
import Foundation

final class AirPlayPTPClock: @unchecked Sendable {
    static let shared = AirPlayPTPClock()

    enum Role: Sendable { case follow, master }

    enum State: Sendable {
        /// This Mac's clock is the timeline.
        case own
        /// Receivers were just added; a better clock may be about to lock.
        case waiting
        /// Locked to a receiver's grandmaster.
        case following
    }

    /// The timeline to state network time on (airptp_timeline): when following,
    /// gm = local - (offset + rate * (local - ref)), all in nanoseconds of this Mac's clock.
    struct Timeline: Sendable {
        let state: State
        /// Grandmaster identity to name next to the time.
        let clockID: UInt64
        let refNs: Int64
        let offsetNs: Int64
        let rate: Double
        /// True when nobody else is the grandmaster: then this Mac's clock is the timeline.
        let isGrandmaster: Bool

        func networkTime(localNs: Int64) -> Int64 {
            guard state == .following else { return localNs }
            return localNs - (offsetNs + Int64(rate * Double(localNs - refNs)))
        }

        func localTime(networkNs: Int64) -> Int64 {
            guard state == .following else { return networkNs }
            return Int64((Double(networkNs + offsetNs) - rate * Double(refNs)) / (1 - rate))
        }

        /// Whether sync packets may name this timeline: following a grandmaster, or being it
        /// (not while waiting for a receiver's clock, nor while relocking to a new one).
        var isUsable: Bool { state == .following || (state == .own && isGrandmaster) }
    }

    // MARK: Constants (airptp_internal.h, ptp_msg_handle.c, tuxplay timeline.c)

    private static let nsPerSec: Int64 = 1_000_000_000
    private static let announceIntervalNs: Int64 = 250_000_000   // logMessageInterval -2
    private static let syncIntervalNs: Int64 = 125_000_000       // -3
    private static let signalingIntervalNs: Int64 = 1_000_000_000
    private static let servoIntervalNs: Int64 = 1_000_000_000
    private static let logIntervalAnnounce: Int8 = -2
    private static let logIntervalSync: Int8 = -3
    private static let logIntervalSignaling: Int8 = -128

    // What a Mac announces (captured from macOS 26): an ordinary clock.
    private static let followPriority1: UInt8 = 250
    private static let followQuality: UInt32 = 0xF821_436A // class 248, accuracy 0x21, variance 0x436A
    private static let followPriority2: UInt8 = 239
    private static let followUTCOffset: UInt16 = 37
    private static let followTimeSource: UInt8 = 0xA0
    // OwnTone's grandmaster: a GPS-class clock every receiver follows.
    private static let masterPriority1: UInt8 = 128
    private static let masterQuality: UInt32 = 0x0621_436A
    private static let masterPriority2: UInt8 = 128
    private static let masterTimeSource: UInt8 = 0x20

    private static let window: Int64 = 4 * nsPerSec
    private static let stepThreshold: Int64 = 20_000_000
    private static let peersGoneGrace: Int64 = 10 * nsPerSec
    private static let slewSeconds = 5.0
    private static let slewMax = 200e-6
    private static let rateMax = 500e-6
    private static let statsInterval: Int64 = 60 * nsPerSec
    private static let outlier: Int64 = nsPerSec / 2
    private static let samplesMax = 64
    private static let fitPointsMax = 60
    private static let foreignMax = 8
    /// tuxplay's LOCK_WAIT_MS: a pair locks in ~0.4 s; this bounds a receiver that never does.
    static let lockWait: TimeInterval = 3

    // MARK: Ports

    /// The PTP ports: 319 (event) and 320 (general). Tests can move them, and the ports peers
    /// are sent to, before the clock starts.
    nonisolated(unsafe) static var eventPort: UInt16 = 319
    nonisolated(unsafe) static var generalPort: UInt16 = 320
    nonisolated(unsafe) static var peerEventPort: UInt16 = 319
    nonisolated(unsafe) static var peerGeneralPort: UInt16 = 320

    // MARK: State (all guarded by `lock`; the clock thread does the work)

    private struct Address {
        var storage = sockaddr_storage()
        var length: socklen_t = 0
        var family: Int32 { Int32(storage.ss_family) }

        init() {}

        init?(_ text: String) {
            var host = text
            if host.hasPrefix("::ffff:") { host.removeFirst(7) } // send IPv4 on the IPv4 socket
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_DGRAM
            hints.ai_flags = AI_NUMERICHOST
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "0", &hints, &result) == 0, let info = result else { return nil }
            defer { freeaddrinfo(result) }
            withUnsafeMutableBytes(of: &storage) { raw in
                raw.copyMemory(from: UnsafeRawBufferPointer(start: info.pointee.ai_addr, count: Int(info.pointee.ai_addrlen)))
            }
            length = info.pointee.ai_addrlen
        }

        func with(port: UInt16) -> Address {
            var copy = self
            withUnsafeMutableBytes(of: &copy.storage) { raw in
                if family == AF_INET6 {
                    raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_port = port.bigEndian
                } else {
                    raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_port = port.bigEndian
                }
            }
            return copy
        }

        var text: String {
            var buffer = [CChar](repeating: 0, count: 64)
            var copy = storage
            withUnsafeBytes(of: &copy) { raw in
                if family == AF_INET6 {
                    var a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    _ = inet_ntop(AF_INET6, &a, &buffer, 64)
                } else {
                    var a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    _ = inet_ntop(AF_INET, &a, &buffer, 64)
                }
            }
            return String(cString: buffer)
        }
    }

    private struct Peer {
        let id: UInt32
        let address: Address
        var references: Int
    }

    /// A clock some receiver announces, its own or one it follows.
    private struct Foreign {
        var portID = [UInt8](repeating: 0, count: 10)
        var address = Address()
        var gmID: UInt64 = 0
        var priority1: UInt8 = 0
        var quality: UInt32 = 0
        var priority2: UInt8 = 0
        var steps: UInt16 = 0
        var logInterval: Int8 = 0
        var lastAnnounce: Int64 = 0
    }

    private struct Sample {
        var local: Int64
        var value: Int64
    }

    private let lock = NSLock()
    private var role: Role = .follow
    private(set) var clockID: UInt64 = 0
    private var isRunning = false
    private var thread: Thread?
    /// When the last peer went (0: there are peers, or the clock just started).
    private var idleSince: Int64 = 0
    /// With no peers for this long, the ports are let go (so macOS's own AirPlay can have them).
    private static let releaseAfterNs: Int64 = 15_000_000_000
    private var event4: Int32 = -1, event6: Int32 = -1, general4: Int32 = -1, general6: Int32 = -1

    private var peers: [Peer] = []
    private var announceSeq: UInt16 = 0, signalingSeq: UInt16 = 0, syncSeq: UInt16 = 0, delayReqSeq: UInt16 = 0
    private var nextAnnounce: Int64 = 0, nextSignaling: Int64 = 0, nextSync: Int64 = 0, nextDelayReq: Int64 = 0, nextServo: Int64 = 0

    // Follower (struct airptp_follower)
    private var foreign: [Foreign?] = Array(repeating: nil, count: AirPlayPTPClock.foreignMax)
    private var master = -1
    private var masterSince: Int64 = 0
    private var firstPeer: Int64 = 0
    private var peersGone: Int64 = 0
    private var syncPending = false
    private var syncPendingSeq: UInt16 = 0
    private var syncRx: Int64 = 0
    private var syncCorrection: Int64 = 0
    private var delayReqPending = false
    private var delayReqPendingSeq: UInt16 = 0
    private var delayReqTx: Int64 = 0
    private var forward: [Sample] = []
    private var reverse: [Sample] = []
    private var fit: [Sample] = []
    private var locked = false
    private var delayMs = 0.0
    private var jitterMs = 0.0
    private var statsAt: Int64 = 0
    private var fallbackLogged = false

    // Published timeline
    private var published = (following: false, clockID: UInt64(0), ref: Int64(0), offset: Int64(0), rate: 0.0)

    private init() {
        if let env = ProcessInfo.processInfo.environment["SOUNDCHECK_PTP_ROLE"]?.lowercased(), env == "master" {
            role = .master
        }
    }

    /// This Mac's clock in nanoseconds (mach_absolute_time, the clock Core Audio uses).
    static func localNs(hostTime: UInt64 = mach_absolute_time()) -> Int64 {
        Int64(AirPlayClock.nanoseconds(fromHostTicks: hostTime))
    }

    static func hostTime(localNs: Int64) -> UInt64 {
        AirPlayClock.hostTicks(fromNanoseconds: UInt64(max(0, localNs)))
    }

    // MARK: API

    /// Follow the receivers (default, what a Mac does) or always be the grandmaster. Set before
    /// the first session starts; SOUNDCHECK_PTP_ROLE=master in the environment does the same.
    func setRole(_ newRole: Role) {
        lock.withLock { if !isRunning { role = newRole } }
    }

    /// Binds the PTP ports and starts the clock thread, once. Throws if the ports are taken (by
    /// another process using PTP); the next call tries again.
    func start() throws {
        try lock.withLock {
            if isRunning {
                idleSince = 0 // a session is about to add a peer: don't let the ports go meanwhile
                return
            }
            event4 = Self.bind(AF_INET, Self.eventPort)
            event6 = Self.bind(AF_INET6, Self.eventPort)
            general4 = Self.bind(AF_INET, Self.generalPort)
            general6 = Self.bind(AF_INET6, Self.generalPort)
            guard (event4 >= 0 || event6 >= 0) && (general4 >= 0 || general6 >= 0) else {
                for fd in [event4, event6, general4, general6] where fd >= 0 { close(fd) }
                event4 = -1; event6 = -1; general4 = -1; general6 = -1
                throw AirPlayError.unsupported("PTP ports \(Self.eventPort)/\(Self.generalPort) are in use: \(String(cString: strerror(errno)))")
            }
            clockID = Self.makeClockID()
            isRunning = true
            let thread = Thread { [self] in run() }
            thread.name = "AirPlay PTP"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
            AirPlayLog.debug(String(format: "PTP clock %016llX on ports %d/%d, %@", clockID, Self.eventPort, Self.generalPort,
                                    role == .follow ? "following the receivers' grandmaster when there is one" : "grandmaster"))
        }
    }

    var isAvailable: Bool { lock.withLock { isRunning } }

    /// A receiver to exchange PTP with. Returns a handle for `removePeer`.
    func addPeer(_ address: String) -> UInt32? {
        guard let parsed = Address(address) else {
            AirPlayLog.error("PTP: bad peer address \(address)")
            return nil
        }
        let id = Self.djbHash(address)
        lock.withLock {
            if let index = peers.firstIndex(where: { $0.id == id }) {
                peers[index].references += 1
                return
            }
            peers.append(Peer(id: id, address: parsed, references: 1))
            peersChanged()
            // Announce and signal at once; keep the sync rhythm if it's going.
            let now = Self.localNs()
            nextAnnounce = now
            nextSignaling = now
            if nextSync == 0 { nextSync = now + Self.syncIntervalNs }
            if nextDelayReq == 0 { nextDelayReq = now + Self.syncIntervalNs }
            if nextServo == 0 { nextServo = now + Self.servoIntervalNs }
            AirPlayLog.debug("PTP: added peer \(address), \(peers.count) peer(s)")
        }
        return id
    }

    func removePeer(_ id: UInt32) {
        lock.withLock {
            guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
            peers[index].references -= 1
            if peers[index].references > 0 { return }
            let address = peers[index].address.text
            peers.remove(at: index)
            peersChanged()
            AirPlayLog.debug("PTP: removed peer \(address), \(peers.count) peer(s)")
        }
    }

    /// The current mapping (airptp_timeline_get), with WAITING bounded by the lock wait.
    func timeline() -> Timeline {
        lock.withLock { currentTimeline(now: Self.localNs()) }
    }

    private func currentTimeline(now: Int64) -> Timeline {
        if published.following {
            return Timeline(state: .following, clockID: published.clockID, refNs: published.ref,
                            offsetNs: published.offset, rate: published.rate, isGrandmaster: false)
        }
        let waiting = role == .follow && firstPeer != 0 && now - firstPeer < Int64(Self.lockWait * 1e9)
        return Timeline(state: waiting ? .waiting : .own, clockID: clockID, refNs: 0, offsetNs: 0, rate: 0,
                        isGrandmaster: isGrandmaster)
    }

    /// Waits until the timeline can be named in sync packets: locked to a grandmaster, or (once
    /// the lock wait has passed with no receiver clock) this Mac's own clock. Gives up after
    /// `timeout` and returns whatever the timeline is then.
    func settledTimeline(timeout: TimeInterval = AirPlayPTPClock.lockWait + 0.5) async -> Timeline {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let current = timeline()
            if current.isUsable || Date() >= deadline { return current }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Sockets

    private static func bind(_ family: Int32, _ port: UInt16) -> Int32 {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var result: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private func send(_ bytes: [UInt8], to address: Address, event: Bool) {
        let fd = address.family == AF_INET6 ? (event ? event6 : general6) : (event ? event4 : general4)
        guard fd >= 0 else { return }
        var storage = address.storage
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer.baseAddress, bytes.count, 0, $0, address.length) }
            }
        }
        if sent != bytes.count {
            AirPlayLog.debug("PTP: sending to \(address.text) failed: \(String(cString: strerror(errno)))")
        }
    }

    private static func makeClockID() -> UInt64 {
        // Apple's form is the MAC address followed by two bytes (0x0008 on Apple devices); a
        // different suffix keeps this clock distinct from macOS's own AirPlay clock.
        var mac: [UInt8] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            var fallback: [UInt8] = []
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
                let name = String(cString: entry.pointee.ifa_name)
                let octets: [UInt8]? = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                    guard link.pointee.sdl_alen == 6 else { return nil }
                    let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(link.pointee.sdl_nlen)
                    let bytes = UnsafeRawPointer(link).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                    let octets = (0..<6).map { bytes[$0] }
                    return octets.contains(where: { $0 != 0 }) ? octets : nil
                }
                guard let octets else { continue }
                if name == "en0" { mac = octets; break }
                if fallback.isEmpty { fallback = octets }
            }
            if mac.isEmpty { mac = fallback }
            freeifaddrs(list)
        }
        if mac.isEmpty { mac = (0..<6).map { _ in UInt8.random(in: 0...255) } }
        var id: UInt64 = 0x5C53
        for (i, byte) in mac.enumerated() { id |= UInt64(byte) << (56 - 8 * UInt64(i)) }
        return id
    }

    private static func djbHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 5381
        for byte in text.utf8 { hash = (hash << 5) &+ hash &+ UInt32(byte) }
        return hash
    }

    // MARK: Thread

    private func run() {
        let fds = lock.withLock { [event4, event6, general4, general6].filter { $0 >= 0 } }
        var polls = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let idle = lock.withLock { peers.isEmpty }
            _ = poll(&polls, nfds_t(polls.count), idle ? 100 : 10)
            for i in polls.indices where polls[i].revents & Int16(POLLIN) != 0 {
                while true {
                    var from = sockaddr_storage()
                    var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    let count = buffer.withUnsafeMutableBytes { raw in
                        withUnsafeMutablePointer(to: &from) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                recvfrom(polls[i].fd, raw.baseAddress, raw.count, 0, $0, &fromLength)
                            }
                        }
                    }
                    // First thing after the read: a follower's timing is only as good as this.
                    let rx = Self.localNs()
                    guard count > 0 else { break }
                    var address = Address()
                    address.storage = from
                    address.length = fromLength
                    let message = Array(buffer[0..<count])
                    lock.withLock { handle(message, from: address, rx: rx) }
                }
            }
            let released = lock.withLock { () -> Bool in
                let now = Self.localNs()
                runTimers(now: now)
                return releaseIfIdle(now: now)
            }
            if released { return }
        }
    }

    /// Lets go of the ports and stops once nothing has streamed for a while; `start` binds them
    /// again for the next session. Called with the lock held.
    private func releaseIfIdle(now: Int64) -> Bool {
        if !peers.isEmpty {
            idleSince = 0
            return false
        }
        if idleSince == 0 {
            idleSince = now
            return false
        }
        guard now - idleSince > Self.releaseAfterNs else { return false }
        for fd in [event4, event6, general4, general6] where fd >= 0 { close(fd) }
        event4 = -1; event6 = -1; general4 = -1; general6 = -1
        master = -1
        foreign = Array(repeating: nil, count: Self.foreignMax)
        clearSamples()
        publish(following: false)
        peersGone = 0
        idleSince = 0
        isRunning = false
        thread = nil
        AirPlayLog.debug("PTP: nothing streaming, ports released")
        return true
    }

    private var isGrandmaster: Bool { role != .follow || master < 0 }

    /// Past the lock wait with no receiver clock to follow: announce as a grandmaster they follow.
    private func announcesAsMaster(now: Int64) -> Bool {
        if role == .master { return true }
        guard master < 0, firstPeer != 0, now - firstPeer >= Int64(Self.lockWait * 1e9) else { return false }
        if !fallbackLogged {
            fallbackLogged = true
            AirPlayLog.debug("PTP: no receiver offered a clock in \(Self.lockWait) s; acting as grandmaster")
        }
        return true
    }

    private func runTimers(now: Int64) {
        guard !peers.isEmpty else { return }
        if nextAnnounce != 0 && now >= nextAnnounce {
            nextAnnounce = now + Self.announceIntervalNs
            // A clock following another doesn't announce, and neither does a Mac once it has
            // found the receivers' grandmaster.
            if isGrandmaster { sendAnnounce(now: now) }
        }
        if nextSignaling != 0 && now >= nextSignaling {
            nextSignaling = now + Self.signalingIntervalNs
            if isGrandmaster { sendSignaling() }
        }
        if nextSync != 0 && now >= nextSync {
            nextSync = now + Self.syncIntervalNs
            if isGrandmaster { sendSync() }
        }
        if role == .follow && nextDelayReq != 0 && now >= nextDelayReq {
            nextDelayReq = now + Self.syncIntervalNs
            sendDelayReq()
        }
        if role == .follow && nextServo != 0 && now >= nextServo {
            nextServo = now + Self.servoIntervalNs
            servo(now: now)
        }
    }

    // MARK: Messages

    private static func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private static func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32(i))) }
    }

    private static func put64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (56 - 8 * UInt64(i))) }
    }

    private static func get16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func get32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    private static func get64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }

    /// A 10-byte PTP timestamp (48-bit seconds, 32-bit nanoseconds) in nanoseconds.
    private static func timestampNs(_ bytes: [UInt8], _ offset: Int) -> Int64 {
        var seconds: Int64 = 0
        for i in 0..<6 { seconds = seconds << 8 | Int64(bytes[offset + i]) }
        return seconds * nsPerSec + Int64(get32(bytes, offset + 6))
    }

    private static func putTimestamp(_ bytes: inout [UInt8], _ offset: Int, _ ns: Int64) {
        let seconds = UInt64(max(0, ns) / nsPerSec)
        for i in 0..<6 { bytes[offset + i] = UInt8(truncatingIfNeeded: seconds >> (40 - 8 * UInt64(i))) }
        put32(&bytes, offset + 6, UInt32(max(0, ns) % nsPerSec))
    }

    /// correctionField, nanoseconds scaled by 2^16. A receiver relaying its partner's clock
    /// stamps with its own clock and puts the difference here; it's added to the Follow_Up origin
    /// and to the Delay_Resp receive time alike.
    private static func correctionNs(_ bytes: [UInt8]) -> Int64 {
        Int64(bitPattern: get64(bytes, 8)) / 65536
    }

    private static let flagUnicast: UInt16 = 1 << 10
    private static let flagTimescale: UInt16 = 1 << 3
    private static let flagTwoStep: UInt16 = 1 << 9

    /// The 34-byte header (header_init): transportSpecific 1, PTPv2, domain 0, port 0x8005.
    private func header(type: UInt8, length: Int, sequence: UInt16, logInterval: Int8, flags: UInt16,
                        control: UInt8 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = type | 0x10
        bytes[1] = 0x02
        Self.put16(&bytes, 2, UInt16(length))
        Self.put16(&bytes, 6, flags)
        Self.put64(&bytes, 20, clockID)
        bytes[28] = 0x80
        bytes[29] = 0x05
        Self.put16(&bytes, 30, sequence)
        bytes[32] = control
        bytes[33] = UInt8(bitPattern: logInterval)
        return bytes
    }

    private func sendToPeers(_ bytes: [UInt8], event: Bool) {
        let port = event ? Self.peerEventPort : Self.peerGeneralPort
        for peer in peers { send(bytes, to: peer.address.with(port: port), event: event) }
    }

    private func sendAnnounce(now: Int64) {
        let strong = announcesAsMaster(now: now)
        var bytes = header(type: 0x0B, length: 76, sequence: announceSeq, logInterval: Self.logIntervalAnnounce,
                           flags: Self.flagUnicast | Self.flagTimescale)
        // originTimestamp 0, as iOS sends
        Self.put16(&bytes, 44, strong ? 0 : Self.followUTCOffset)
        bytes[47] = strong ? Self.masterPriority1 : Self.followPriority1
        Self.put32(&bytes, 48, strong ? Self.masterQuality : Self.followQuality)
        bytes[52] = strong ? Self.masterPriority2 : Self.followPriority2
        Self.put64(&bytes, 53, clockID)
        // stepsRemoved 0
        bytes[63] = strong ? Self.masterTimeSource : Self.followTimeSource
        // Path trace TLV with our clock identity, as iOS adds
        Self.put16(&bytes, 64, 0x0008)
        Self.put16(&bytes, 66, 8)
        Self.put64(&bytes, 68, clockID)
        sendToPeers(bytes, event: false)
        announceSeq &+= 1
    }

    private func sendSignaling() {
        var bytes = header(type: 0x0C, length: 106, sequence: signalingSeq, logInterval: Self.logIntervalSignaling,
                           flags: Self.flagUnicast | Self.flagTimescale, control: 0x05)
        // targetPortIdentity zero; two Apple TLVs with a fixed value nobody understands
        let apple: [UInt8] = [0x00, 0x0D, 0x93]
        let unknown: [UInt8] = [0x00, 0x00, 0x03, 0x01]
        Self.put16(&bytes, 44, 0x0003)
        Self.put16(&bytes, 46, 22)
        bytes.replaceSubrange(48..<58, with: apple + [0x00, 0x00, 0x01] + unknown)
        Self.put16(&bytes, 70, 0x0003)
        Self.put16(&bytes, 72, 32)
        bytes.replaceSubrange(74..<84, with: apple + [0x00, 0x00, 0x05] + unknown)
        sendToPeers(bytes, event: false)
        signalingSeq &+= 1
    }

    private func sendSync() {
        // Two-step: a Sync with no time, then a Follow_Up with the time the Sync left.
        let sync = header(type: 0x00, length: 44, sequence: syncSeq, logInterval: Self.logIntervalSync,
                          flags: Self.flagUnicast | Self.flagTimescale | Self.flagTwoStep)
        let sent = Self.localNs()
        sendToPeers(sync, event: true)
        var followUp = header(type: 0x08, length: 96, sequence: syncSeq, logInterval: Self.logIntervalSync,
                              flags: Self.flagUnicast | Self.flagTimescale)
        Self.putTimestamp(&followUp, 34, sent)
        Self.put16(&followUp, 44, 0x0003)
        Self.put16(&followUp, 46, 28)
        followUp.replaceSubrange(48..<54, with: [0x00, 0x80, 0xC2, 0x00, 0x00, 0x01])
        Self.put16(&followUp, 76, 0x0003)
        Self.put16(&followUp, 78, 16)
        followUp.replaceSubrange(80..<86, with: [0x00, 0x0D, 0x93, 0x00, 0x00, 0x04])
        Self.put64(&followUp, 86, clockID)
        sendToPeers(followUp, event: false)
        syncSeq &+= 1
    }

    private func sendDelayReq() {
        guard role == .follow, master >= 0, let target = foreign[master] else { return }
        // As macOS 27 sends it: unicast and timescale flags, controlField 0, no origin.
        let bytes = header(type: 0x01, length: 44, sequence: delayReqSeq, logInterval: Self.logIntervalSync,
                           flags: Self.flagUnicast | Self.flagTimescale)
        delayReqPendingSeq = delayReqSeq
        delayReqSeq &+= 1
        delayReqPending = true
        delayReqTx = Self.localNs()
        send(bytes, to: target.address.with(port: Self.peerEventPort), event: true)
        // Also to every other receiver offering a clock (a pair's second member): ones that get
        // none keep announcing four times a second. Only the master's answer counts.
        for (index, other) in foreign.enumerated() where index != master {
            if let other { send(bytes, to: other.address.with(port: Self.peerEventPort), event: true) }
        }
    }

    private func handle(_ bytes: [UInt8], from address: Address, rx: Int64) {
        guard bytes.count >= 34 else { return }
        switch bytes[0] & 0x0F {
        case 0x0B: handleAnnounce(bytes, from: address, rx: rx)
        case 0x00: handleSync(bytes, rx: rx)
        case 0x08: handleFollowUp(bytes)
        case 0x01: handleDelayReq(bytes, from: address)
        case 0x09: handleDelayResp(bytes, rx: rx)
        default: break // Signaling (TLVs we don't act on), Pdelay, Management
        }
    }

    private func fromMaster(_ bytes: [UInt8]) -> Bool {
        guard role == .follow, master >= 0, let current = foreign[master] else { return false }
        // Clock identity only: see handleAnnounce
        return Array(bytes[20..<28]) == Array(current.portID[0..<8])
    }

    private func handleSync(_ bytes: [UInt8], rx: Int64) {
        guard bytes.count >= 44, fromMaster(bytes) else { return }
        syncPending = true
        syncPendingSeq = Self.get16(bytes, 30)
        syncRx = rx
        syncCorrection = Self.correctionNs(bytes)
    }

    private func handleFollowUp(_ bytes: [UInt8]) {
        guard bytes.count >= 44, fromMaster(bytes), syncPending, Self.get16(bytes, 30) == syncPendingSeq else { return }
        syncPending = false
        let origin = Self.timestampNs(bytes, 34) + syncCorrection + Self.correctionNs(bytes)
        push(&forward, Sample(local: syncRx, value: syncRx - origin), max: Self.samplesMax)
    }

    private func handleDelayReq(_ bytes: [UInt8], from address: Address) {
        // Someone timing against us (we're their grandmaster): answer with when it arrived.
        guard bytes.count >= 44 else { return }
        var response = header(type: 0x09, length: 54, sequence: Self.get16(bytes, 30), logInterval: Self.logIntervalSync,
                              flags: Self.flagUnicast | Self.flagTimescale | Self.flagTwoStep)
        Self.putTimestamp(&response, 34, Self.localNs())
        response.replaceSubrange(44..<54, with: bytes[20..<30])
        send(response, to: address.with(port: Self.peerGeneralPort), event: false)
    }

    private func handleDelayResp(_ bytes: [UInt8], rx: Int64) {
        guard bytes.count >= 54, fromMaster(bytes) else { return }
        // requestingPortIdentity must be ours, answering the Delay_Req we timed
        guard Self.get64(bytes, 44) == clockID, delayReqPending, Self.get16(bytes, 30) == delayReqPendingSeq else { return }
        delayReqPending = false
        let receivedGm = Self.timestampNs(bytes, 34) + Self.correctionNs(bytes)
        push(&reverse, Sample(local: delayReqTx, value: receivedGm - delayReqTx), max: Self.samplesMax)
        if !locked { tryLock(now: rx) }
    }

    /// Every receiver announces the grandmaster it follows (its own clock or its partner's).
    private func handleAnnounce(_ bytes: [UInt8], from address: Address, rx: Int64) {
        guard bytes.count >= 64, role == .follow else { return }
        let source = Self.get64(bytes, 20)
        if source == clockID { return }
        // Keyed by clock identity, not port identity: a HomePod opens a new PTP port when a
        // session registers with it, and moves everything it sends us there a moment later.
        let identity = Array(bytes[20..<28])
        var index = foreign.firstIndex { $0.map { Array($0.portID[0..<8]) == identity } ?? false }
        if index == nil {
            guard let free = foreign.firstIndex(where: { $0 == nil }) else { return }
            foreign[free] = Foreign()
            index = free
        }
        guard let slot = index, var offer = foreign[slot] else { return }
        let previousGm = offer.gmID
        offer.portID = Array(bytes[20..<30])
        offer.address = address
        offer.priority1 = bytes[47]
        offer.quality = Self.get32(bytes, 48)
        offer.priority2 = bytes[52]
        offer.gmID = Self.get64(bytes, 53)
        offer.steps = Self.get16(bytes, 61)
        offer.logInterval = Int8(bitPattern: bytes[33])
        offer.lastAnnounce = rx
        foreign[slot] = offer

        // While a pair settles, a receiver can announce its own clock and then its partner's.
        if master == slot && previousGm != offer.gmID {
            AirPlayLog.debug(String(format: "PTP: the clock we follow now passes on grandmaster %016llX instead of %016llX, relocking",
                                    offer.gmID, previousGm))
            clearSamples()
            masterSince = rx
            publish(following: false)
        }
        // A receiver passing our own clock along offers nothing new.
        if offer.gmID == clockID {
            if master == slot { lose("it now follows our clock") }
            foreign[slot] = nil
            return
        }
        selectMaster(now: rx)
    }

    // MARK: Follower

    private static func compare(_ p1a: UInt8, _ qa: UInt32, _ p2a: UInt8, _ ida: UInt64,
                                _ p1b: UInt8, _ qb: UInt32, _ p2b: UInt8, _ idb: UInt64) -> Int {
        if p1a != p1b { return p1a < p1b ? -1 : 1 }
        if qa != qb { return qa < qb ? -1 : 1 }
        if p2a != p2b { return p2a < p2b ? -1 : 1 }
        if ida != idb { return ida < idb ? -1 : 1 }
        return 0
    }

    private static func isBetter(_ a: Foreign, than b: Foreign) -> Bool {
        let result = compare(a.priority1, a.quality, a.priority2, a.gmID, b.priority1, b.quality, b.priority2, b.gmID)
        if result != 0 { return result < 0 }
        if a.steps != b.steps { return a.steps < b.steps }
        return a.portID.lexicographicallyPrecedes(b.portID)
    }

    private func push(_ samples: inout [Sample], _ sample: Sample, max: Int) {
        if samples.count == max { samples.removeFirst() }
        samples.append(sample)
    }

    private func clearSamples() {
        syncPending = false
        delayReqPending = false
        forward.removeAll()
        reverse.removeAll()
        fit.removeAll()
        locked = false
    }

    private func lose(_ why: String) {
        guard master >= 0 else { return }
        AirPlayLog.debug(String(format: "PTP: no longer following grandmaster %016llX (%@), using our own clock",
                                foreign[master]?.gmID ?? 0, why))
        master = -1
        clearSamples()
        publish(following: false)
    }

    private func publish(following: Bool, ref: Int64 = 0, offset: Int64 = 0, rate: Double = 0) {
        if following, master >= 0, let current = foreign[master] {
            published = (true, current.gmID, ref, offset, rate)
        } else {
            published = (false, clockID, 0, 0, 0)
        }
    }

    private func selectMaster(now: Int64) {
        var best = -1
        for index in foreign.indices {
            guard let offer = foreign[index] else { continue }
            // Four announce intervals, never under 3 s: receivers slow to one a second once settled.
            var timeout: Int64
            if offer.logInterval >= 0 && offer.logInterval < 8 {
                timeout = (4 * Self.nsPerSec) << Int64(offer.logInterval)
            } else if offer.logInterval < 0 && offer.logInterval > -8 {
                timeout = (4 * Self.nsPerSec) >> Int64(-offer.logInterval)
            } else {
                timeout = 4 * Self.nsPerSec
            }
            timeout = max(timeout, 3 * Self.nsPerSec)
            if now - offer.lastAnnounce > timeout {
                AirPlayLog.debug(String(format: "PTP: offer from %@ for grandmaster %016llX expired", offer.address.text, offer.gmID))
                foreign[index] = nil
                if master == index { lose("it stopped announcing") }
                continue
            }
            if best < 0 || Self.isBetter(offer, than: foreign[best]!) { best = index }
        }
        guard best >= 0, let candidate = foreign[best],
              Self.compare(candidate.priority1, candidate.quality, candidate.priority2, candidate.gmID,
                           Self.followPriority1, Self.followQuality, Self.followPriority2, clockID) < 0 else {
            lose("no receiver offers a better clock")
            return
        }
        if master == best { return }

        // The same grandmaster reached through another receiver: stay on the path the samples
        // were taken on unless the new one is shorter (a relaying pair member adds its error).
        if master >= 0, let current = foreign[master], current.gmID == candidate.gmID {
            guard candidate.steps < current.steps else { return }
            AirPlayLog.debug(String(format: "PTP: grandmaster %016llX also announced directly by %@ (stepsRemoved %d), switching to that path",
                                    candidate.gmID, candidate.address.text, Int(candidate.steps)))
            master = best
            syncPending = false
            delayReqPending = false
            forward.removeAll()
            reverse.removeAll()
            return
        }

        AirPlayLog.debug(String(format: "PTP: following grandmaster %016llX announced by %@ (priority1 %d, class %d, stepsRemoved %d)",
                                candidate.gmID, candidate.address.text, Int(candidate.priority1),
                                Int((candidate.quality >> 24) & 0xFF), Int(candidate.steps)))
        master = best
        masterSince = now
        statsAt = now
        fallbackLogged = false
        clearSamples()
        publish(following: false)
    }

    /// The fastest exchange in the window, among samples on the same timescale as most of them
    /// (a receiver's first replies can be on its own clock, hours away).
    private func windowMinimum(_ samples: [Sample], since: Int64) -> (minimum: Int64, count: Int)? {
        let values = samples.filter { $0.local >= since }.map(\.value).sorted()
        guard !values.isEmpty else { return nil }
        let median = values[values.count / 2]
        guard let index = values.firstIndex(where: { $0 >= median - Self.outlier }) else { return nil }
        return (values[index], values.count - index)
    }

    /// offset is local minus grandmaster time.
    private func estimate(now: Int64, minimumSamples: Int) -> (offset: Int64, delay: Int64)? {
        guard let forwardMin = windowMinimum(forward, since: now - Self.window), forwardMin.count >= minimumSamples,
              let reverseMin = windowMinimum(reverse, since: now - Self.window), reverseMin.count >= minimumSamples else {
            return nil
        }
        let delay = (forwardMin.minimum + reverseMin.minimum) / 2
        let offset = (forwardMin.minimum - reverseMin.minimum) / 2
        // A clearly negative round trip means the window straddles a change on the grandmaster's side.
        return delay > -2_000_000 ? (offset, delay) : nil
    }

    /// Least squares line through the recent offset estimates, refitted once without outliers.
    private func fitLine(now: Int64, previousRate: Double) -> (offset: Int64, rate: Double, jitter: Double) {
        let last = fit[fit.count - 1]
        guard fit.count >= 3, now - fit[0].local >= 3 * Self.nsPerSec else { return (last.value, previousRate, 0) }
        let base = Double(last.value)
        var outlier = [Bool](repeating: false, count: fit.count)
        var slope = 0.0, intercept = 0.0, variance = 0.0
        for pass in 0..<2 {
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, n = 0.0
            for (i, point) in fit.enumerated() where !outlier[i] {
                let x = Double(point.local - now) / 1e9
                let y = Double(point.value) - base
                sx += x; sy += y; sxx += x * x; sxy += x * y; n += 1
            }
            guard n >= 3, n * sxx - sx * sx > 0 else { return (last.value, previousRate, 0) }
            slope = (n * sxy - sx * sy) / (n * sxx - sx * sx) // ns per second
            intercept = (sy - slope * sx) / n                 // at now
            variance = 0
            for (i, point) in fit.enumerated() where !outlier[i] {
                let residual = (Double(point.value) - base) - (intercept + slope * Double(point.local - now) / 1e9)
                variance += residual * residual
            }
            variance /= n
            if pass == 0 {
                let limit = max(3 * variance.squareRoot(), 500_000)
                for (i, point) in fit.enumerated() {
                    let residual = (Double(point.value) - base) - (intercept + slope * Double(point.local - now) / 1e9)
                    outlier[i] = abs(residual) > limit
                }
            }
        }
        let rate = min(max(slope / 1e9, -Self.rateMax), Self.rateMax)
        return (Int64(base + intercept), rate, variance.squareRoot() / 1e6)
    }

    private func tryLock(now: Int64) {
        guard let estimate = estimate(now: now, minimumSamples: 2) else { return }
        locked = true
        delayMs = Double(estimate.delay) / 1e6
        push(&fit, Sample(local: now, value: estimate.offset), max: Self.fitPointsMax)
        publish(following: true, ref: now, offset: estimate.offset, rate: 0)
        AirPlayLog.debug(String(format: "PTP: locked to grandmaster %016llX %.0f ms after choosing it, path delay %.1f ms",
                                foreign[master]?.gmID ?? 0, Double(now - masterSince) / 1e6, delayMs))
    }

    private func servo(now: Int64) {
        selectMaster(now: now)
        guard master >= 0, locked, let estimate = estimate(now: now, minimumSamples: 4) else { return }
        delayMs = Double(estimate.delay) / 1e6
        push(&fit, Sample(local: now, value: estimate.offset), max: Self.fitPointsMax)
        let line = fitLine(now: now, previousRate: published.rate)
        jitterMs = line.jitter
        // The mapping must stay continuous while audio is timed by it: slew small errors out
        // through the rate, step only large ones.
        let current = published.offset + Int64(published.rate * Double(now - published.ref))
        let error = line.offset - current
        if abs(error) > Self.stepThreshold {
            AirPlayLog.debug(String(format: "PTP: timeline stepped by %+.1f ms", Double(error) / 1e6))
            publish(following: true, ref: now, offset: line.offset, rate: line.rate)
        } else {
            let slew = min(max(Double(error) / (Self.slewSeconds * 1e9), -Self.slewMax), Self.slewMax)
            publish(following: true, ref: now, offset: current, rate: line.rate + slew)
        }
        if now - statsAt >= Self.statsInterval {
            statsAt = now
            AirPlayLog.debug(String(format: "PTP: following %016llX via %@: path delay %.1f ms, jitter %.2f ms, rate %+.1f ppm, correcting %+.2f ms",
                                    foreign[master]?.gmID ?? 0, foreign[master]?.address.text ?? "?", delayMs, jitterMs,
                                    line.rate * 1e6, Double(error) / 1e6))
        }
    }

    /// ptp_follower_peers_changed, plus resetting the grandmaster fallback.
    private func peersChanged() {
        let now = Self.localNs()
        if !peers.isEmpty && firstPeer == 0 { firstPeer = now }
        if peers.isEmpty {
            firstPeer = 0
            fallbackLogged = false
            nextAnnounce = 0; nextSignaling = 0; nextSync = 0; nextDelayReq = 0; nextServo = 0
        }
        // Keep the lock a moment for sessions that reconnect at once, then start from nothing.
        if peers.isEmpty && master >= 0 {
            if peersGone == 0 { peersGone = now }
            return
        }
        if !peers.isEmpty && peersGone != 0 {
            let stale = now - peersGone > Self.peersGoneGrace
            peersGone = 0
            if stale && master >= 0 {
                AirPlayLog.debug("PTP: no peers for a while, dropping the lock")
                master = -1
                clearSamples()
                publish(following: false)
            }
        }
    }
}
