import AudioToolbox
import CoreAudio
import Foundation

/// Soundcheck Mic's mix: the real microphones, plus (with Route) each chosen app's sound at its
/// own level, added together and written to Soundcheck Mic's hidden feed, which the driver plays
/// back as Soundcheck Mic's input. The apps keep playing normally (their taps don't mute them).
///
/// A private aggregate device of the feed (the clock), the microphones and one tap per app, with
/// an IO proc that adds them up. It also measures each one's level for the panel.
final class MicMixer: @unchecked Sendable {
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.route", qos: .userInteractive)

    // Kept alive for the audio thread, which only touches the raw pointers below.
    private let appGains: [SharedValue]
    private let unity = SharedValue(1)
    /// For each of the aggregate's input buffers: whether it's mixed in (each microphone's first
    /// stream, and every tap), its gain, and which level slot it fills (-1: none).
    private let mixed: UnsafeMutablePointer<Bool>
    private let gains: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let slots: UnsafeMutablePointer<Int>
    /// The latest peak of each microphone, then each app (0...1, before its gain: the panel's
    /// shade scales it by the slider).
    private let peaks: UnsafeMutablePointer<Float>
    private let inputCount: Int
    private let sourceIDs: [String]

    /// A microphone's or an app's level right now (0...1).
    func level(_ id: String) -> Float {
        guard let index = sourceIDs.firstIndex(of: id) else { return 0 }
        return min(peaks[index], 1)
    }

    /// - Parameters:
    ///   - microphones: each microphone's UID and its gain in the mix (0 when it's turned all the
    ///     way down or muted; its level is otherwise the device's own).
    ///   - apps: each routed app's id, its processes, and its level in the mix.
    init(feedUID: String, microphones: [(uid: String, gain: SharedValue)],
         apps: [(id: String, processes: [AudioObjectID], gain: SharedValue)]) throws {
        let microphoneUIDs = microphones.map(\.uid)
        appGains = apps.map(\.gain) + microphones.map(\.gain)
        sourceIDs = microphoneUIDs + apps.map(\.id)

        // The aggregate's input buffers: each microphone's streams in order, then one per tap.
        var layout: [(mixed: Bool, gain: UnsafeMutablePointer<Float>, slot: Int)] = []
        for (index, uid) in microphoneUIDs.enumerated() {
            let streams = HAL.array(HAL.device(forUID: uid), kAudioDevicePropertyStreams,
                                    scope: kAudioObjectPropertyScopeInput, zero: AudioStreamID(0)).count
            for stream in 0..<streams { layout.append((stream == 0, microphones[index].gain.pointer, stream == 0 ? index : -1)) }
        }
        for (index, app) in apps.enumerated() {
            layout.append((true, app.gain.pointer, microphoneUIDs.count + index))
        }
        inputCount = layout.count
        mixed = .allocate(capacity: max(layout.count, 1))
        gains = .allocate(capacity: max(layout.count, 1))
        slots = .allocate(capacity: max(layout.count, 1))
        for (index, entry) in layout.enumerated() {
            (mixed + index).initialize(to: entry.mixed)
            (gains + index).initialize(to: entry.gain)
            (slots + index).initialize(to: entry.slot)
        }
        peaks = .allocate(capacity: max(sourceIDs.count, 1))
        peaks.initialize(repeating: 0, count: max(sourceIDs.count, 1))

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

        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: feedUID, kAudioSubDeviceDriftCompensationKey: false]]
        for uid in microphoneUIDs {
            subDevices.append([kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: true])
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
        let mixed = self.mixed, gains = self.gains, slots = self.slots, peaks = self.peaks, count = inputCount
        var result = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, output, _ in
            MicMixer.mix(input, into: output, mixed: mixed, gains: gains, slots: slots, peaks: peaks, count: count)
        }
        if result == noErr {
            procID = proc
            result = AudioDeviceStart(aggregateID, procID)
        }
        guard result == noErr else { throw HALError(status: result, what: "start Soundcheck Mic") }
    }

    deinit {
        teardown()
        mixed.deallocate()
        gains.deallocate()
        slots.deallocate()
        peaks.deallocate()
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

    /// Adds up the mixed input buffers at their gains (a mono microphone goes to both channels).
    private static func mix(_ inputList: UnsafePointer<AudioBufferList>, into outputList: UnsafeMutablePointer<AudioBufferList>,
                            mixed: UnsafeMutablePointer<Bool>, gains: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
                            slots: UnsafeMutablePointer<Int>, peaks: UnsafeMutablePointer<Float>, count: Int) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        guard outputs.count > 0, let data = outputs[0].mData else { return }
        let out = data.assumingMemoryBound(to: Float.self)
        let outChannels = max(Int(outputs[0].mNumberChannels), 1)
        let frames = Int(outputs[0].mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
        memset(data, 0, Int(outputs[0].mDataByteSize))

        for index in 0..<min(inputs.count, count) where mixed[index] {
            let buffer = inputs[index]
            guard let source = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let available = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let gain = gains[index].pointee
            var peak: Float = 0
            for frame in 0..<available {
                let left = source[frame * channels]
                let right = channels > 1 ? source[frame * channels + 1] : left
                out[frame * outChannels] += left * gain
                if outChannels > 1 { out[frame * outChannels + 1] += right * gain }
                peak = max(peak, abs(left), abs(right))
            }
            let slot = slots[index]
            if slot >= 0 { peaks[slot] = max(peak, peaks[slot] * 0.85) } // held briefly, so no frame misses a peak
        }
        // Keep the sum from clipping hard.
        for sample in 0..<(frames * outChannels) {
            out[sample] = max(-1, min(1, out[sample]))
        }
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
