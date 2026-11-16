import AudioToolbox
import CoreAudio
import Foundation
import os
import Synchronization

let log = Logger(subsystem: "com.mylesdean.Soundcheck", category: "audio")

/// A Float the audio thread reads while the main thread writes it. Aligned 32-bit loads and
/// stores are atomic on Apple silicon and Intel, so no lock is needed.
final class SharedValue: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
    init(_ value: Float) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: value)
    }
    deinit { pointer.deallocate() }
    var value: Float {
        get { pointer.pointee }
        set { pointer.pointee = newValue }
    }
}

struct HALError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String { "\(what) failed (\(status))" }
    /// macOS refused because Soundcheck doesn't have the System Audio Recording permission.
    var isPermissionDenied: Bool { status == kAudioDevicePermissionsError }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw HALError(status: status, what: what) }
}

/// An output a tap plays through: its UID, its software gain (1 when the device's own volume
/// does the job) and its shape (EQ, balance, mono).
typealias TapOutput = (uid: String, gain: SharedValue, shape: ShapeControl)

/// Plays tapped sound through one or more outputs at a chosen level: a process tap (one app's
/// sound, or everything except some processes) muted at the source, and a private aggregate
/// device made of the outputs plus the tap, whose IO proc copies the tap to every output with
/// the gains applied, the app's EQ first and each output's shape after. Releasing the tap gives
/// the app its own sound back.
final class TapPlayer {
    enum Source: Equatable {
        case processes([AudioObjectID])
        case everythingExcept([AudioObjectID])
    }

    let outputUIDs: [String]
    private(set) var source: Source

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let tapDescription: CATapDescription
    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.io", qos: .userInteractive)
    private(set) var isSuspended = false
    var quietSince: Date?
    /// The loudest sample tapped since `takePeak` (before the level is applied), as Float bits.
    private let peakBits = Atomic<UInt32>(0)

    /// How loud the tapped sound has been since the last call (0…1, before its level and mute).
    func takePeak() -> Float { Float(bitPattern: peakBits.exchange(0, ordering: .relaxed)) }

    // Kept alive for the audio thread, which only touches the raw pointers below.
    private let gainValues: [SharedValue]
    // Audio-thread state: everything is set up before IO starts and never reallocated.
    private let tapGain: UnsafeMutablePointer<Float>
    private let tapMuted: UnsafeMutablePointer<Float>
    private let outputGains: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let bufferOutput: UnsafeMutablePointer<Int>
    private let bufferGain: UnsafeMutablePointer<Float>
    private let bufferCount: Int
    private let ramp: Float
    /// The app's own shape, on a stereo copy of the tap, and each output buffer's shape.
    private static let maxFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>
    private var sourceShape: UnsafeMutablePointer<ShapeDSP>?
    private var bufferShapes: UnsafeMutablePointer<ShapeDSP>?
    /// Each output buffer held back so every output sounds together with the slowest.
    private var bufferDelays: UnsafeMutablePointer<DelayLine>?
    private let nightOn: UnsafeMutablePointer<Float>
    private var night: UnsafeMutablePointer<Compressor>?
    /// Each output buffer's shape, then the app's (kept alive for the audio thread).
    private let shapeSources: [ShapeControl]
    /// The app's effects, after its EQ (kept alive here; the audio thread doesn't retain it).
    private let keepEffects: EffectControl?
    private unowned(unsafe) let effects: EffectControl?
    private var sampleRate: Double = 0

