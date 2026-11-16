import Foundation

/// How an effect's control reads: what its number means, so the Mac and the companion show it
/// the same way ("30%", "−12 dB", "350 ms", "+3 st"…).
enum EffectValueStyle: String, Codable, Hashable, Sendable {
    case plain, percent, decibels, seconds, milliseconds, hertz, cents
    /// Cents shown as semitones (Pitch).
    case pitch
    case semitones, octaves, ratio, toggle, choice

    /// The value as it's shown; `unit` is a plug-in's own unit name (for plain values).
    func format(_ value: Float, choices: [String]? = nil, unit: String? = nil) -> String {
        switch self {
        case .percent:
            return "\(Int(value.rounded()))%"
        case .decibels:
            let magnitude = abs(value)
            let number = magnitude >= 10 ? String(format: "%.0f", magnitude) : String(format: "%.1f", magnitude)
            if magnitude < 0.05 { return "0 dB" }
            return (value < 0 ? "−" : "+") + number + " dB"
        case .seconds:
            return value < 1 ? "\(Int((value * 1000).rounded())) ms" : String(format: "%.2f s", value)
        case .milliseconds:
            if value >= 1000 { return String(format: "%.2f s", value / 1000) }
            return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
        case .hertz:
            return value >= 1000 ? String(format: "%.1f kHz", value / 1000) : String(format: "%.0f Hz", value)
        case .cents:
            return Self.signed(value) + " ¢"
        case .pitch:
            return abs(value) < 50 ? "0 st" : Self.signed(value / 100) + " st"
        case .semitones:
            return Self.signed(value) + " st"
        case .octaves:
            return String(format: "%.2f oct", value)
        case .ratio:
            return String(format: "%.1f:1", value)
        case .toggle:
            return value >= 0.5 ? "On" : "Off"
        case .choice:
            let index = Int(value.rounded())
            if let choices, index >= 0, index < choices.count { return choices[index] }
            return "\(index)"
        case .plain:
            let number = abs(value) >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)
            return unit.map { $0.isEmpty ? number : number + " " + $0 } ?? number
        }
    }

    private static func signed(_ value: Float) -> String {
        let rounded = value.rounded()
        if abs(rounded) < 0.5 { return "0" }
        return (rounded < 0 ? "−" : "+") + String(Int(abs(rounded)))
    }
}
