import AVFoundation
import MediaPlayer
import Synchronization
import UIKit

/// The audio session, for playing as a speaker, the microphone, or both (then with echo
/// cancellation, so the Mac's sound playing here doesn't go back into the microphone).
@MainActor
enum AudioSessionSetup {
    static func apply(speaker: Bool, microphone: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        switch (speaker, microphone) {
        case (true, true):
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        case (true, false):
            // Not mixable: that's what makes it the lock screen's player.
            try session.setCategory(.playback, mode: .default, options: [])
        case (false, true):
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        case (false, false):
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
    }
}

/// Playing the Mac's sound, as one of its speakers. Frames arrive stamped with their place on
/// the Mac's timeline (frame P plays at Mac time `start` + P/44100 + `delay`); each time iOS asks
/// for sound, the frame due when it'll be heard is worked out from the Mac's clock, so this
/// plays in step with the Mac's other speakers. The two clocks drift a little: the read position
/// eases back to where it should be one frame at a time, and jumps if it's far off.
final class SpeakerPlayer: @unchecked Sendable {
    static let shared = SpeakerPlayer()

    private static let capacity = 1 << 17 // frames, about 3 s
    private let ring: UnsafeMutablePointer<Float>
    /// The highest frame written so far (+1), and whether anything has been.
    private let writtenEnd = Atomic<Int64>(Int64.min)
    private let timelineStart = Atomic<UInt64>(0)
    private let delay = Atomic<UInt64>(0)
    /// The output's latency (nanoseconds) and the gain (Float bits), set on the main thread.
    private let outputLatency = Atomic<UInt64>(0)
    private let gain = Atomic<UInt32>(Float(1).bitPattern)
    private let running = Atomic<Bool>(false)
    // Counters for the log (written on their threads, read now and then).
    private let receivedFrames = Atomic<Int>(0)
    private let lastDue = Atomic<Int64>(0)
    private let renders = Atomic<Int>(0)
    private let silentRenders = Atomic<Int>(0)
    @MainActor private var statsTimer: Timer?
    // Render thread only.
    private var readPosition: Int64?
    private var smoothedOff: Double = 0
    private var currentGain: Float = 1

    // Main thread only.
    @MainActor private var engine: AVAudioEngine?
    @MainActor private(set) var isPlaying = false
    /// A start the Mac asked for that iOS didn't allow from the background: tried again when
    /// the app opens.
    @MainActor private var pendingStart: (start: UInt64, delay: Double)?
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var commandsReady = false

    private init() {
        ring = .allocate(capacity: Self.capacity * 2)
        ring.initialize(repeating: 0, count: Self.capacity * 2)
    }

    // MARK: Starting and stopping

    @MainActor func start(timelineStart start: UInt64, delay seconds: Double) {
        timelineStart.store(start, ordering: .relaxed)
        delay.store(UInt64(max(seconds, 0) * 1e9), ordering: .relaxed)
        if isPlaying {
            // Already playing: the timing changed (the Mac took this device's latency into
            // account), or the Mac reconnected and is asking again, so say so again.
            reportLatency()
            return
        }
        do {
            try AudioSessionSetup.apply(speaker: true, microphone: MicStreamer.shared.isRunning)
            try startEngine()
        } catch {
            companionLog.error("Couldn't play: \(error.localizedDescription, privacy: .public)")
            pendingStart = (start, seconds)
            let inBackground = UIApplication.shared.applicationState != .active
            MacLink.shared.send(.speakerFailed(inBackground ? "Tap the notification on your \(PairingStore.deviceKind)" : "Couldn't play here"))
            if inBackground { Notifications.askToPlay(mac: MacLink.shared.state?.macShortName ?? "your Mac") }
            return
        }
        pendingStart = nil
        isPlaying = true
        SharedState.speakerOn = true
        startStats()
        setUpRemoteCommands()
        updateNowPlaying()
        reportLatency()
        VolumeButtons.shared.update()
    }

    @MainActor private func startEngine() throws {
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Companion.speakerRate, channels: 2) else { return }
        let source = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, buffers in
            self.render(timestamp, Int(frameCount), buffers)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        readPosition = nil
        writtenEnd.store(Int64.min, ordering: .relaxed)
        updateLatency()
        try engine.start()
        self.engine = engine
        running.store(true, ordering: .releasing)
        watchSession()
    }

