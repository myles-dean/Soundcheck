import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// While AirPlay speakers are in use, the Mac's sound goes through this one mixer instead of the
/// separate taps: every app with its own level (and everything else at the apps' level) is tapped
/// and muted at the source, mixed here, then sent both to the AirPlay speakers (through the
/// feed) and, held back by the AirPlay delay so they play together, to the regular speakers.
///
/// A private aggregate device of the regular speakers (the first is the clock; with AirPlay
/// only, it's written silence) plus one tap per source, with an IO proc that does the mixing.
final class MainMixer: @unchecked Sendable {
    struct Source {
        let tap: TapPlayer.Source
        let gain: SharedValue
        let muted: SharedValue
        /// The app's own EQ (none for everything else).
        var shape: ShapeControl?
        /// The app's own effects, after its EQ (none for everything else).
        var effects: EffectControl?
        /// The AirPlay speakers it's sent to on its own (indexes into the mixer's AirPlay
        /// speakers); none: it's in the main mix.
        var airPlay: [Int] = []
    }

    let outputUIDs: [String]
    let sourceSignature: [TapPlayer.Source]
    let sourceRouting: [[Int]]
    /// The AirPlay speakers with a mix of their own (their IDs), when an app is sent to one of
    /// them; none: every AirPlay speaker shares the one mix (`feeds[0]`).
    let airPlaySlots: [String]
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.mainmix", qos: .userInteractive)
    let sampleRate: Double
    /// One per AirPlay speaker with a mix of its own, or one for all of them.
    let feeds: [AirPlayFeed]

    // Kept alive for the audio thread, which only touches the raw pointers below.
    private let keep: [SharedValue]
    private let keepShapes: [ShapeControl]
    private let keepEffects: [EffectControl]
    private let state: UnsafeMutablePointer<MixState>

    /// How long the regular speakers are held back (frames at `sampleRate`).
    func setDelay(seconds: TimeInterval) {
        let frames = Int(seconds * sampleRate)
        state.pointee.delay = min(max(frames, 0), MixState.ringFrames - MixState.maxFrames - 1)
    }

