import Foundation
import Synchronization

/// One band of the EQ, named for what it changes.
enum EQBand: Int, CaseIterable, Identifiable {
    case bass, warmth, voice, clarity, air
    var id: Int { rawValue }
    static let count = 5

    var name: String {
        switch self {
        case .bass: "Bass"
        case .warmth: "Warmth"
        case .voice: "Voice"
        case .clarity: "Clarity"
        case .air: "Air"
        }
    }

    /// What it changes, for the tooltip.
    var help: String {
        switch self {
        case .bass: "Bass and kick drums (below 100 Hz)"
        case .warmth: "Fullness, or boom and mud (around 300 Hz)"
        case .voice: "Voices and most instruments (around 1 kHz)"
        case .clarity: "Clarity and presence (around 3 kHz)"
        case .air: "Sparkle, cymbals and hiss (above 10 kHz)"
        }
    }

    /// The filter: 0 low shelf, 1 peak, 2 high shelf; its frequency (Hz) and width (Q, peaks only).
    /// A switch rather than a table, so the audio thread can ask without touching an array.
    static func spec(_ index: Int) -> (kind: Int, frequency: Double, q: Double) {
        switch index {
        case 0: (0, 100, 0.707)
        case 1: (1, 300, 0.9)
        case 2: (1, 1_000, 0.9)
        case 3: (1, 3_000, 0.9)
        default: (2, 10_000, 0.707)
        }
    }
}

/// How a speaker, an app or a microphone sounds: its EQ (dB per band) and, for speakers,
/// balance and mono. Flat is how it sounds without Soundcheck.
struct SoundShape: Codable, Equatable {
    static let range: ClosedRange<Float> = -12...12

    var gains: [Float] = Array(repeating: 0, count: EQBand.count)
    /// -1 (left only) … 0 (both) … 1 (right only).
    var balance: Float = 0
    var mono = false

    func gain(_ band: EQBand) -> Float { band.rawValue < gains.count ? gains[band.rawValue] : 0 }

    mutating func setGain(_ value: Float, for band: EQBand) {
        if gains.count != EQBand.count { gains = (0..<EQBand.count).map { $0 < gains.count ? gains[$0] : 0 } }
        gains[band.rawValue] = min(max(value, Self.range.lowerBound), Self.range.upperBound)
    }

    var hasEQ: Bool { gains.contains { abs($0) >= 0.05 } }
    var isFlat: Bool { !hasEQ && abs(balance) < 0.005 && !mono }
}

/// Starting points for the EQ.
struct EQPreset: Identifiable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let all = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0]),
        EQPreset(name: "More Bass", gains: [6, 2, 0, 0, 0]),
        EQPreset(name: "Less Boom", gains: [-3, -5, 0, 0, 0]),
        EQPreset(name: "Clear Voices", gains: [-2, -2, 2, 4, 0]),
        EQPreset(name: "Brighter", gains: [0, 0, 0, 3, 5]),
        EQPreset(name: "Less Rumble", gains: [-10, -2, 0, 0, 0]),
    ]
}

/// A shape the main thread changes while audio threads read it. A sequence lock: the count is
/// odd while a change is being written, and an audio thread only takes a copy when it's even and
/// didn't move while it copied (otherwise it keeps what it had and looks again next time).
final class ShapeControl: @unchecked Sendable {
    /// The bands' gains, then balance, then mono (0 or 1).
    static let count = EQBand.count + 2
    fileprivate let values: UnsafeMutablePointer<Float>
    private let sequence = Atomic<UInt32>(0)

    init(_ shape: SoundShape = SoundShape()) {
        values = .allocate(capacity: Self.count)
        values.initialize(repeating: 0, count: Self.count)
        set(shape)
    }

    deinit { values.deallocate() }

    /// Main thread.
    func set(_ shape: SoundShape) {
        let start = sequence.load(ordering: .relaxed)
        sequence.store(start &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        for band in 0..<EQBand.count { values[band] = band < shape.gains.count ? shape.gains[band] : 0 }
        values[EQBand.count] = min(max(shape.balance, -1), 1)
        values[EQBand.count + 1] = shape.mono ? 1 : 0
        sequence.store(start &+ 2, ordering: .releasing)
    }

    /// Audio thread: copies the settings into `target` if they changed since `seen`, returning the
    /// new count; nil when nothing changed or a change is half written.
    fileprivate func read(into target: UnsafeMutablePointer<Float>, since seen: UInt32) -> UInt32? {
        let first = sequence.load(ordering: .acquiring)
        guard first != seen, first & 1 == 0 else { return nil }
        for index in 0..<Self.count { target[index] = values[index] }
        atomicMemoryFence(ordering: .acquiring)
        guard sequence.load(ordering: .relaxed) == first else { return nil }
        return first
    }
}

/// The audio thread's side of a shape, for one stream: its own copy of the settings, the EQ's
/// filters made from them at the stream's sample rate (RBJ cookbook biquads, in doubles so the low
/// bands stay accurate), and their state for two channels. Made off the audio thread, with
/// `release()` to free it; `process` doesn't allocate, lock or call into Objective-C.
struct ShapeDSP {
    unowned(unsafe) let control: ShapeControl
    let sampleRate: Double
    private var seen: UInt32 = .max // odd: never a finished count, so the first look takes a copy
    private let settings: UnsafeMutablePointer<Float>
    /// b0, b1, b2, a1, a2 per band (divided by a0).
    private let coefficients: UnsafeMutablePointer<Double>
    /// x1, x2, y1, y2 per band per channel.
    private let state: UnsafeMutablePointer<Double>
    /// One bit per band that isn't flat.
    private var bands = 0
    private var mono = false
    private var leftTarget: Float = 1, rightTarget: Float = 1
    private var left: Float = 1, right: Float = 1
    private let ramp: Float