    /// - Parameters:
    ///   - outputs: the devices to play through (the first one is the clock), each with its
    ///     software gain (1 when the device's own volume does the job).
    ///   - gain: the tap's own level (an app's volume); `muted` is 1 when muted.
    ///   - shape: the app's own EQ (none for everything else).
    ///   - effects: the app's own effects, after its EQ (none for everything else).
    ///   - night: Night Mode (1: on), which evens out the tapped sound.
    init(source: Source, outputs: [TapOutput], gain: SharedValue, muted: SharedValue, shape: ShapeControl?,
         effects: EffectControl? = nil, night: SharedValue) throws {
        guard let clock = outputs.first?.uid else { throw HALError(status: kAudioHardwareBadDeviceError, what: "find an output") }
        self.source = source
        outputUIDs = outputs.map(\.uid)

        switch source {
        case .processes(let objects): tapDescription = CATapDescription(stereoMixdownOfProcesses: objects)
        case .everythingExcept(let objects): tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
        }
        tapDescription.uuid = UUID()
        tapDescription.name = "Soundcheck"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        gainValues = [gain, muted, night] + outputs.map(\.gain)
        keepEffects = effects
        self.effects = effects
        nightOn = night.pointer
        scratch = .allocate(capacity: Self.maxFrames * 2)
        scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
        tapGain = gain.pointer
        tapMuted = muted.pointer
        outputGains = .allocate(capacity: outputs.count)
        for (index, output) in outputs.enumerated() { (outputGains + index).initialize(to: output.gain.pointer) }

        // Which output each of the aggregate's output buffers belongs to (sub-devices keep the
        // order they're listed in; a device can have more than one stream).
        var map: [Int] = []
        for (index, uid) in outputUIDs.enumerated() {
            let streams = HAL.array(HAL.device(forUID: uid), kAudioDevicePropertyStreams,
                                    scope: kAudioObjectPropertyScopeOutput, zero: AudioStreamID(0)).count
            map += Array(repeating: index, count: streams)
        }
        bufferCount = max(map.count, 1)
        shapeSources = (0..<bufferCount).map { index in outputs[index < map.count ? map[index] : 0].shape } + (shape.map { [$0] } ?? [])
        bufferOutput = .allocate(capacity: bufferCount)
        bufferGain = .allocate(capacity: bufferCount)
        for index in 0..<bufferCount {
            (bufferOutput + index).initialize(to: index < map.count ? map[index] : 0)
            (bufferGain + index).initialize(to: 0) // fade in from silence
        }

        var tap = AudioObjectID.unknown
        do {
            try check(AudioHardwareCreateProcessTap(tapDescription, &tap), "create process tap")
            tapID = tap

            var description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Soundcheck",
                kAudioAggregateDeviceUIDKey: AudioDevice.ownUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: clock,
                kAudioAggregateDeviceClockDeviceKey: clock,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: outputUIDs.map {
                    [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: $0 != clock]
                },
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            if outputUIDs.count > 1 { description[kAudioAggregateDeviceIsStackedKey] = true }
            var aggregate = AudioObjectID.unknown
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "create aggregate device")
            aggregateID = aggregate

            let format = HAL.read(aggregate, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeOutput,
                                  initial: AudioStreamBasicDescription()) ?? AudioStreamBasicDescription()
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0
            else { throw HALError(status: kAudioDeviceUnsupportedFormatError, what: "use the output's format") }
            ramp = 1 - exp(-1 / (Float(format.mSampleRate) * 0.02)) // ~20 ms smoothing, no clicks
            sampleRate = format.mSampleRate
            effects?.prepare(sampleRate: format.mSampleRate)
            let dsps = UnsafeMutablePointer<ShapeDSP>.allocate(capacity: bufferCount)
            for index in 0..<bufferCount {
                (dsps + index).initialize(to: ShapeDSP(control: shapeSources[index], sampleRate: format.mSampleRate))
            }
            bufferShapes = dsps
            let alignment = HAL.alignment(outputUIDs)
            let delays = UnsafeMutablePointer<DelayLine>.allocate(capacity: bufferCount)
            for index in 0..<bufferCount {
                let output = index < map.count ? map[index] : 0
                let frames = Int((alignment[output] * format.mSampleRate).rounded())
                (delays + index).initialize(to: DelayLine(frames: frames, maxBlock: Self.maxFrames))
            }
            bufferDelays = delays
            self.night = .allocate(capacity: 1)
            self.night?.initialize(to: .nightMode(sampleRate: format.mSampleRate))
            if let shape {
                sourceShape = .allocate(capacity: 1)
                sourceShape?.initialize(to: ShapeDSP(control: shape, sampleRate: format.mSampleRate))
            }
        } catch {
            ramp = 0
            teardown()
            deallocate()
            throw error
        }

