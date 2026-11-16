import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Companions' microphones: each arrives over the network (48 kHz mono) into a ring that
/// Soundcheck Mic's mixer reads like any other microphone. They're listed with the Mac's own
/// microphones as "iPhone (Soundcheck)".
final class CompanionMics: @unchecked Sendable {
    static let shared = CompanionMics()
    static let uidPrefix = "com.mylesdean.Soundcheck.companion-mic."
    /// The transport type companions' microphones are given (not a real one: 'scmp').
    static let transport: UInt32 = 0x7363_6D70

    static func uid(_ device: String) -> String { uidPrefix + device }
    static func device(fromUID uid: String) -> String? {
        uid.hasPrefix(uidPrefix) ? String(uid.dropFirst(uidPrefix.count)) : nil
    }

    private let lock = NSLock()
    private var rings: [String: CompanionMicRing] = [:]

    /// The ring a companion's microphone goes into (made the first time it's asked for).
    func ring(for device: String, create: Bool = false) -> CompanionMicRing? {
        lock.withLock {
            if let ring = rings[device] { return ring }
            guard create else { return nil }
            let ring = CompanionMicRing()
            rings[device] = ring
            return ring
        }
    }

    /// Its link went: what's left plays out and then it's silence.
    func markIdle(_ device: String) {
        ring(for: device)?.reset()
    }

    /// The companions' microphones, as devices for the Microphones list.
    @MainActor static var devices: [AudioDevice] {
        CompanionHub.shared.devices.map { device in
            AudioDevice(companion: uid(device.id), name: "\(device.kind) (Soundcheck)")
        }
    }
}

extension AudioDevice {
    /// A companion's microphone: no Core Audio device behind it.
    init(companion uid: String, name: String) {
        self.init(id: .unknown, uid: uid, name: name, transport: CompanionMics.transport, outputSource: 0)
    }

    var isCompanion: Bool { transport == CompanionMics.transport }
}

/// One companion's microphone between the network and the audio thread. The network writes
/// 48 kHz mono 16-bit as it arrives; the mixer reads at its own rate (converted on the way in
/// when that's not 48 kHz). The two clocks drift apart slowly, so the reader keeps about 60 ms
/// buffered, now and then repeating or skipping one frame (which can't be heard) to stay there;
/// after a gap it waits until that much has built up again.
final class CompanionMicRing: @unchecked Sendable {
    private static let capacity = 1 << 16 // frames
    private let samples: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let resetRequested = Atomic<Bool>(false)
    /// The mixer's rate (the network side converts to it).
    private let rate = Atomic<Int>(48_000)
    // Network side only.
    private var converter: AVAudioConverter?
    private var converterRate = 48_000
    // Audio thread only.
    private var primed = false
    private var counter = 0

    init() {
        samples = .allocate(capacity: Self.capacity)
        samples.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { samples.deallocate() }

    func reset() { resetRequested.store(true, ordering: .releasing) }

    /// Network: 48 kHz mono Int16.
    func write(_ data: Data) {
        let count = data.count / 2
        guard count > 0 else { return }
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for index in 0..<count { floats[index] = Float(Int16(littleEndian: ints[index])) / 32_768 }
        }
        let target = rate.load(ordering: .relaxed)
        if target != 48_000 { floats = convert(floats, to: target) }
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        // A reader that's stopped (the mixer was rebuilt) shouldn't make the writer stall.
        let room = Self.capacity - (write - read)
        let usable = min(floats.count, max(room, 0))
        for index in 0..<usable { samples[(write + index) & (Self.capacity - 1)] = floats[index] }
        writeIndex.store(write + usable, ordering: .releasing)
    }

    private func convert(_ input: [Float], to target: Int) -> [Float] {
        if converter == nil || converterRate != target {
            guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
                  let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(target), channels: 1, interleaved: false) else { return input }
            converter = AVAudioConverter(from: from, to: to)
            converterRate = target
        }
        guard let converter, let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(input.count)),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(input.count) * Double(target) / 48_000) + 32) else { return input }
        buffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: input.count) }
        var supplied = false
        converter.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Audio thread: `frames` frames of stereo into `into` (the mixer's rate is `sampleRate`).
    /// Silence while it's filling up.
    func read(into: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) {
        let wantedRate = Int(sampleRate.rounded())
        if rate.load(ordering: .relaxed) != wantedRate { rate.store(wantedRate, ordering: .relaxed) }
        var read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        if resetRequested.exchange(false, ordering: .acquiring) {
            read = write
            primed = false
        }
        let target = Int(sampleRate * 0.06)
        var available = write - read
        if !primed {
            if available < target {
                for index in 0..<(frames * 2) { into[index] = 0 }
                readIndex.store(read, ordering: .releasing)
                return
            }
            primed = true
        }
        // Far too much buffered (a burst after a stall): drop to the target.
        if available > target * 4 {
            read = write - target
            available = target
        }
        // Drifting: one frame now and then.
        counter += frames
        var skip = 0, repeatFrame = false
        if counter >= 4_800 {
            counter = 0
            if available > target + target / 2 { skip = 1 } else if available < target / 2 { repeatFrame = true }
        }
        read += skip
        var position = read
        for frame in 0..<frames {
            let value: Float
            if position < write {
                value = samples[position & (Self.capacity - 1)]
                if !(repeatFrame && frame == 0) { position += 1 }
            } else {
                value = 0
                primed = false // ran dry: wait for it to build up again
            }
            into[frame * 2] = value
            into[frame * 2 + 1] = value
        }
        readIndex.store(position, ordering: .releasing)
    }
}
