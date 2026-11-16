import AVFoundation
import Synchronization
import UIKit

/// This device's microphone, sent to the Mac as one of Soundcheck Mic's microphones: 48 kHz
/// mono, each buffer as it's captured (about 10 ms). It runs for as long as it's picked on the
/// Mac (iOS shows the orange dot meanwhile), so a call starting on the Mac finds it ready: iOS
/// doesn't let an app start the microphone from the background.
final class MicStreamer: @unchecked Sendable {
    static let shared = MicStreamer()

    @MainActor private(set) var isRunning = false
    @MainActor private var engine: AVAudioEngine?
    @MainActor private var pendingStart = false
    private let peak = Atomic<UInt32>(0)
    private let converterQueue = DispatchQueue(label: "com.mylesdean.Soundcheck.Companion.mic", qos: .userInitiated)
    private var converter: AVAudioConverter?

    /// The microphone's level right now (0...1), for the meter.
    var level: Float { Float(bitPattern: peak.load(ordering: .relaxed)) }

    @MainActor func start() {
        guard !isRunning else { MacLink.shared.send(.micReady); return }
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if granted { MicStreamer.shared.start() } else { MacLink.shared.send(.micFailed("Microphone access is off")) }
                    }
                }
            }
            return
        case .denied:
            MacLink.shared.send(.micFailed("Turn on Microphone for Soundcheck in Settings"))
            return
        default:
            break
        }
        do {
            try AudioSessionSetup.apply(speaker: SpeakerPlayer.shared.isPlaying, microphone: true)
            try startEngine()
        } catch {
            companionLog.error("Couldn't start the microphone: \(error.localizedDescription, privacy: .public)")
            pendingStart = true
            let inBackground = UIApplication.shared.applicationState != .active
            MacLink.shared.send(.micFailed(inBackground ? "Tap the notification on your \(PairingStore.deviceKind)" : "Couldn't use the microphone"))
            if inBackground { Notifications.askToListen(mac: MacLink.shared.state?.macShortName ?? "your Mac") }
            return
        }
        pendingStart = false
        isRunning = true
        SharedState.micOn = true
        MacLink.shared.send(.micReady)
    }

    @MainActor private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CompanionMicError.noInput }
        let rate = format.sampleRate
        let sink = AVAudioSinkNode { [unowned self] _, frames, buffers in
            self.captured(buffers, frames: Int(frames), rate: rate)
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        try engine.start()
        self.engine = engine
    }

    @MainActor func stop() {
        pendingStart = false
        guard isRunning else { return }
        isRunning = false
        engine?.stop()
        engine = nil
        SharedState.micOn = false
        peak.store(0, ordering: .relaxed)
        try? AudioSessionSetup.apply(speaker: SpeakerPlayer.shared.isPlaying, microphone: false)
    }

    @MainActor func linkLost() {
        guard isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            MainActor.assumeIsolated {
                if MicStreamer.shared.isRunning && !MacLink.shared.isConnected { MicStreamer.shared.stop() }
            }
        }
    }

    @MainActor func appBecameActive() {
        if pendingStart { start() }
    }

    // MARK: Capture thread

    private func captured(_ buffers: UnsafePointer<AudioBufferList>, frames: Int, rate: Double) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        guard frames > 0, let data = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = list.count == 1 ? max(Int(list[0].mNumberChannels), 1) : 1
        var loudest: Float = 0
        if rate == Companion.micRate {
            var out = Data(count: frames * 2)
            out.withUnsafeMutableBytes { raw in
                let ints = raw.bindMemory(to: Int16.self)
                for frame in 0..<frames {
                    let value = data[frame * channels]
                    loudest = max(loudest, abs(value))
                    ints[frame] = Int16(max(-32_768, min(32_767, (value * 32_768).rounded()))).littleEndian
                }
            }
            MacLink.audio.channel?.sendAudio(.micAudio(samples: out))
        } else {
            // Another rate (a Bluetooth headset's): converted off this thread.
            var floats = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                floats[frame] = data[frame * channels]
                loudest = max(loudest, abs(floats[frame]))
            }
            converterQueue.async { self.convertAndSend(floats, rate: rate) }
        }
        let held = max(loudest, Float(bitPattern: peak.load(ordering: .relaxed)) * 0.9)
        peak.store(held.bitPattern, ordering: .relaxed)
    }

    private func convertAndSend(_ floats: [Float], rate: Double) {
        guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Companion.micRate, channels: 1, interleaved: false) else { return }
        if converter?.inputFormat.sampleRate != rate { converter = AVAudioConverter(from: from, to: to) }
        guard let converter, let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(floats.count)),
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(Double(floats.count) * Companion.micRate / rate) + 32)
        else { return }
        input.frameLength = AVAudioFrameCount(floats.count)
        floats.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: floats.count) }
        var supplied = false
        converter.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard output.frameLength > 0, let ints = output.int16ChannelData?[0] else { return }
        let data = Data(bytes: ints, count: Int(output.frameLength) * 2)
        MacLink.audio.channel?.sendAudio(.micAudio(samples: data))
    }
}

enum CompanionMicError: LocalizedError {
    case noInput
    var errorDescription: String? { "No microphone" }
}