    init(outputs: [TapOutput], silent: Bool, sources: [Source], airPlaySlots: [String], night: SharedValue, timeline: AirPlayTimeline) throws {
        guard let clock = outputs.first?.uid else { throw HALError(status: kAudioHardwareBadDeviceError, what: "find an output") }
        outputUIDs = outputs.map(\.uid)
        sourceSignature = sources.map(\.tap)
        sourceRouting = sources.map(\.airPlay)
        self.airPlaySlots = airPlaySlots
        keep = outputs.map(\.gain) + sources.flatMap { [$0.gain, $0.muted] } + [night]
        let flat = ShapeControl()
        let sourceShapes = sources.map { $0.shape ?? flat }
        keepShapes = outputs.map(\.shape) + sourceShapes
        keepEffects = sources.compactMap(\.effects)
        let clockDevice = HAL.device(forUID: clock)
        let rate = HAL.read(clockDevice, kAudioDevicePropertyNominalSampleRate, initial: Float64(48_000)) ?? 48_000
        sampleRate = rate
        for source in sources { source.effects?.prepare(sampleRate: rate) }

        // Input buffers: any input streams the speakers have come first, then one per tap.
        var deviceInputs = 0
        var outputMap: [Int] = []
        for (index, output) in outputs.enumerated() {
            let device = HAL.device(forUID: output.uid)
            deviceInputs += HAL.array(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, zero: AudioStreamID(0)).count
            let streams = HAL.array(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, zero: AudioStreamID(0)).count
            outputMap += Array(repeating: index, count: streams)
        }
        // Each output held back a little more to sound together with the slowest of them.
        let alignment = HAL.alignment(outputUIDs)
        let extra = outputMap.map { Int((alignment[$0] * rate).rounded()) }
        state = .allocate(capacity: 1)
        let masks: [UInt64] = sources.map { source in
            source.airPlay.filter { $0 >= 0 && $0 < min(airPlaySlots.count, 64) }.reduce(UInt64(0)) { $0 | (1 << UInt64($1)) }
        }
        state.initialize(to: MixState(firstTap: deviceInputs, silent: silent, sampleRate: rate, bufferExtra: extra, night: night.pointer,
                                      slots: min(airPlaySlots.count, 64), sourceSlots: masks,
                                      sourceGains: sources.map(\.gain.pointer), sourceMutes: sources.map(\.muted.pointer),
                                      sourceShapes: sourceShapes, sourceEffects: sources.map(\.effects),
                                      outputGains: outputs.map(\.gain.pointer),
                                      bufferShapes: outputMap.map { outputs[$0].shape }, outputMap: outputMap))
        // How long after the IO proc hands a frame over it's heard: the slowest output's latency,
        // since the others are held back to match it (HDMI and Bluetooth speakers can take a while).
        let latency = silent ? 0 : (outputUIDs.map { HAL.outputLatency(HAL.device(forUID: $0)) }.max() ?? 0)
        feeds = (0..<max(airPlaySlots.count, 1)).map { _ in AirPlayFeed(sampleRate: rate, timeline: timeline, outputLatency: latency) }

        // Once everything's set, a throw still runs deinit, which cleans up.
        var tapUUIDs: [UUID] = []
        for source in sources {
            let description: CATapDescription
            switch source.tap {
            case .processes(let objects): description = CATapDescription(stereoMixdownOfProcesses: objects)
            case .everythingExcept(let objects): description = CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
            }
            description.uuid = UUID()
            description.name = "Soundcheck"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            var tap = AudioObjectID.unknown
            let status = AudioHardwareCreateProcessTap(description, &tap)
            guard status == noErr else { throw HALError(status: status, what: "create a tap") }
            tapIDs.append(tap)
            tapUUIDs.append(description.uuid)
        }

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Soundcheck",
            kAudioAggregateDeviceUIDKey: AudioDevice.ownUIDPrefix + "main." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clock,
            kAudioAggregateDeviceClockDeviceKey: clock,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: outputUIDs.map {
                [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: $0 != clock]
            },
            kAudioAggregateDeviceTapListKey: tapUUIDs.map { [kAudioSubTapUIDKey: $0.uuidString, kAudioSubTapDriftCompensationKey: true] },
        ]
        if outputUIDs.count > 1 { description[kAudioAggregateDeviceIsStackedKey] = true }
        var aggregate = AudioObjectID.unknown
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw HALError(status: status, what: "create the main mix") }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        let state = self.state, feeds = self.feeds
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, output, outputTime in
            MainMixer.render(input, output, outputTime: outputTime, state: state, feeds: feeds)
        }
        if status == noErr {
            procID = proc
            status = AudioDeviceStart(aggregateID, procID)
        }
        guard status == noErr else { throw HALError(status: status, what: "start the main mix") }
        for feed in feeds { feed.start() }
    }

    deinit {
        teardown()
        state.pointee.release()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func invalidate() { teardown() }

    var isAlive: Bool { aggregateID.isValid && HAL.isAlive(aggregateID) }

    private func teardown() {
        for feed in feeds { feed.stop() }
        if aggregateID.isValid {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        tapIDs = []
        procID = nil
        aggregateID = .unknown
    }

    // MARK: Audio thread: no allocation, locks, Objective-C or logging below.

    /// Everything the audio thread uses, allocated up front.
    struct MixState {
        static let maxFrames = 8192
        /// The delay line: 4 s of stereo at 48 kHz (and then some).
        static let ringFrames = 262_144

        let firstTap: Int
        let silent: Bool
        let sources: Int
        let sourceGains: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        let sourceMutes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        let sourceCurrent: UnsafeMutablePointer<Float>
        let outputs: Int
        let outputGains: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        let outputMap: UnsafeMutablePointer<Int>
        let buffers: Int
        let mix: UnsafeMutablePointer<Float>
        let ring: UnsafeMutablePointer<Float>
        /// One source at a time, through its app's EQ, on its way into the mix.
        let scratch: UnsafeMutablePointer<Float>
        let sourceShapes: UnsafeMutablePointer<ShapeDSP>
        /// Each app's effects, after its EQ (not retained: the mixer keeps them).
        let sourceEffects: UnsafeMutablePointer<Unmanaged<EffectControl>?>
        let rate: Double
        let bufferShapes: UnsafeMutablePointer<ShapeDSP>
        /// How much later still each output buffer reads (to line up with the slowest output).
        let bufferExtra: UnsafeMutablePointer<Int>
        /// Night Mode (1: on) and each source's compressor.
        let night: UnsafeMutablePointer<Float>
        let sourceNight: UnsafeMutablePointer<Compressor>
        /// AirPlay speakers with a mix of their own: how many, each one's mix (the main mix plus
        /// the apps sent to it), and which of them each source goes to (0: the main mix).
        let slots: Int
        let slotMixes: UnsafeMutablePointer<Float>
        let sourceSlots: UnsafeMutablePointer<UInt64>
        var written = 0
        var delay = 0

        init(firstTap: Int, silent: Bool, sampleRate: Double, bufferExtra: [Int], night: UnsafeMutablePointer<Float>,
             slots: Int, sourceSlots: [UInt64], sourceGains: [UnsafeMutablePointer<Float>],
             sourceMutes: [UnsafeMutablePointer<Float>], sourceShapes: [ShapeControl], sourceEffects: [EffectControl?],
             outputGains: [UnsafeMutablePointer<Float>], bufferShapes: [ShapeControl], outputMap: [Int]) {
            self.firstTap = firstTap
            rate = sampleRate
            self.silent = silent
            sources = sourceGains.count
            self.sourceGains = .allocate(capacity: max(sources, 1))
            self.sourceMutes = .allocate(capacity: max(sources, 1))
            sourceCurrent = .allocate(capacity: max(sources, 1))
            for index in 0..<sources {
                (self.sourceGains + index).initialize(to: sourceGains[index])
                (self.sourceMutes + index).initialize(to: sourceMutes[index])
                (sourceCurrent + index).initialize(to: 0)
            }
            outputs = outputGains.count
            self.outputGains = .allocate(capacity: max(outputs, 1))
            for index in 0..<outputs { (self.outputGains + index).initialize(to: outputGains[index]) }
            buffers = outputMap.count
            self.outputMap = .allocate(capacity: max(buffers, 1))
            for index in 0..<buffers { (self.outputMap + index).initialize(to: outputMap[index]) }
            mix = .allocate(capacity: Self.maxFrames * 2)
            mix.initialize(repeating: 0, count: Self.maxFrames * 2)
            ring = .allocate(capacity: Self.ringFrames * 2)
            ring.initialize(repeating: 0, count: Self.ringFrames * 2)
            scratch = .allocate(capacity: Self.maxFrames * 2)
            scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
            self.sourceShapes = .allocate(capacity: max(sources, 1))
            for index in 0..<sources {
                (self.sourceShapes + index).initialize(to: ShapeDSP(control: sourceShapes[index], sampleRate: sampleRate))
            }
            self.sourceEffects = .allocate(capacity: max(sources, 1))
            for index in 0..<max(sources, 1) {
                let effects = index < sourceEffects.count ? sourceEffects[index] : nil
                (self.sourceEffects + index).initialize(to: effects.map { Unmanaged.passUnretained($0) })
            }
            self.bufferShapes = .allocate(capacity: max(buffers, 1))
            for index in 0..<buffers {
                (self.bufferShapes + index).initialize(to: ShapeDSP(control: bufferShapes[index], sampleRate: sampleRate))
            }
            self.night = night
            self.slots = slots
            slotMixes = .allocate(capacity: max(slots, 1) * Self.maxFrames * 2)
            slotMixes.initialize(repeating: 0, count: max(slots, 1) * Self.maxFrames * 2)
            self.sourceSlots = .allocate(capacity: max(sources, 1))
            for index in 0..<max(sources, 1) { (self.sourceSlots + index).initialize(to: index < sourceSlots.count ? sourceSlots[index] : 0) }
            sourceNight = .allocate(capacity: max(sources, 1))
            for index in 0..<max(sources, 1) { (sourceNight + index).initialize(to: .nightMode(sampleRate: sampleRate)) }
            self.bufferExtra = .allocate(capacity: max(buffers, 1))
            for index in 0..<buffers {
                (self.bufferExtra + index).initialize(to: min(max(index < bufferExtra.count ? bufferExtra[index] : 0, 0), 48_000))
            }
        }

        func release() {
            for index in 0..<sources { sourceShapes[index].release() }
            for index in 0..<buffers { bufferShapes[index].release() }
            sourceShapes.deallocate()
            sourceEffects.deallocate()
            bufferShapes.deallocate()
            bufferExtra.deallocate()
            sourceNight.deallocate()
            slotMixes.deallocate()
            sourceSlots.deallocate()
            scratch.deallocate()
            sourceGains.deallocate()
            sourceMutes.deallocate()
            sourceCurrent.deallocate()
            outputGains.deallocate()
            outputMap.deallocate()
            mix.deallocate()
            ring.deallocate()
        }
    }

    private static func render(_ inputList: UnsafePointer<AudioBufferList>, _ outputList: UnsafeMutablePointer<AudioBufferList>,
                               outputTime: UnsafePointer<AudioTimeStamp>, state: UnsafeMutablePointer<MixState>, feeds: [AirPlayFeed]) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        var frames = 0
        for buffer in outputs where buffer.mData != nil {
            frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(Int(buffer.mNumberChannels), 1))
            break
        }
        frames = min(frames, MixState.maxFrames)
        let mix = state.pointee.mix
        memset(mix, 0, frames * 2 * MemoryLayout<Float>.size)
        let slots = state.pointee.slots, slotMixes = state.pointee.slotMixes, stride = MixState.maxFrames * 2
        for slot in 0..<slots { memset(slotMixes + slot * stride, 0, frames * 2 * MemoryLayout<Float>.size) }

        // Add up the taps at their levels (eased, so changes don't click), each through its app's EQ.
        let scratch = state.pointee.scratch
        for source in 0..<state.pointee.sources {
            let index = state.pointee.firstTap + source
            guard index < inputs.count, let data = inputs[index].mData else { continue }
            let channels = max(Int(inputs[index].mNumberChannels), 1)
            let available = min(frames, Int(inputs[index].mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let samples = data.assumingMemoryBound(to: Float.self)
            let target = state.pointee.sourceMutes[source].pointee > 0.5 ? 0 : state.pointee.sourceGains[source].pointee
            var gain = state.pointee.sourceCurrent[source]
            for frame in 0..<available {
                gain += (target - gain) * 0.002
                let left = samples[frame * channels]
                let right = channels > 1 ? samples[frame * channels + 1] : left
                scratch[frame * 2] = left * gain
                scratch[frame * 2 + 1] = right * gain
            }
            state.pointee.sourceCurrent[source] = gain
            state.pointee.sourceShapes[source].process(scratch, frames: available, channels: 2)
            state.pointee.sourceEffects[source]?.takeUnretainedValue().process(scratch, frames: available, sampleRate: state.pointee.rate)
            state.pointee.sourceNight[source].process(scratch, frames: available, channels: 2, on: state.pointee.night.pointee > 0.5)
            // The main mix, or only the AirPlay speakers it's sent to.
            let mask = state.pointee.sourceSlots[source]
            if mask == 0 {
                for sample in 0..<(available * 2) { mix[sample] += scratch[sample] }
            } else {
                for slot in 0..<slots where mask & (1 << UInt64(slot)) != 0 {
                    let slotMix = slotMixes + slot * stride
                    for sample in 0..<(available * 2) { slotMix[sample] += scratch[sample] }
                }
            }
        }

        // To AirPlay as it is (the speakers add their own delay), stamped with the moment this mix
        // would reach the Mac's own speakers if it weren't held back: the shared reference point.
        let stamped = outputTime.pointee.mFlags.contains(.hostTimeValid)
        let hostTime = stamped ? outputTime.pointee.mHostTime : mach_absolute_time()
        if slots == 0 {
            feeds[0].push(mix, frames: frames, hostTime: hostTime)
        } else {
            // Each AirPlay speaker with a mix of its own: the main mix plus the apps sent to it.
            for slot in 0..<min(slots, feeds.count) {
                let slotMix = slotMixes + slot * stride
                for sample in 0..<(frames * 2) { slotMix[sample] += mix[sample] }
                feeds[slot].push(slotMix, frames: frames, hostTime: hostTime)
            }
        }

        // Into the delay line, and out of it, held back, to the regular speakers.
        let ring = state.pointee.ring
        let size = MixState.ringFrames
        let start = state.pointee.written
        for frame in 0..<frames {
            let slot = (start + frame) % size
            ring[slot * 2] = mix[frame * 2]
            ring[slot * 2 + 1] = mix[frame * 2 + 1]
        }
        state.pointee.written = start + frames
        let delay = state.pointee.delay
        for index in 0..<outputs.count {
            let buffer = outputs[index]
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            guard !state.pointee.silent, index < state.pointee.buffers else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let gain = state.pointee.outputGains[state.pointee.outputMap[index]].pointee
            let out = data.assumingMemoryBound(to: Float.self)
            let held = min(delay + state.pointee.bufferExtra[index], MixState.ringFrames - MixState.maxFrames - 1)
            for frame in 0..<count {
                let position = start + frame - held
                guard position >= 0 else { continue }
                let slot = position % size
                let left = ring[slot * 2] * gain, right = ring[slot * 2 + 1] * gain
                if channels == 1 {
                    out[frame] = (left + right) * 0.5
                } else {
                    out[frame * channels] = left
                    out[frame * channels + 1] = right
                }
            }
            // The speaker's own shape, then peaks rounded off.
            state.pointee.bufferShapes[index].process(out, frames: count, channels: channels)
            for frame in 0..<count {
                out[frame * channels] = softLimit(out[frame * channels])
                if channels > 1 { out[frame * channels + 1] = softLimit(out[frame * channels + 1]) }
            }
        }
    }
}

/// The mix on its way to AirPlay: the audio thread drops it into a ring buffer, and a feeder on
/// its own queue converts it to 44.1 kHz 16-bit and hands it to the AirPlay sessions.
final class AirPlayFeed: @unchecked Sendable {
    private let sampleRate: Double
    private let timeline: AirPlayTimeline
    /// Seconds between the IO proc's output time and the regular speakers playing it.
    private let outputLatency: TimeInterval
    private static let capacity = 131_072 // frames
    private let ring: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// The host time of the frame at `writeIndex` (the end of the latest push).
    private let writeHost = Atomic<UInt64>(0)
    private let ticksPerSecond: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }()
    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.airplayfeed", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    /// A session, how much earlier (frames) it gets the sound to line it up, and its speaker's
    /// shape (on the feeder's queue only).
    private final class Target {
        let session: any SpeakerSession
        /// Changed under the lock (read with it too).
        var earlier: Int64
        let control: ShapeControl?
        /// Only touched on the feeder's queue.
        var shape: ShapeDSP?
        init(session: any SpeakerSession, earlier: Int64, shape: ShapeControl?) {
            self.session = session
            self.earlier = earlier
            control = shape
            self.shape = shape.map { ShapeDSP(control: $0, sampleRate: 44_100) }
        }
        deinit { shape?.release() }
    }
    private var sessions: [Target] = []
    /// Shaped samples for one session (feeder's queue only).
    private var shaped: [Float] = []
    private var shapedOut: [Int16] = []
    /// Where on the shared AirPlay timeline the next frame goes; nil until the first frames.
    private var position: Int64?
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat?

    init(sampleRate: Double, timeline: AirPlayTimeline, outputLatency: TimeInterval) {
        self.sampleRate = sampleRate
        self.timeline = timeline
        self.outputLatency = outputLatency
        ring = .allocate(capacity: Self.capacity * 2)
        ring.initialize(repeating: 0, count: Self.capacity * 2)
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true)
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true)
        if let inputFormat, let outputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        } else {
            converter = nil
        }
    }

    deinit {
        stop()
        ring.deallocate()
    }

    /// The sessions to feed. Ones already fed keep their EQ's state, so nothing clicks.
    func setSessions(_ sessions: [(session: any SpeakerSession, earlier: Int64, shape: ShapeControl?)]) {
        lock.lock()
        let current = self.sessions
        self.sessions = sessions.map { wanted in
            if let target = current.first(where: { $0.session === wanted.session && $0.control === wanted.shape }) {
                target.earlier = wanted.earlier
                return target
            }
            return Target(session: wanted.session, earlier: wanted.earlier, shape: wanted.shape)
        }
        lock.unlock()
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Audio thread: interleaved stereo float at `sampleRate`, whose first frame is heard (on the
    /// Mac's speakers, before any holding back) at `hostTime`. Drops the newest frames if the
    /// feeder has fallen a whole ring behind.
    func push(_ samples: UnsafePointer<Float>, frames: Int, hostTime: UInt64) {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard frames > 0, write - read + frames <= Self.capacity else { return }
        for frame in 0..<frames {
            let slot = (write + frame) % Self.capacity
            ring[slot * 2] = samples[frame * 2]
            ring[slot * 2 + 1] = samples[frame * 2 + 1]
        }
        writeHost.store(hostTime &+ UInt64(Double(frames) / sampleRate * ticksPerSecond), ordering: .relaxed)
        writeIndex.store(write + frames, ordering: .releasing)
    }

    /// Feeder: whatever has arrived, converted and sent on.
    private func drain() {
        let read = readIndex.load(ordering: .relaxed)
        // The newest frame's index and host time, read so they belong together.
        var write = 0, endHost: UInt64 = 0
        repeat {
            endHost = writeHost.load(ordering: .relaxed)
            write = writeIndex.load(ordering: .acquiring)
        } while writeHost.load(ordering: .relaxed) != endHost
        let available = write - read
        let firstHost = endHost &- UInt64(Double(available) / sampleRate * ticksPerSecond)
        // No AirPlay speakers connected (yet): nothing to convert, and the next one starts afresh.
        lock.lock()
        let idle = sessions.isEmpty
        lock.unlock()
        if idle {
            readIndex.store(write, ordering: .releasing)
            position = nil
            return
        }
        guard available > 0, let converter, let inputFormat, let outputFormat,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(available)) else { return }
        let destination = input.floatChannelData![0]
        for frame in 0..<available {
            let slot = (read + frame) % Self.capacity
            destination[frame * 2] = ring[slot * 2]
            destination[frame * 2 + 1] = ring[slot * 2 + 1]
        }
        input.frameLength = AVAudioFrameCount(available)
        readIndex.store(write, ordering: .releasing)

        let capacity = AVAudioFrameCount(Double(available) * 44_100 / sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        let frames = Int(output.frameLength)
        guard frames > 0, let samples = output.int16ChannelData?[0] else { return }
        // Their place on the timeline is the moment they reach the Mac's speakers (before holding
        // back), so a speaker's playback delay is exactly how long to hold those back. Counting
        // on from the last batch keeps the sound seamless. The output's clock and the Mac's
        // aren't quite the same, so the count slowly drifts from the stamps: past 1 ms it's eased
        // back one frame per batch (a repeated or overwritten frame, which can't be heard), and
        // past 100 ms (a hiccup) it starts over.
        let stamp = timeline.position(atHostTime: firstHost &+ UInt64(outputLatency * ticksPerSecond))
        var at = position ?? stamp
        var repeatFirst = false
        if abs(at - stamp) > 4_410 {
            at = stamp
        } else if at < stamp - 44 {
            at += 1
            repeatFirst = true // fill the frame skipped over with a copy of the next
        } else if at > stamp + 44 {
            at -= 1
        }
        position = at + Int64(frames)
        guard at >= 1 else { return }
        lock.lock()
        let targets = sessions.map { (target: $0, earlier: $0.earlier) }
        lock.unlock()
        for (target, earlier) in targets where at - earlier >= 1 {
            let start = UInt64(at - earlier)
            // The speaker's own shape (EQ, balance, mono) on a copy, when it has one.
            guard target.shape?.isActive() == true else {
                if repeatFirst { target.session.enqueue(samples, frames: 1, position: start - 1) }
                target.session.enqueue(samples, frames: frames, position: start)
                continue
            }
            if shaped.count < frames * 2 {
                shaped = [Float](repeating: 0, count: frames * 2)
                shapedOut = [Int16](repeating: 0, count: frames * 2)
            }
            shaped.withUnsafeMutableBufferPointer { floats in
                shapedOut.withUnsafeMutableBufferPointer { ints in
                    guard let base = floats.baseAddress, let out = ints.baseAddress else { return }
                    for sample in 0..<(frames * 2) { base[sample] = Float(samples[sample]) / 32_768 }
                    target.shape?.process(base, frames: frames, channels: 2)
                    for sample in 0..<(frames * 2) {
                        out[sample] = Int16(max(-32_768, min(32_767, (softLimit(base[sample]) * 32_768).rounded())))
                    }
                    if repeatFirst { target.session.enqueue(out, frames: 1, position: start - 1) }
                    target.session.enqueue(out, frames: frames, position: start)
                }
            }
        }
    }
}
