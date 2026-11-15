// AirPlay audio sender for Soundcheck.
//
// The shared clock: host time, NTP time (what AirPlay receivers sync to) and RTP time. RAOP's
// timing model (sync packets mapping RTP time to NTP time, timestamps `latency` frames ahead) is
// pyatv's (pyatv/protocols/raop/timing.py, protocols/__init__.py StreamContext):
// https://github.com/postlund/pyatv, MIT License, © Pierre Ståhl.

import Darwin
import Foundation

/// Host time (mach_absolute_time, the clock Core Audio timestamps use) and the NTP time sessions
/// tell receivers. NTP time is derived from host time with an offset fixed at first use, so it
/// never jumps when the wall clock is adjusted, and every session in the process agrees on it.
enum AirPlayClock {
    private static let numer: UInt64 = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(info.numer)
    }()
    private static let denom: UInt64 = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(info.denom)
    }()
    /// (host time, NTP time) at the same instant, taken once.
    private static let anchorHost: UInt64 = anchor.host
    private static let anchorNTP: UInt64 = anchor.ntp
    private static let anchor: (host: UInt64, ntp: UInt64) = {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        let host = mach_absolute_time()
        let seconds = UInt64(now.tv_sec) + 2_208_988_800 // 1900 → 1970
        let fraction = (UInt64(now.tv_nsec) << 32) / 1_000_000_000
        return (host, seconds << 32 | fraction)
    }()

    static var hostTimeNow: UInt64 { mach_absolute_time() }

    /// a·b/c without overflowing the intermediate product (saturates if the result doesn't fit).
    static func multiplyDivide(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64 {
        let product = a.multipliedFullWidth(by: b)
        guard product.high < c else { return .max }
        return c.dividingFullWidth(product).quotient
    }

    static func nanoseconds(fromHostTicks ticks: UInt64) -> UInt64 {
        multiplyDivide(ticks, numer, denom)
    }

    static func hostTicks(fromNanoseconds nanos: UInt64) -> UInt64 {
        multiplyDivide(nanos, denom, numer)
    }

    static func hostTicks(fromSeconds seconds: Double) -> UInt64 {
        hostTicks(fromNanoseconds: UInt64(max(0, seconds) * 1e9))
    }

    static func seconds(fromHostTicks ticks: UInt64) -> Double {
        Double(nanoseconds(fromHostTicks: ticks)) / 1e9
    }

    /// Nanoseconds as NTP 32.32 fixed point.
    private static func ntpInterval(nanoseconds nanos: UInt64) -> UInt64 {
        let seconds = nanos / 1_000_000_000
        let fraction = ((nanos % 1_000_000_000) << 32) / 1_000_000_000
        return seconds << 32 | fraction
    }

    /// NTP time (seconds since 1900 in the high 32 bits, fraction in the low 32) of a host time.
    static func ntp(hostTime: UInt64) -> UInt64 {
        if hostTime >= anchorHost {
            return anchorNTP &+ ntpInterval(nanoseconds: nanoseconds(fromHostTicks: hostTime - anchorHost))
        }
        return anchorNTP &- ntpInterval(nanoseconds: nanoseconds(fromHostTicks: anchorHost - hostTime))
    }

    static var ntpNow: UInt64 { ntp(hostTime: mach_absolute_time()) }
}

/// Shared clock for several sessions so they play in sync: frame 0 of the stream plays at
/// `start` + the receivers' latency. Sessions given the same timeline and the same frames must
/// stay in sync with each other (like multi-room AirPlay).
///
/// Positions are frames at 44.1 kHz since frame 0. Frame P is "current" at `start + P / 44100`
/// (that's when a producer capturing live audio would have it) and plays on every speaker at
/// `start + latency + P / 44100`: each session stamps it with RTP time `P + latencyFrames` and
/// tells its receiver, in sync packets, that RTP time `P` corresponds to NTP time
/// `start + P / 44100`, so receivers syncing to the same clock play the same frame together.
final class AirPlayTimeline: @unchecked Sendable {
    static let sampleRate = 44_100
    /// pyatv's latency: 22050 + 44100 frames (1.5 s).
    static let defaultLatency: TimeInterval = 66_150.0 / 44_100.0

    /// Host time (mach_absolute_time) of frame 0.
    let startHostTime: UInt64
    /// How far ahead of "current" a frame plays, in frames.
    let latencyFrames: UInt32
    /// NTP time of frame 0.
    let startNTP: UInt64

    /// Seconds between a frame being current and it playing on the speakers.
    var latency: TimeInterval { Double(latencyFrames) / Double(Self.sampleRate) }

    /// Wall-clock time of frame 0.
    var start: Date {
        let now = mach_absolute_time()
        let offset = now >= startHostTime
            ? -AirPlayClock.seconds(fromHostTicks: now - startHostTime)
            : AirPlayClock.seconds(fromHostTicks: startHostTime - now)
        return Date(timeIntervalSinceNow: offset)
    }

