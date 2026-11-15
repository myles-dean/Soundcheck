import Foundation

// Loudness tools for the audio threads: Night Mode's compressor, Voice Cleanup, and the voice
// detector that lowers routed apps while you talk. All of them are plain structs made off the
// audio thread; `process` doesn't allocate, lock or call into Objective-C.

@inline(__always) private func decibels(_ value: Float) -> Float { 20 * log10f(max(value, 1e-9)) }
@inline(__always) private func amplitude(_ decibels: Float) -> Float { powf(10, decibels / 20) }
/// A one-pole smoothing coefficient for a time constant (seconds) at a sample rate.
@inline(__always) private func coefficient(_ seconds: Double, _ rate: Double) -> Float { Float(exp(-1 / (max(rate, 1) * seconds))) }

/// A stereo-linked compressor with a soft knee and make-up gain. It fades in and out over about
/// 50 ms when it's switched, so turning it on or off doesn't jump.
struct Compressor {
    let threshold: Float // dB
    let ratio: Float
    let knee: Float // dB
    let makeUp: Float // dB
    private let attack: Float, release: Float, blendRate: Float
    private var envelope: Float = 0
    private var blend: Float = 0

    init(threshold: Float, ratio: Float, knee: Float = 6, makeUp: Float, attack: Double, release: Double, sampleRate: Double) {
        self.threshold = threshold
        self.ratio = ratio
        self.knee = knee
        self.makeUp = makeUp
        self.attack = coefficient(attack, sampleRate)
        self.release = coefficient(release, sampleRate)
        blendRate = 1 - coefficient(0.05, sampleRate)
    }

    /// Night Mode: loud parts come down a lot and quiet ones up, so dialogue stays clear without
    /// the explosions.
    static func nightMode(sampleRate: Double) -> Compressor {
        Compressor(threshold: -30, ratio: 4, knee: 8, makeUp: 9, attack: 0.008, release: 0.3, sampleRate: sampleRate)
    }

    /// How much quieter (dB) a level comes out, before make-up.
    func reduction(at level: Float) -> Float {
        let over = level - threshold
        if over <= -knee / 2 { return 0 }
        if over >= knee / 2 { return over * (1 - 1 / ratio) }
        let into = over + knee / 2
        return (1 - 1 / ratio) * into * into / (2 * knee)
    }

    mutating func process(_ data: UnsafeMutablePointer<Float>, frames: Int, channels: Int, on: Bool) {
        let target: Float = on ? 1 : 0
        guard on || blend > 0.0001 else { blend = 0; envelope = 0; return }
        let stereo = channels > 1
        for frame in 0..<frames {
            let index = frame * channels
            let left = data[index], right = stereo ? data[index + 1] : left
            let peak = max(abs(left), abs(right))
            envelope = peak > envelope ? attack * envelope + (1 - attack) * peak : release * envelope + (1 - release) * peak
            let gain = amplitude(makeUp - reduction(at: decibels(envelope)))
            blend += (target - blend) * blendRate
            let applied = 1 + (gain - 1) * blend
            data[index] = left * applied
            if stereo { data[index + 1] = right * applied }
        }
    }
}

