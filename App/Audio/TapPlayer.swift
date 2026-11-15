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

/// Plays tapped sound through one or more outputs at a chosen level: a process tap (one app's
/// sound, or everything except some processes) muted at the source, and a private aggregate
/// device made of the outputs plus the tap, whose IO proc copies the tap to every output with
/// the gains applied. Releasing the tap gives the app its own sound back.
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

    /// - Parameters:
    ///   - outputs: the devices to play through (the first one is the clock), each with its
    ///     software gain (1 when the device's own volume does the job).
    ///   - gain: the tap's own level (an app's volume); `muted` is 1 when muted.
    init(source: Source, outputs: [(uid: String, gain: SharedValue)], gain: SharedValue, muted: SharedValue) throws {
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

        gainValues = [gain, muted] + outputs.map(\.gain)
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
    }

    // MARK: Audio thread: no allocation, locks, Objective-C or logging below.

    /// Boosted apps can go past full scale; peaks are rounded off instead of clipping hard.
    @inline(__always) private static func limit(_ sample: Float) -> Float {
        let size = abs(sample)
        guard size > 0.9 else { return sample }
        let limited = 0.9 + 0.1 * tanh((size - 0.9) / 0.1)
        return sample < 0 ? -limited : limited
    }

    private func render(_ inputList: UnsafePointer<AudioBufferList>, _ outputList: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        // The tap's stream comes after any input streams the output devices have.
        let tap = inputs.count > 0 ? inputs[inputs.count - 1] : AudioBuffer()
        let inChannels = max(Int(tap.mNumberChannels), 1)
        let inFrames = tap.mData == nil ? 0 : Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
        let source = tap.mData?.assumingMemoryBound(to: Float.self)
        let level = tapMuted.pointee > 0.5 ? 0 : tapGain.pointee
        let ramp = self.ramp

        if let source {
            var peak: Float = 0
            for sample in 0..<(inFrames * inChannels) { peak = max(peak, abs(source[sample])) }
            if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) { peakBits.store(peak.bitPattern, ordering: .relaxed) }
        }

        for index in 0..<outputs.count {
            let buffer = outputs[index]
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            guard index < bufferCount, let source else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = min(inFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let target = level * outputGains[bufferOutput[index]].pointee
            let out = data.assumingMemoryBound(to: Float.self)
            var gain = bufferGain[index]
            for frame in 0..<frames {
                gain += (target - gain) * ramp
                let left = source[frame * inChannels]
                let right = inChannels > 1 ? source[frame * inChannels + 1] : left
                if channels == 1 {
                    out[frame] = Self.limit((left + right) * 0.5 * gain)
                } else {
                    out[frame * channels] = Self.limit(left * gain)
                    out[frame * channels + 1] = Self.limit(right * gain)
                }
            }
            bufferGain[index] = gain
        }
    }
}