    /// `latency` is clamped to 0.25…2 s (the range sessions announce to receivers).
    init(startHostTime: UInt64 = mach_absolute_time(), latency: TimeInterval = AirPlayTimeline.defaultLatency) {
        self.startHostTime = startHostTime
        let clamped = min(max(latency, 11_025.0 / 44_100.0), 88_200.0 / 44_100.0)
        latencyFrames = UInt32((clamped * Double(Self.sampleRate)).rounded())
        startNTP = AirPlayClock.ntp(hostTime: startHostTime)
    }

    convenience init(start: Date, latency: TimeInterval = AirPlayTimeline.defaultLatency) {
        let delta = start.timeIntervalSinceNow
        let now = mach_absolute_time()
        let host = delta >= 0 ? now + AirPlayClock.hostTicks(fromSeconds: delta)
                              : now - min(now, AirPlayClock.hostTicks(fromSeconds: -delta))
        self.init(startHostTime: host, latency: latency)
    }

    /// The frame that is current at a host time (e.g. an AudioTimeStamp's mHostTime): use it as
    /// the `position` of captured audio. Negative before frame 0.
    func position(atHostTime hostTime: UInt64) -> Int64 {
        if hostTime >= startHostTime {
            let nanos = AirPlayClock.nanoseconds(fromHostTicks: hostTime - startHostTime)
            return Int64(clamping: AirPlayClock.multiplyDivide(nanos, UInt64(Self.sampleRate), 1_000_000_000))
        }
        let nanos = AirPlayClock.nanoseconds(fromHostTicks: startHostTime - hostTime)
        return -Int64(clamping: AirPlayClock.multiplyDivide(nanos, UInt64(Self.sampleRate), 1_000_000_000)) - 1
    }

    /// The frame that is current now.
    var currentPosition: Int64 { position(atHostTime: mach_absolute_time()) }

    /// Host time at which frame `position` is current.
    func hostTime(atPosition position: Int64) -> UInt64 {
        let magnitude = UInt64(position.magnitude)
        let nanos = AirPlayClock.multiplyDivide(magnitude, 1_000_000_000, UInt64(Self.sampleRate))
        let ticks = AirPlayClock.hostTicks(fromNanoseconds: nanos)
        return position >= 0 ? startHostTime &+ ticks : startHostTime &- ticks
    }

    /// Host time at which frame `position` comes out of the speakers.
    func playbackHostTime(ofPosition position: Int64) -> UInt64 {
        hostTime(atPosition: position + Int64(latencyFrames))
    }

    /// NTP time at which frame `position` is current (exact, from frame counts).
    func ntpTime(atPosition position: Int64) -> UInt64 {
        let magnitude = UInt64(position.magnitude)
        let rate = UInt64(Self.sampleRate)
        let interval = (magnitude / rate) << 32 | ((magnitude % rate) << 32) / rate
        return position >= 0 ? startNTP &+ interval : startNTP &- interval
    }

    /// RTP timestamp of frame `position` (pyatv: frames sent + latency).
    func rtpTime(atPosition position: Int64) -> UInt32 {
        UInt32(truncatingIfNeeded: position &+ Int64(latencyFrames))
    }

    // MARK: PTP group

    /// How long after its timeline moment a frame is rendered by speakers timed with PTP: what a
    /// Mac runs at ("AudioEngineRealTime using audio latency 400 ms", from tuxplay's notes).
    /// Every PTP session uses it, so all of them render a position at the same moment.
    static let ptpLatency: TimeInterval = 0.4

    /// Sent as groupUUID by every session on this timeline, like a Mac's multi-room group.
    let groupUUID = UUID().uuidString.uppercased()

    private let groupLock = NSLock()
    private var ptpMembers: [ObjectIdentifier: (address: String, changed: @Sendable () -> Void)] = [:]

    /// Adds a receiver timed with PTP to the group; `changed` is called (on an arbitrary queue)
    /// when another receiver joins or leaves, so the session can send SETPEERS again.
    func joinPTPGroup(_ member: ObjectIdentifier, address: String, changed: @escaping @Sendable () -> Void) {
        let others = groupLock.withLock { () -> [@Sendable () -> Void] in
            ptpMembers[member] = (address, changed)
            return ptpMembers.filter { $0.key != member }.map(\.value.changed)
        }
        others.forEach { $0() }
    }

    func leavePTPGroup(_ member: ObjectIdentifier) {
        let others = groupLock.withLock { () -> [@Sendable () -> Void] in
            guard ptpMembers.removeValue(forKey: member) != nil else { return [] }
            return ptpMembers.map(\.value.changed)
        }
        others.forEach { $0() }
    }

    /// The PTP addresses of every receiver in the group.
    var ptpGroupAddresses: [String] {
        groupLock.withLock { ptpMembers.values.map(\.address).sorted() }
    }
}