    init(control: ShapeControl, sampleRate: Double) {
        self.control = control
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        settings = .allocate(capacity: ShapeControl.count)
        settings.initialize(repeating: 0, count: ShapeControl.count)
        coefficients = .allocate(capacity: EQBand.count * 5)
        coefficients.initialize(repeating: 0, count: EQBand.count * 5)
        state = .allocate(capacity: EQBand.count * 2 * 4)
        state.initialize(repeating: 0, count: EQBand.count * 2 * 4)
        ramp = 1 - exp(-1 / (Float(self.sampleRate) * 0.02)) // balance changes over ~20 ms
    }

    func release() {
        settings.deallocate()
        coefficients.deallocate()
        state.deallocate()
    }

    /// Whether `process` would change anything (after taking any new settings).
    mutating func isActive() -> Bool {
        refresh()
        return bands != 0 || mono || left != 1 || right != 1 || leftTarget != 1 || rightTarget != 1
    }

    /// Shapes interleaved float samples in place: the first two of `channels` (just the first
    /// when there's one).
    mutating func process(_ data: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, isActive() else { return }
        let stereo = channels > 1
        if mono && stereo {
            for frame in 0..<frames {
                let index = frame * channels
                let middle = (data[index] + data[index + 1]) * 0.5
                data[index] = middle
                data[index + 1] = middle
            }
        }
        if bands != 0 {
            for band in 0..<EQBand.count where bands & (1 << band) != 0 {
                let c = coefficients + band * 5
                let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
                for channel in 0..<(stereo ? 2 : 1) {
                    let s = state + (band * 2 + channel) * 4
                    var x1 = s[0], x2 = s[1], y1 = s[2], y2 = s[3]
                    var index = channel
                    for _ in 0..<frames {
                        let x = Double(data[index])
                        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                        x2 = x1; x1 = x
                        y2 = y1; y1 = y
                        data[index] = Float(y)
                        index += channels
                    }
                    // Silence decays towards denormals, which are slow on Intel: stop at zero.
                    if abs(y1) < 1e-20 && abs(y2) < 1e-20 && abs(x1) < 1e-20 && abs(x2) < 1e-20 { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }
                    s[0] = x1; s[1] = x2; s[2] = y1; s[3] = y2
                }
            }
        }
        if stereo && (left != 1 || right != 1 || leftTarget != 1 || rightTarget != 1) {
            for frame in 0..<frames {
                left += (leftTarget - left) * ramp
                right += (rightTarget - right) * ramp
                data[frame * channels] *= left
                data[frame * channels + 1] *= right
            }
            if abs(left - leftTarget) < 1e-4 { left = leftTarget }
            if abs(right - rightTarget) < 1e-4 { right = rightTarget }
        }
    }

    private mutating func refresh() {
        guard let next = control.read(into: settings, since: seen) else { return }
        seen = next
        var active = 0
        for band in 0..<EQBand.count {
            let gain = Double(settings[band])
            let spec = EQBand.spec(band)
            guard abs(gain) >= 0.05, spec.frequency < sampleRate * 0.45 else { continue }
            // A band coming back on starts from silence rather than whatever it last held.
            if bands & (1 << band) == 0 {
                (state + band * 8).update(repeating: 0, count: 8)
            }
            active |= 1 << band
            Self.design(kind: spec.kind, frequency: spec.frequency, q: spec.q, gain: gain,
                        sampleRate: sampleRate, into: coefficients + band * 5)
        }
        bands = active
        let balance = min(max(settings[EQBand.count], -1), 1)
        leftTarget = balance > 0 ? 1 - balance : 1
        rightTarget = balance < 0 ? 1 + balance : 1
        mono = settings[EQBand.count + 1] > 0.5
    }

    /// The RBJ Audio EQ Cookbook's shelving and peaking filters (shelf slope 1).
    static func design(kind: Int, frequency: Double, q: Double, gain: Double, sampleRate: Double,
                       into c: UnsafeMutablePointer<Double>) {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        var b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
        switch kind {
        case 1:
            let alpha = sinW / (2 * q)
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a
        case 0:
            let alpha = sinW / 2 * 2.squareRoot()
            let root = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW + root)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - root)
            a0 = (a + 1) + (a - 1) * cosW + root
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - root
        default:
            let alpha = sinW / 2 * 2.squareRoot()
            let root = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW + root)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - root)
            a0 = (a + 1) - (a - 1) * cosW + root
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - root
        }
        c[0] = b0 / a0
        c[1] = b1 / a0
        c[2] = b2 / a0
        c[3] = a1 / a0
        c[4] = a2 / a0
    }
}

/// Rounds off peaks past 0.9 instead of clipping hard (EQ boosts and Boost can go past full scale).
@inline(__always) func softLimit(_ sample: Float) -> Float {
    let size = abs(sample)
    guard size > 0.9 else { return sample }
    let limited = 0.9 + 0.1 * tanh((size - 0.9) / 0.1)
    return sample < 0 ? -limited : limited
}