        var proc: AudioDeviceIOProcID?
        do {
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [unowned(unsafe) self] _, input, _, output, _ in
                self.render(input, output)
            }, "create IO proc")
            procID = proc
            try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
        } catch {
            teardown()
            deallocate()
            throw error
        }
    }

    deinit {
        teardown()
        deallocate()
    }

    /// Stops and destroys everything (in the order the HAL needs); the tapped sound goes back to
    /// playing on its own.
    func invalidate() { teardown() }

    var isAlive: Bool { aggregateID.isValid && HAL.isAlive(aggregateID) }

    /// The global tap's list of processes to leave alone (the ones with their own tap).
    @discardableResult
    func updateExcluded(_ objects: [AudioObjectID]) -> Bool {
        guard case .everythingExcept(let current) = source else { return false }
        if current == objects { return true }
        tapDescription.processes = objects
        guard writeDescription() else { return false }
        source = .everythingExcept(objects)
        return true
    }

    /// Stops reading a quiet app (so the output can idle) while keeping it muted at the source,
    /// so it can't suddenly play at full volume; `resume()` when it plays again.
    func suspend() {
        guard !isSuspended, aggregateID.isValid, let procID else { return }
        tapDescription.muteBehavior = .muted
        guard writeDescription() else { tapDescription.muteBehavior = .mutedWhenTapped; return }
        AudioDeviceStop(aggregateID, procID)
        isSuspended = true
    }

    func resume() {
        guard isSuspended, aggregateID.isValid, let procID else { return }
        AudioDeviceStart(aggregateID, procID)
        tapDescription.muteBehavior = .mutedWhenTapped
        writeDescription()
        isSuspended = false
        quietSince = nil
    }

    @discardableResult
    private func writeDescription() -> Bool {
        var reference = tapDescription
        var address = HAL.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status != noErr { log.error("Couldn't update a tap: \(status)") }
        return status == noErr
    }

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

    private var deallocated = false
    private func deallocate() {
        guard !deallocated else { return }
        deallocated = true
        outputGains.deallocate()
        bufferOutput.deallocate()
        bufferGain.deallocate()
        scratch.deallocate()
        if let bufferShapes {
            for index in 0..<bufferCount { bufferShapes[index].release() }
            bufferShapes.deallocate()
        }
        if let bufferDelays {
            for index in 0..<bufferCount { bufferDelays[index].release() }
            bufferDelays.deallocate()
        }
        night?.deallocate()
        if let sourceShape {
            sourceShape.pointee.release()
            sourceShape.deallocate()
        }
    }

    // MARK: Audio thread: no allocation, locks, Objective-C or logging below.

    private func render(_ inputList: UnsafePointer<AudioBufferList>, _ outputList: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        // The tap's stream comes after any input streams the output devices have.
        let tap = inputs.count > 0 ? inputs[inputs.count - 1] : AudioBuffer()
        let inChannels = max(Int(tap.mNumberChannels), 1)
        let inFrames = tap.mData == nil ? 0 : min(Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * inChannels), Self.maxFrames)
        let source = tap.mData?.assumingMemoryBound(to: Float.self)
        let level = tapMuted.pointee > 0.5 ? 0 : tapGain.pointee
        let ramp = self.ramp

        // A stereo copy of the tap, with the app's own EQ.
        if let source {
            var peak: Float = 0
            for sample in 0..<(inFrames * inChannels) { peak = max(peak, abs(source[sample])) }
            if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) { peakBits.store(peak.bitPattern, ordering: .relaxed) }
            for frame in 0..<inFrames {
                let left = source[frame * inChannels]
                scratch[frame * 2] = left
                scratch[frame * 2 + 1] = inChannels > 1 ? source[frame * inChannels + 1] : left
            }
            sourceShape?.pointee.process(scratch, frames: inFrames, channels: 2)
            effects?.process(scratch, frames: inFrames, sampleRate: sampleRate)
            night?.pointee.process(scratch, frames: inFrames, channels: 2, on: nightOn.pointee > 0.5)
        }

        for index in 0..<outputs.count {
            let buffer = outputs[index]
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            guard index < bufferCount, source != nil else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = min(inFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let target = level * outputGains[bufferOutput[index]].pointee
            let out = data.assumingMemoryBound(to: Float.self)
            var gain = bufferGain[index]
            for frame in 0..<frames {
                gain += (target - gain) * ramp
                let left = scratch[frame * 2], right = scratch[frame * 2 + 1]
                if channels == 1 {
                    out[frame] = (left + right) * 0.5 * gain
                } else {
                    out[frame * channels] = left * gain
                    out[frame * channels + 1] = right * gain
                }
            }
            bufferGain[index] = gain
            // The output's own shape, then peaks rounded off (Boost and EQ can go past full scale).
            bufferShapes?[index].process(out, frames: frames, channels: channels)
            for frame in 0..<frames {
                out[frame * channels] = softLimit(out[frame * channels])
                if channels > 1 { out[frame * channels + 1] = softLimit(out[frame * channels + 1]) }
            }
            bufferDelays?[index].process(out, frames: frames, channels: channels)
        }
    }
}
