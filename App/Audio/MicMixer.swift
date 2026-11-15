import AudioToolbox
import CoreAudio
import Foundation

/// Soundcheck Mic's mix: the real microphones (each through its own EQ), plus (with Route) each
/// chosen app's sound at its own level, added together and written to Soundcheck Mic's hidden
/// feed, which the driver plays back as Soundcheck Mic's input. The apps keep playing normally
/// (their taps don't mute them). With Hear Yourself, the microphones (not the apps, which you
/// already hear) also play through the speakers in use.
///
/// A private aggregate device of the feed (the clock), the microphones, the speakers you hear
/// yourself on and one tap per app, with an IO proc that adds them up. It also measures each
/// one's level for the panel.
final class MicMixer: @unchecked Sendable {
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.route", qos: .userInteractive)

    /// Voice Cleanup on the microphones, and routed apps lowered while you talk (each 1: on).
    struct Voice {
        let cleanup: SharedValue
        let duckApps: SharedValue
    }

    /// Where you hear yourself: the speakers (by UID), their software gains and which microphones
    /// each plays (nil: the ones going into Soundcheck Mic), and how loud.
    struct Monitor {
        let outputs: [(uid: String, gain: SharedValue, microphones: [String]?)]
        let level: SharedValue
    }

    // Kept alive for the audio thread, which only touches the raw pointers below.
    private let appGains: [SharedValue]
    private let shapes: [ShapeControl]
    private let state: UnsafeMutablePointer<MixState>
    private let sourceIDs: [String]
    let monitorUIDs: [String]

    /// A microphone's or an app's level right now (0...1).
    func level(_ id: String) -> Float {
        guard let index = sourceIDs.firstIndex(of: id) else { return 0 }
        return min(state.pointee.peaks[index], 1)
    }