/// Voice Cleanup for one microphone: a high-pass that cuts rumble (desks, footsteps, air
/// conditioning), a gate that quiets the room between your words (it learns the room's noise
/// level as it goes), and a leveller that evens out loud and soft speech. It also says whether
/// you're talking, for lowering apps under your voice (that part runs even with Cleanup off).
struct VoiceCleanup {
    private let sampleRate: Double
    // High-pass at 80 Hz (RBJ, Q 0.707), state per channel.
    private let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var x1 = (0.0, 0.0), x2 = (0.0, 0.0), y1 = (0.0, 0.0), y2 = (0.0, 0.0)
    // Detector: a short RMS, and the room's noise floor under it.
    private var power: Float = 0
    private var floor: Float = -60 // dB
    private let powerRate: Float, floorDown: Float, floorUp: Float
    // Gate: open while you talk (and a moment after), down to `depth` between words.
    private var gateGain: Float = 1
    private var hold = 0
    private let holdFrames: Int, gateOpen: Float, gateClose: Float
    private let depth: Float = -18 // dB
    private var leveller: Compressor
    private var blend: Float = 0
    private let blendRate: Float
    /// You're talking (the level is well above the room's), as of the last block.
    private(set) var talking = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        let w0 = 2 * Double.pi * 80 / self.sampleRate
        let alpha = sin(w0) / (2 * 0.707)
        let a0 = 1 + alpha
        b0 = (1 + cos(w0)) / 2 / a0
        b1 = -(1 + cos(w0)) / a0
        b2 = (1 + cos(w0)) / 2 / a0
        a1 = -2 * cos(w0) / a0
        a2 = (1 - alpha) / a0
        powerRate = 1 - coefficient(0.01, self.sampleRate)
        floorDown = 1 - coefficient(0.5, self.sampleRate)
        floorUp = 1 - coefficient(8, self.sampleRate)
        holdFrames = Int(0.2 * self.sampleRate)
        gateOpen = 1 - coefficient(0.003, self.sampleRate)
        gateClose = 1 - coefficient(0.12, self.sampleRate)
        leveller = Compressor(threshold: -26, ratio: 3, knee: 6, makeUp: 7, attack: 0.008, release: 0.2, sampleRate: self.sampleRate)
        blendRate = 1 - coefficient(0.05, self.sampleRate)
    }

    mutating func process(_ data: UnsafeMutablePointer<Float>, frames: Int, channels: Int, on: Bool) {
        let stereo = channels > 1
        var heard = false
        let wet: Float = on ? 1 : 0
        for frame in 0..<frames {
            let index = frame * channels
            let left = data[index], right = stereo ? data[index + 1] : left
            // Talking or not, from the level against the room's (measured before any change).
            let level = max(abs(left), abs(right))
            power += (level * level - power) * powerRate
            let now = decibels(sqrtf(power))
            floor += (now - floor) * (now < floor ? floorDown : floorUp)
            floor = min(max(floor, -90), -35)
            let voice = now > floor + 9
            if voice { hold = holdFrames; heard = true } else if hold > 0 { hold -= 1 }
            guard on || blend > 0.0001 else { continue }
            // High-pass.
            let l = Double(left), r = Double(right)
            let outL = b0 * l + b1 * x1.0 + b2 * x2.0 - a1 * y1.0 - a2 * y2.0
            let outR = b0 * r + b1 * x1.1 + b2 * x2.1 - a1 * y1.1 - a2 * y2.1
            x2 = x1; x1 = (l, r); y2 = y1; y1 = (outL, outR)
            // Gate.
            let gateTarget: Float = hold > 0 ? 1 : amplitude(depth)
            gateGain += (gateTarget - gateGain) * (gateTarget > gateGain ? gateOpen : gateClose)
            var cleanL = Float(outL) * gateGain, cleanR = Float(outR) * gateGain
            blend += (wet - blend) * blendRate
            cleanL = left + (cleanL - left) * blend
            cleanR = right + (cleanR - right) * blend
            data[index] = cleanL
            if stereo { data[index + 1] = cleanR }
        }
        if abs(y1.0) < 1e-20 && abs(y2.0) < 1e-20 { y1 = (0, 0); y2 = (0, 0) }
        talking = heard || hold > 0
        // The leveller, on what's left (it fades with Cleanup itself).
        leveller.process(data, frames: frames, channels: channels, on: on)
    }
}

/// Lowers the apps routed into Soundcheck Mic while you talk, so you're heard over the music:
/// down by `depth` within ~40 ms of your voice, back up over half a second once you've stopped
/// (after a short hold, so they don't pump between words).
struct VoiceDucker {
    private let depth: Float = amplitude(-12)
    private var gain: Float = 1
    private var hold = 0
    private let holdFrames: Int, down: Float, up: Float

    init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        holdFrames = Int(0.35 * rate)
        down = 1 - coefficient(0.04, rate)
        up = 1 - coefficient(0.5, rate)
    }

    /// The apps' gain for this block, and what it eases towards over it.
    mutating func gains(frames: Int, talking: Bool, on: Bool) -> (start: Float, end: Float) {
        let start = gain
        if on && talking { hold = holdFrames } else { hold = max(hold - frames, 0) }
        let target: Float = on && hold > 0 ? depth : 1
        let rate = target < gain ? down : up
        // Eased per frame, worked out for the whole block at once.
        gain = target + (gain - target) * powf(1 - rate, Float(frames))
        return (start, gain)
    }
}
