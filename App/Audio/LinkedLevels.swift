import Foundation

/// A group of levels that move together: the speakers in use, the apps, or the microphones.
///
/// Each member sits at `level` plus its offset (clamped to 0...1); a member without an offset is
/// at `level`. The main slider follows the loudest member, and moving it (or pressing a volume
/// key) moves every member by the same amount: with one at half and the rest at zero, turning
/// the main slider up to full puts that one at full and the rest at half. Past full, the full
/// ones stay full while the quieter ones keep rising (volume keys); turning down mirrors that,
/// until all are silent. Offsets only change when you drag one member's own slider, so the gaps
/// come back when you turn the other way.
struct LinkedLevels: Codable, Equatable {
    var level: Float = 1
    var offsets: [String: Float] = [:]

    /// The level of members without an offset of their own.
    var base: Float { clamp(level) }
    func value(_ key: String) -> Float { clamp(level + (offsets[key] ?? 0)) }
    func hasOwnLevel(_ key: String) -> Bool { offsets[key] != nil }

    /// The loudest member's level, before clamping (it can be past full).
    private func peak(_ members: [String]) -> Float {
        level + (members.map { offsets[$0] ?? 0 }.max() ?? 0)
    }

    /// What the main slider shows: the loudest member's level.
    func top(_ members: [String]) -> Float { clamp(peak(members)) }

    /// The main slider: the loudest member goes to `value`, the rest move by the same amount.
    mutating func setTop(_ value: Float, _ members: [String]) {
        level += clamp(value) - peak(members)
    }

    /// A volume key: every member moves by the same amount, from all silent to all full.
    mutating func step(_ delta: Float, _ members: [String]) {
        let values = members.isEmpty ? [Float(0)] : members.map { offsets[$0] ?? 0 }
        let low = -(values.max() ?? 0), high = 1 - (values.min() ?? 0)
        level = min(max(min(max(level, low), high) + delta, low), high)
    }

    /// One member's own slider. Only that member changes.
    mutating func set(_ value: Float, for key: String) {
        let offset = clamp(value) - level
        offsets[key] = abs(offset) < 0.001 ? nil : offset
    }

    private func clamp(_ value: Float) -> Float { min(max(value, 0), 1) }
}