    @MainActor private func startStats() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { SpeakerPlayer.shared.logStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    @MainActor private func logStats() {
        let end = writtenEnd.load(ordering: .relaxed), due = lastDue.load(ordering: .relaxed)
        let ahead = end == Int64.min ? -1 : (end - due) * 1000 / 44_100
        companionLog.debug("""
            Speaker: \(self.receivedFrames.load(ordering: .relaxed)) frames in, written to \(end), due \(due) (\(ahead) ms ahead), \
            renders \(self.renders.load(ordering: .relaxed)) (\(self.silentRenders.load(ordering: .relaxed)) silent), clock \(MacLink.clock.isKnown), \
            gain \(Float(bitPattern: self.gain.load(ordering: .relaxed))), start \(self.timelineStart.load(ordering: .relaxed)), running \(self.running.load(ordering: .relaxed))
            """)
    }

    @MainActor func stop() {
        pendingStart = nil
        statsTimer?.invalidate()
        statsTimer = nil
        guard isPlaying else { return }
        isPlaying = false
        running.store(false, ordering: .releasing)
        engine?.stop()
        engine = nil
        SharedState.speakerOn = false
        try? AudioSessionSetup.apply(speaker: false, microphone: MicStreamer.shared.isRunning)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        VolumeButtons.shared.update()
    }

    /// The link went: keep the session a moment (it usually comes straight back), then stop.
    @MainActor func linkLost() {
        guard isPlaying else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            MainActor.assumeIsolated {
                let player = SpeakerPlayer.shared
                if player.isPlaying && !MacLink.shared.isConnected { player.stop() }
            }
        }
    }

    /// The app came to the front: a start iOS refused in the background is tried now.
    @MainActor func appBecameActive() {
        if let pending = pendingStart { start(timelineStart: pending.start, delay: pending.delay) }
    }

    @MainActor func setVolume(_ volume: Float) {
        let level = min(max(volume, 0), 1)
        gain.store((level * level * level).bitPattern, ordering: .relaxed)
    }

    // MARK: The session

