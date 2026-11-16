import Foundation

// The EQ's bands, a sound's shape and the EQ's starting points: shared by Soundcheck and its
// companion app (which shows and edits them).

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