    /// - Parameters:
    ///   - microphones: each microphone's UID, its gain (0 when it's turned all the way down or
    ///     muted; its level is otherwise the device's own), its EQ, and whether it goes into
    ///     Soundcheck Mic (one that doesn't is only there to be heard on a speaker).
    ///   - apps: each routed app's id, its processes, and its level in the mix.
    ///   - monitor: the speakers to hear the microphones on (Hear Yourself), if any.
    init(feedUID: String, microphones: [(uid: String, gain: SharedValue, shape: ShapeControl, feeds: Bool)],
         apps: [(id: String, processes: [AudioObjectID], gain: SharedValue)], monitor: Monitor?, voice: Voice) throws {
        let microphoneUIDs = microphones.map(\.uid)
        appGains = apps.map(\.gain) + microphones.map(\.gain) + (monitor.map { [$0.level] + $0.outputs.map(\.gain) } ?? [])
            + [voice.cleanup, voice.duckApps]
        shapes = microphones.map(\.shape)
        sourceIDs = microphoneUIDs + apps.map(\.id)

        // The aggregate's input buffers: each microphone's streams in order, then one per tap.
        var layout: [MixState.Input] = []
        for (index, uid) in microphoneUIDs.enumerated() {
            let streams = HAL.array(HAL.device(forUID: uid), kAudioDevicePropertyStreams,
                                    scope: kAudioObjectPropertyScopeInput, zero: AudioStreamID(0)).count
            for stream in 0..<streams {
                layout.append(MixState.Input(mixed: stream == 0, gain: microphones[index].gain.pointer,
                                             slot: stream == 0 ? index : -1, microphone: stream == 0 ? index : -1,
                                             feeds: microphones[index].feeds))
            }
        }
        for (index, app) in apps.enumerated() {
            layout.append(MixState.Input(mixed: true, gain: app.gain.pointer, slot: microphoneUIDs.count + index,
                                         microphone: -1, feeds: true))
        }

        // The sub-devices: the feed, the microphones, then the speakers you hear yourself on that
        // aren't already in (a USB mic with a headphone jack is both).
        let monitorOutputs = monitor?.outputs ?? []
        monitorUIDs = monitorOutputs.map(\.uid)
        let extra = monitorUIDs.filter { !microphoneUIDs.contains($0) && $0 != feedUID }
        let subDeviceUIDs = [feedUID] + microphoneUIDs + extra
        // The output buffers, in sub-device order: the feed's first stream is Soundcheck Mic; a
        // speaker's streams play the microphones (by its index in the monitor list); the rest
        // stay silent.
        var roles: [Int] = []
        for (position, uid) in subDeviceUIDs.enumerated() {
            let streams = HAL.array(HAL.device(forUID: uid), kAudioDevicePropertyStreams,
                                    scope: kAudioObjectPropertyScopeOutput, zero: AudioStreamID(0)).count
            for stream in 0..<streams {
                if position == 0 {
                    roles.append(stream == 0 ? MixState.feedRole : MixState.silentRole)
                } else if let target = monitorUIDs.firstIndex(of: uid) {
                    roles.append(target)
                } else {
                    roles.append(MixState.silentRole)
                }
            }
        }

        // Which microphones each speaker plays, one bit per microphone.
        let masks: [UInt64] = monitorOutputs.map { output in
            var mask: UInt64 = 0
            for (index, microphone) in microphones.enumerated().prefix(64) {
                let heard = output.microphones.map { $0.contains(microphone.uid) } ?? microphone.feeds
                if heard { mask |= 1 << UInt64(index) }
            }
            return mask
        }

        let feedDevice = HAL.device(forUID: feedUID)
        let rate = HAL.read(feedDevice, kAudioDevicePropertyNominalSampleRate, initial: Float64(48_000)) ?? 48_000
        state = .allocate(capacity: 1)
        state.initialize(to: MixState(inputs: layout, sources: sourceIDs.count, microphoneShapes: microphones.map(\.shape),
                                      sampleRate: rate, roles: roles,
                                      monitorGains: monitorOutputs.map(\.gain.pointer), monitorMasks: masks,
                                      monitorLevel: monitor?.level.pointer,
                                      cleanup: voice.cleanup.pointer, duckApps: voice.duckApps.pointer))

        // Once everything's set, a throw still runs deinit, which cleans up.
        var tapUUIDs: [UUID] = []
        for app in apps {
            let description = CATapDescription(stereoMixdownOfProcesses: app.processes)
            description.uuid = UUID()
            description.name = "Soundcheck Mic"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tap = AudioObjectID.unknown
            let status = AudioHardwareCreateProcessTap(description, &tap)
            guard status == noErr else { throw HALError(status: status, what: "create a route tap") }
            tapIDs.append(tap)
            tapUUIDs.append(description.uuid)
        }

        let subDevices: [[String: Any]] = subDeviceUIDs.map { uid in
            [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: uid != feedUID]
        }
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Soundcheck Mic",
            kAudioAggregateDeviceUIDKey: AudioDevice.ownUIDPrefix + "route." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: feedUID,
            kAudioAggregateDeviceClockDeviceKey: feedUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        if !tapUUIDs.isEmpty {
            description[kAudioAggregateDeviceTapAutoStartKey] = true
            description[kAudioAggregateDeviceTapListKey] = tapUUIDs.map { [kAudioSubTapUIDKey: $0.uuidString, kAudioSubTapDriftCompensationKey: true] }
        }
        var aggregate = AudioObjectID.unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw HALError(status: status, what: "create the Soundcheck Mic mix") }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        let state = self.state
        var result = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, output, _ in
            MicMixer.mix(input, into: output, state: state)
        }
        if result == noErr {
            procID = proc
            result = AudioDeviceStart(aggregateID, procID)
        }
        guard result == noErr else { throw HALError(status: result, what: "start Soundcheck Mic") }
    }

    deinit {
        teardown()
        state.pointee.release()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func invalidate() { teardown() }

    private func teardown() {
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
        static let feedRole = -1
        static let silentRole = -2

        /// One of the aggregate's input buffers: whether it's mixed in (each microphone's first
        /// stream, and every tap), its gain, which level slot it fills (-1: none), which
        /// microphone's EQ it goes through (-1: an app, no EQ) and whether it goes into Soundcheck
        /// Mic (a microphone only there to be heard on a speaker doesn't).
        struct Input {
            let mixed: Bool
            let gain: UnsafeMutablePointer<Float>
            let slot: Int
            let microphone: Int
            let feeds: Bool
        }

        let inputCount: Int
        let inputs: UnsafeMutablePointer<Input>
        /// The latest peak of each microphone (after its EQ), then each app (0...1, before its
        /// gain: the panel's shade scales it by the slider).
        let peaks: UnsafeMutablePointer<Float>
        let sourceCount: Int
        let microphoneCount: Int
        let microphoneShapes: UnsafeMutablePointer<ShapeDSP>
        /// What each output buffer plays (a monitor index, `feedRole` or `silentRole`).
        let roleCount: Int
        let roles: UnsafeMutablePointer<Int>
        let monitorGains: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        /// Which microphones each speaker plays (bit n: microphone n).
        let monitorMasks: UnsafeMutablePointer<UInt64>
        let monitorLevel: UnsafeMutablePointer<Float>?
        var monitorCurrent: Float = 0
        let ramp: Float
        /// One microphone at a time through its EQ, the microphones going into Soundcheck Mic
        /// added up, and each microphone's own sound this cycle (for the speakers that play it).
        let scratch: UnsafeMutablePointer<Float>
        let microphoneMix: UnsafeMutablePointer<Float>
        let microphoneSounds: UnsafeMutablePointer<Float>
        /// Voice Cleanup (each microphone's), and the apps lowered while you talk.
        let cleanup: UnsafeMutablePointer<Float>
        let duckApps: UnsafeMutablePointer<Float>
        let microphoneCleanup: UnsafeMutablePointer<VoiceCleanup>
        var ducker: VoiceDucker

        init(inputs: [Input], sources: Int, microphoneShapes: [ShapeControl], sampleRate: Double, roles: [Int],
             monitorGains: [UnsafeMutablePointer<Float>], monitorMasks: [UInt64], monitorLevel: UnsafeMutablePointer<Float>?,
             cleanup: UnsafeMutablePointer<Float>, duckApps: UnsafeMutablePointer<Float>) {
            self.cleanup = cleanup
            self.duckApps = duckApps
            microphoneCleanup = .allocate(capacity: max(microphoneShapes.count, 1))
            for index in 0..<max(microphoneShapes.count, 1) { (microphoneCleanup + index).initialize(to: VoiceCleanup(sampleRate: sampleRate)) }
            ducker = VoiceDucker(sampleRate: sampleRate)
            inputCount = inputs.count
            self.inputs = .allocate(capacity: max(inputs.count, 1))
            for (index, input) in inputs.enumerated() { (self.inputs + index).initialize(to: input) }
            sourceCount = max(sources, 1)
            peaks = .allocate(capacity: sourceCount)
            peaks.initialize(repeating: 0, count: sourceCount)
            microphoneCount = microphoneShapes.count
            self.microphoneShapes = .allocate(capacity: max(microphoneCount, 1))
            for (index, shape) in microphoneShapes.enumerated() {
                (self.microphoneShapes + index).initialize(to: ShapeDSP(control: shape, sampleRate: sampleRate))
            }
            roleCount = roles.count
            self.roles = .allocate(capacity: max(roles.count, 1))
            for (index, role) in roles.enumerated() { (self.roles + index).initialize(to: role) }
            self.monitorGains = .allocate(capacity: max(monitorGains.count, 1))
            for (index, gain) in monitorGains.enumerated() { (self.monitorGains + index).initialize(to: gain) }
            self.monitorMasks = .allocate(capacity: max(monitorMasks.count, 1))
            for (index, mask) in monitorMasks.enumerated() { (self.monitorMasks + index).initialize(to: mask) }
            self.monitorLevel = monitorLevel
            ramp = 1 - exp(-1 / (Float(sampleRate > 0 ? sampleRate : 48_000) * 0.02))
            scratch = .allocate(capacity: Self.maxFrames * 2)
            scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
            microphoneMix = .allocate(capacity: Self.maxFrames * 2)
            microphoneMix.initialize(repeating: 0, count: Self.maxFrames * 2)
            microphoneSounds = .allocate(capacity: max(microphoneCount, 1) * Self.maxFrames * 2)
            microphoneSounds.initialize(repeating: 0, count: max(microphoneCount, 1) * Self.maxFrames * 2)
        }

        func release() {
            for index in 0..<microphoneCount { microphoneShapes[index].release() }
            inputs.deallocate()
            peaks.deallocate()
            microphoneShapes.deallocate()
            roles.deallocate()
            monitorGains.deallocate()
            monitorMasks.deallocate()
            microphoneCleanup.deallocate()
            scratch.deallocate()
            microphoneMix.deallocate()
            microphoneSounds.deallocate()
        }
    }

    /// Adds up the mixed input buffers at their gains (a mono microphone goes to both channels):
    /// the microphones through their EQ, then the apps. Soundcheck Mic gets everything; the
    /// speakers you hear yourself on get the microphones.
    private static func mix(_ inputList: UnsafePointer<AudioBufferList>, into outputList: UnsafeMutablePointer<AudioBufferList>,
                            state: UnsafeMutablePointer<MixState>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        guard outputs.count > 0, let data = outputs[0].mData else { return }
        let out = data.assumingMemoryBound(to: Float.self)
        let outChannels = max(Int(outputs[0].mNumberChannels), 1)
        let frames = min(Int(outputs[0].mDataByteSize) / (MemoryLayout<Float>.size * outChannels), MixState.maxFrames)
        memset(data, 0, Int(outputs[0].mDataByteSize))
        let scratch = state.pointee.scratch
        let microphones = state.pointee.microphoneMix
        let sounds = state.pointee.microphoneSounds
        let stride = MixState.maxFrames * 2
        memset(microphones, 0, frames * 2 * MemoryLayout<Float>.size)
        for microphone in 0..<state.pointee.microphoneCount {
            memset(sounds + microphone * stride, 0, frames * 2 * MemoryLayout<Float>.size)
        }

        // The microphones first (through their EQ and Voice Cleanup, which also hears whether
        // you're talking), then the apps (lowered while you talk, with that option on).
        let cleanupOn = state.pointee.cleanup.pointee > 0.5
        var talking = false
        for index in 0..<min(inputs.count, state.pointee.inputCount) where state.pointee.inputs[index].mixed {
            let input = state.pointee.inputs[index]
            guard input.microphone >= 0, let source = inputs[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(Int(inputs[index].mNumberChannels), 1)
            let available = min(frames, Int(inputs[index].mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let gain = input.gain.pointee
            for frame in 0..<available {
                let left = source[frame * channels]
                scratch[frame * 2] = left
                scratch[frame * 2 + 1] = channels > 1 ? source[frame * channels + 1] : left
            }
            state.pointee.microphoneShapes[input.microphone].process(scratch, frames: available, channels: 2)
            state.pointee.microphoneCleanup[input.microphone].process(scratch, frames: available, channels: 2, on: cleanupOn)
            // Only a microphone that's on (and in Soundcheck Mic) counts as you talking.
            if input.feeds && gain > 0 && state.pointee.microphoneCleanup[input.microphone].talking { talking = true }
            let sound = sounds + input.microphone * stride
            var peak: Float = 0
            for sample in 0..<(available * 2) {
                peak = max(peak, abs(scratch[sample]))
                let value = scratch[sample] * gain
                sound[sample] = value
                if input.feeds { microphones[sample] += value }
            }
            if input.slot >= 0 && input.slot < state.pointee.sourceCount {
                state.pointee.peaks[input.slot] = max(peak, state.pointee.peaks[input.slot] * 0.85) // held briefly, so no frame misses a peak
            }
        }
        let duck = state.pointee.ducker.gains(frames: frames, talking: talking, on: state.pointee.duckApps.pointee > 0.5)
        let duckStep = frames > 0 ? (duck.end - duck.start) / Float(frames) : 0
        for index in 0..<min(inputs.count, state.pointee.inputCount) where state.pointee.inputs[index].mixed {
            let input = state.pointee.inputs[index]
            guard input.microphone < 0, let source = inputs[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(Int(inputs[index].mNumberChannels), 1)
            let available = min(frames, Int(inputs[index].mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let gain = input.gain.pointee
            var peak: Float = 0
            for frame in 0..<available {
                let left = source[frame * channels]
                let right = channels > 1 ? source[frame * channels + 1] : left
                let lowered = gain * (duck.start + duckStep * Float(frame))
                out[frame * outChannels] += left * lowered
                if outChannels > 1 { out[frame * outChannels + 1] += right * lowered }
                peak = max(peak, abs(left), abs(right))
            }
            if input.slot >= 0 && input.slot < state.pointee.sourceCount {
                state.pointee.peaks[input.slot] = max(peak, state.pointee.peaks[input.slot] * 0.85)
            }
        }
        // Soundcheck Mic: the apps plus the microphones, kept from clipping hard.
        for frame in 0..<frames {
            out[frame * outChannels] = max(-1, min(1, out[frame * outChannels] + microphones[frame * 2]))
            if outChannels > 1 { out[frame * outChannels + 1] = max(-1, min(1, out[frame * outChannels + 1] + microphones[frame * 2 + 1])) }
        }

        // Hear Yourself: each speaker's microphones on it (eased, so turning it up or down doesn't
        // click); any other output buffers stay silent.
        let target = state.pointee.monitorLevel?.pointee ?? 0
        let start = state.pointee.monitorCurrent
        var end = start
        for index in 1..<max(outputs.count, 1) {
            let buffer = outputs[index]
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            guard index < state.pointee.roleCount else { continue }
            let role = state.pointee.roles[index]
            guard role >= 0 else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let speaker = state.pointee.monitorGains[role].pointee
            let mask = state.pointee.monitorMasks[role]
            let samples = data.assumingMemoryBound(to: Float.self)
            var level = start
            for frame in 0..<count {
                level += (target - level) * state.pointee.ramp
                let gain = level * speaker
                var leftSum: Float = 0, rightSum: Float = 0
                for microphone in 0..<min(state.pointee.microphoneCount, 64) where mask & (1 << UInt64(microphone)) != 0 {
                    leftSum += sounds[microphone * stride + frame * 2]
                    rightSum += sounds[microphone * stride + frame * 2 + 1]
                }
                let left = leftSum * gain, right = rightSum * gain
                if channels == 1 {
                    samples[frame] = softLimit((left + right) * 0.5)
                } else {
                    samples[frame * channels] = softLimit(left)
                    samples[frame * channels + 1] = softLimit(right)
                }
            }
            end = level
        }
        state.pointee.monitorCurrent = end
    }
}

/// The Soundcheck Mic driver: a virtual microphone (and its hidden feed) that macOS
/// loads from /Library/Audio/Plug-Ins/HAL. Soundcheck carries a copy and installs it when you
/// add Soundcheck Mic.
enum MicDriver {
    static let microphoneUID = "com.mylesdean.Soundcheck.Microphone"
    static let feedUID = "com.mylesdean.Soundcheck.MicrophoneFeed"
    static let installPath = "/Library/Audio/Plug-Ins/HAL/SoundcheckMic.driver"

    static var isInstalled: Bool {
        HAL.device(forUID: microphoneUID).isValid && HAL.device(forUID: feedUID).isValid
    }

    /// Copies the driver into place and restarts macOS's audio service so it loads (sound cuts
    /// out for a moment). macOS asks for an administrator password.
    static func install(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let source = Bundle.main.url(forResource: "SoundcheckMic", withExtension: "driver")?.path,
              !source.contains("'"), !source.contains("\"") else {
            Task { @MainActor in done(false) }
            return
        }
        let command = [
            "/bin/mkdir -p /Library/Audio/Plug-Ins/HAL",
            "/bin/rm -rf '\(installPath)'",
            "/usr/bin/ditto '\(source)' '\(installPath)'",
            "/usr/sbin/chown -R root:wheel '\(installPath)'",
            "/usr/bin/killall coreaudiod",
        ].joined(separator: " && ")
        let script = "do shell script \"\(command)\" with prompt \"Soundcheck wants to add Soundcheck Mic, so apps can hear the sound you route to it.\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error { log.error("Installing the microphone failed: \(String(describing: error), privacy: .public)") }
            // macOS's audio service takes a few seconds to come back with the new devices.
            var installed = false
            for _ in 0..<60 where error == nil {
                if isInstalled { installed = true; break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            Task { @MainActor in done(installed) }
        }
    }
}

/// Measures one app's sound for the level shade in its slider, while the panel is open: a tap
/// that doesn't mute the app, in a private aggregate whose IO proc only takes the peak (and
/// writes silence).
final class TapMeter: @unchecked Sendable {
    let processes: [AudioObjectID]
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.meter", qos: .utility)
    private let peak: UnsafeMutablePointer<Float>

    var level: Float { min(peak.pointee, 1) }

    init(processes: [AudioObjectID], clockUID: String) throws {
        self.processes = processes
        peak = .allocate(capacity: 1)
        peak.initialize(to: 0)

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Soundcheck Meter"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID.unknown
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw HALError(status: status, what: "create a meter tap") }
        tapID = tap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Soundcheck Meter",
            kAudioAggregateDeviceUIDKey: AudioDevice.ownUIDPrefix + "meter." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID.unknown
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else { throw HALError(status: status, what: "create a meter") }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        let peak = self.peak
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, output, _ in
            TapMeter.measure(input, output, peak: peak)
        }
        if status == noErr {
            procID = proc
            status = AudioDeviceStart(aggregateID, procID)
        }
        guard status == noErr else { throw HALError(status: status, what: "start a meter") }
    }

    deinit {
        teardown()
        peak.deallocate()
    }

    func invalidate() { teardown() }

    private func teardown() {
        if aggregateID.isValid {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    // Audio thread.
    private static func measure(_ inputList: UnsafePointer<AudioBufferList>, _ outputList: UnsafeMutablePointer<AudioBufferList>,
                                peak: UnsafeMutablePointer<Float>) {
        for buffer in UnsafeMutableAudioBufferListPointer(outputList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        guard inputs.count > 0, let data = inputs[inputs.count - 1].mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(inputs[inputs.count - 1].mDataByteSize) / MemoryLayout<Float>.size
        var loudest: Float = 0
        for index in 0..<count { loudest = max(loudest, abs(samples[index])) }
        peak.pointee = max(loudest, peak.pointee * 0.85)
    }
}