    @MainActor private func watchSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated { SpeakerPlayer.shared.interrupted(type == .began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let player = SpeakerPlayer.shared
                player.updateLatency()
                player.reportLatency()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SpeakerPlayer.shared.restart() }
        })
    }

    /// A phone call (or Siri, an alarm) took the sound: it comes back after.
    @MainActor private func interrupted(_ began: Bool) {
        guard isPlaying else { return }
        if began {
            running.store(false, ordering: .releasing)
        } else {
            restart()
        }
    }

    @MainActor private func restart() {
        guard isPlaying else { return }
        engine?.stop()
        engine = nil
        do {
            try AudioSessionSetup.apply(speaker: true, microphone: MicStreamer.shared.isRunning)
            try startEngine()
            updateNowPlaying()
        } catch {
            companionLog.error("Couldn't play again: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor private func updateLatency() {
        let session = AVAudioSession.sharedInstance()
        outputLatency.store(UInt64(max(session.outputLatency, 0) * 1e9), ordering: .relaxed)
    }

    /// Tells the Mac how long sound takes here (AirPods take a lot longer than the speaker).
    @MainActor private func reportLatency() {
        guard isPlaying else { return }
        let session = AVAudioSession.sharedInstance()
        MacLink.shared.send(.speakerReady(latency: session.outputLatency + session.ioBufferDuration))
    }

    // MARK: Sound from the Mac (on the link's queue)

    func receive(position: Int64, samples: Data) {
        guard running.load(ordering: .relaxed) else { return }
        let frames = samples.count / 4
        guard frames > 0 else { return }
        var end = writtenEnd.load(ordering: .relaxed)
        // A gap (frames dropped while Wi-Fi stalled): silence there, not what was in the ring.
        if end != Int64.min, position > end {
            let gap = min(position - end, Int64(Self.capacity))
            for offset in 0..<gap {
                let slot = Int((end + offset) & Int64(Self.capacity - 1))
                ring[slot * 2] = 0
                ring[slot * 2 + 1] = 0
            }
        }
        samples.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                let slot = Int((position + Int64(frame)) & Int64(Self.capacity - 1))
                ring[slot * 2] = Float(Int16(littleEndian: ints[frame * 2])) / 32_768
                ring[slot * 2 + 1] = Float(Int16(littleEndian: ints[frame * 2 + 1])) / 32_768
            }
        }
        end = end == Int64.min ? position + Int64(frames) : max(end, position + Int64(frames))
        writtenEnd.store(end, ordering: .releasing)
        receivedFrames.add(frames, ordering: .relaxed)
    }

    // MARK: Render thread

    private func render(_ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: Int, _ buffers: UnsafeMutablePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        guard list.count >= 2, let left = list[0].mData?.assumingMemoryBound(to: Float.self),
              let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        // When this buffer will be heard, in the Mac's time, and so which frame is due.
        let stamp = timestamp.pointee
        let host = stamp.mFlags.contains(.hostTimeValid) ? HostClock.nanoseconds(stamp.mHostTime) : HostClock.now
        let heard = host &+ outputLatency.load(ordering: .relaxed)
        let start = timelineStart.load(ordering: .relaxed)
        let end = writtenEnd.load(ordering: .acquiring)
        renders.add(1, ordering: .relaxed)
        guard running.load(ordering: .relaxed), start > 0, end != Int64.min, let mac = MacLink.clock.macTime(heard) else {
            silentRenders.add(1, ordering: .relaxed)
            for frame in 0..<frames { left[frame] = 0; right[frame] = 0 }
            readPosition = nil
            return
        }
        let since = Int64(bitPattern: mac &- start &- delay.load(ordering: .relaxed))
        let due = since / 1_000 * 44_100 / 1_000_000 // nanoseconds → frames at 44.1 kHz
        lastDue.store(due, ordering: .relaxed)
        var position: Int64
        if let read = readPosition {
            position = read
            // How far off it is, averaged over a fraction of a second: each buffer's own reading
            // jitters by a millisecond or so, and chasing that would click all the time.
            smoothedOff += (Double(due - read) - smoothedOff) * 0.04
            if abs(smoothedOff) > 4_410 {
                position = due // 100 ms out (a long stall): start again from where it should be
                smoothedOff = 0
            } else if abs(smoothedOff) > 88 {
                // More than 2 ms off (the clocks drift, or the timing changed): a frame or two at
                // a time, skipped or played again, which can't be heard.
                let adjust: Int64 = smoothedOff > 0 ? (smoothedOff > 441 ? 2 : 1) : (smoothedOff < -441 ? -2 : -1)
                position += adjust
                smoothedOff -= Double(adjust)
            }
        } else {
            position = due
            smoothedOff = 0
        }
        let target = Float(bitPattern: gain.load(ordering: .relaxed))
        var level = currentGain
        let step = (target - level) / Float(max(frames, 1))
        for frame in 0..<frames {
            let at = position + Int64(frame)
            level += step
            if at < end && at > end - Int64(Self.capacity) + 4_410 {
                let slot = Int(at & Int64(Self.capacity - 1))
                left[frame] = ring[slot * 2] * level
                right[frame] = ring[slot * 2 + 1] * level
            } else {
                left[frame] = 0
                right[frame] = 0
            }
        }
        currentGain = target
        readPosition = position + Int64(frames)
    }

    // MARK: The lock screen

    /// The lock screen's player: this Mac, on the grey tile Soundcheck shows for its System sounds.
    @MainActor func stateChanged(_ state: RemoteState) {
        guard isPlaying else { return }
        updateNowPlaying()
    }

    /// The lock screen's player: this Mac, on the grey tile Soundcheck shows for System, with
    /// what's playing there and what the main bar controls (no timeline: there's no track).
    @MainActor func updateNowPlaying() {
        guard isPlaying else { return }
        let state = MacLink.shared.state
        let knob = state?.knob ?? "speakers"
        let knobName = knob == "apps" ? "Apps" : knob == "mics" ? "Mics" : "Speakers"
        let playing = state?.playing ?? []
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state?.macShortName ?? "Mac",
            MPMediaItemPropertyArtist: (playing.isEmpty ? "" : ListFormatter.localizedString(byJoining: playing) + " · ") + knobName,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing.isEmpty ? 0.0 : 1.0,
        ]
        let artwork = Self.artwork(symbol: state?.macSymbol ?? "laptopcomputer")
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing.isEmpty ? .paused : .playing
    }

    /// The Mac on the grey of Soundcheck's System tile, filling the square (the lock screen rounds
    /// the corners itself; a tile with its own margin would sit on white).
    @MainActor private static var artworkCache: (symbol: String, image: UIImage)?

    @MainActor static func artwork(symbol: String) -> UIImage {
        if let cached = artworkCache, cached.symbol == symbol { return cached.image }
        let side: CGFloat = 600
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let colors = [UIColor(white: 0.66, alpha: 1).cgColor, UIColor(white: 0.46, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: side), options: [])
            }
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.36, weight: .medium)
            if let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
            }
        }
        artworkCache = (symbol, image)
        return image
    }

    /// Play/pause and skip on the lock screen (and AirPods, CarPlay, Control Center) press the
    /// Mac's media keys.
    @MainActor private func setUpRemoteCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            command.addTarget { _ in
                MainActor.assumeIsolated { action() }
                return .success
            }
        }
        let link = MacLink.shared
        handle(center.togglePlayPauseCommand) { link.send(.playPause) }
        handle(center.playCommand) { if link.state?.playing.isEmpty ?? true { link.send(.playPause) } }
        handle(center.pauseCommand) { if !(link.state?.playing.isEmpty ?? true) { link.send(.playPause) } }
        handle(center.nextTrackCommand) { link.send(.nextTrack) }
        handle(center.previousTrackCommand) { link.send(.previousTrack) }
        for command in [center.seekForwardCommand, center.seekBackwardCommand, center.changePlaybackPositionCommand,
                        center.skipForwardCommand, center.skipBackwardCommand] {
            command.isEnabled = false
        }
    }
}
