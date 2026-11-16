import Foundation
import os

/// A speaker the main mix is sent to, timed on the AirPlay timeline: an AirPlay speaker, or a
/// companion (an iPhone or iPad with Soundcheck Companion) playing as one.
protocol SpeakerSession: AnyObject, Sendable {
    var onError: (@Sendable (Error) -> Void)? { get set }
    var onSpeakerVolume: (@Sendable (Float) -> Void)? { get set }
    var requestPIN: (@Sendable (_ reply: @escaping @Sendable (String?) -> Void) -> Void)? { get set }
    var allowsPTP: Bool { get set }
    var timingMethod: AirPlaySession.Timing { get }
    /// How long after a frame is current on the timeline the speaker plays it.
    var playbackDelay: TimeInterval { get }
    func start(_ done: @escaping @Sendable (Error?) -> Void)
    func enqueue(_ samples: UnsafePointer<Int16>, frames: Int, position: UInt64)
    func setVolume(_ volume: Float)
    func stop()
}

extension AirPlaySession: SpeakerSession {}

let companionStatsLog = Logger(subsystem: "com.mylesdean.Soundcheck", category: "companion")

struct CompanionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A companion playing as a speaker. The sound goes over the companion's link as it's mixed,
/// stamped with its place on the timeline; the companion plays each frame when the Mac's other
/// speakers do (it knows the Mac's clock, and how long its own output takes, which it tells the
/// Mac so the others wait for it).
final class CompanionSpeakerSession: SpeakerSession, @unchecked Sendable {
    let device: String
    private let timeline: AirPlayTimeline
    private let lock = NSLock()
    private var latency: TimeInterval = 0.05
    private var done: (@Sendable (Error?) -> Void)?
    private var isPlaying = false
    private var stopped = false
    private var volume: Float = 1
    private var channel: CompanionChannel?
    private var timeout: DispatchWorkItem?

    var onError: (@Sendable (Error) -> Void)?
    var onSpeakerVolume: (@Sendable (Float) -> Void)?
    var requestPIN: (@Sendable (_ reply: @escaping @Sendable (String?) -> Void) -> Void)?
    var allowsPTP = false
    var timingMethod: AirPlaySession.Timing { .ntp }
    var playbackDelay: TimeInterval { lock.withLock { Companion.speakerMargin + latency } }

    init(speaker: AirPlaySpeaker, timeline: AirPlayTimeline) {
        device = CompanionHub.device(fromSpeakerID: speaker.id) ?? speaker.id
        self.timeline = timeline
    }

    func start(_ done: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { self.done = done }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CompanionHub.shared.register(self) }
        }
        // It may need waking, and someone to tap a notification: give that a minute and a half.
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishStart(CompanionError(message: "\(MainActor.assumeIsolated { CompanionHub.shared.name(of: self?.device ?? "") }) didn't answer"))
        }
        lock.withLock { self.timeout = timeout }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
    }

    /// The companion is connected (now, or it already was): it's asked to play.
    @MainActor func connected() {
        guard let peer = CompanionHub.shared.peer(for: device) else { return }
        let (stopped, volume) = lock.withLock { () -> (Bool, Float) in
            channel = peer.channel
            return (self.stopped, self.volume)
        }
        guard !stopped else { return }
        peer.channel.send(.speakerStart(start: HostClock.nanoseconds(timeline.startHostTime), delay: playbackDelay))
        peer.channel.send(.speakerVolume(volume))
    }

    /// It's playing; `latency` is its own output's.
    @MainActor func ready(latency: TimeInterval) {
        let changed = lock.withLock { () -> Bool in
            let changed = abs(self.latency - latency) > 0.002
            self.latency = min(max(latency, 0), 1)
            return changed
        }
        // Everything else waits that much longer; it's told when to play to match.
        if changed, let channel = lock.withLock({ channel }) {
            channel.send(.speakerStart(start: HostClock.nanoseconds(timeline.startHostTime), delay: playbackDelay))
        }
        let wasPlaying = lock.withLock { () -> Bool in
            let was = isPlaying
            isPlaying = true
            return was
        }
        if !wasPlaying {
            finishStart(nil)
        } else if changed {
            AudioEngine.shared.companionLatencyChanged()
        }
    }

    /// It couldn't play yet (asleep, needs its app opened): still waiting, unless it never will.
    @MainActor func waiting(_ reason: String) {
        _ = reason // shown under the speaker's name (the hub keeps it)
    }

    /// The link went (the companion slept, left the network, or quit).
    @MainActor func lostConnection() {
        let playing = lock.withLock { () -> Bool in
            channel = nil
            return isPlaying
        }
        if playing { onError?(CompanionError(message: "Lost the connection")) }
    }

    private func finishStart(_ error: Error?) {
        let done = lock.withLock { () -> (@Sendable (Error?) -> Void)? in
            let done = self.done
            self.done = nil
            timeout?.cancel()
            timeout = nil
            return done
        }
        guard let done else { return }
        DispatchQueue.main.async { done(error) }
    }

    private var sent = 0, calls = 0, loudest: Int16 = 0

    func enqueue(_ samples: UnsafePointer<Int16>, frames: Int, position: UInt64) {
        calls += 1
        for index in 0..<(frames * 2) { loudest = max(loudest, samples[index] == .min ? .max : abs(samples[index])) }
        if calls % 500 == 1 {
            let state = lock.withLock { (isPlaying, channel != nil) }
            companionStatsLog.debug("Speaker \(self.device.prefix(8), privacy: .public): \(self.sent) frames sent, at \(position), loudest \(String(format: "%.1f", 20 * log10(max(Double(self.loudest), 1) / 32_768)), privacy: .public) dB, playing \(state.0), linked \(state.1)")
            loudest = 0
        }
        guard frames > 0, let channel = lock.withLock({ isPlaying ? channel : nil }) else { return }
        sent += frames
        let data = Data(bytes: samples, count: frames * 2 * MemoryLayout<Int16>.size)
        channel.sendAudio(.speakerAudio(position: Int64(position), samples: data))
    }

    func setVolume(_ volume: Float) {
        let channel = lock.withLock { () -> CompanionChannel? in
            guard abs(self.volume - volume) > 0.0005 else { return nil }
            self.volume = volume
            return self.channel
        }
        channel?.send(.speakerVolume(volume))
    }

    func stop() {
        lock.withLock {
            stopped = true
            isPlaying = false
            timeout?.cancel()
            timeout = nil
            done = nil
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CompanionHub.shared.unregister(self) }
        }
    }
}
