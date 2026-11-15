import SwiftUI

/// Building blocks laid out like Control Center's menus.

struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 16).padding(.vertical, 6)
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// A device's glyph in a circle: blue when it's in use.
struct IconCircle: View {
    let symbol: String
    let isOn: Bool
    var size: CGFloat = 28
    var rotation: Double = 0

    var body: some View {
        Image(systemName: symbol)
            .rotationEffect(.degrees(rotation))
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.1)))
    }
}

/// A full-width row that highlights under the pointer, like a menu item.
struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

/// An output or input to pick. `toggle` adds a circle at the end that adds the device to the
/// ones in use (or takes it out) without picking it alone.
struct DeviceRow: View {
    let device: AudioDevice
    let direction: AudioDirection
    let isOn: Bool
    var toggle: (isOn: Bool, action: () -> Void)?
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            IconCircle(symbol: device.symbol(direction), isOn: isOn)
            Text(device.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let toggle {
                Button(action: toggle.action) {
                    Image(systemName: toggle.isOn ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(toggle.isOn ? Color.accentColor : Color.secondary.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(toggle.isOn ? "Stop playing through \(device.name)" : "Also play through \(device.name)")
            }
        }
    }
}

/// The closed dropdown: what's in use now, and a chevron that turns when it opens.
struct DropdownRow: View {
    let symbols: [String]
    let title: String
    let isOpen: Bool
    var symbolRotation: Double = 0
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: -8) {
                ForEach(Array(symbols.prefix(3).enumerated()), id: \.offset) { _, symbol in
                    IconCircle(symbol: symbol, isOn: true, rotation: symbolRotation)
                        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }
            }
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
    }
}

/// A slider with a glyph at each end, like the volume slider in Control Center.
struct LevelSlider: View {
    let value: Float
    var low = "speaker.fill"
    var high = "speaker.wave.3.fill"
    var lowAction: (() -> Void)?
    /// A live level (the sound's peak before this slider, 0...1), drawn as a lighter shade inside
    /// the bar and scaled by the slider: nothing at zero, up to the knob at most.
    var meter: (() -> Float)?
    let onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { lowAction?() } label: {
                Image(systemName: low)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(lowAction == nil)
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .overlay {
                    if let meter { MeterShade(read: meter, scale: value) }
                }
            Image(systemName: high)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 16)
        }
        .frame(height: 16)
    }
}

/// The closed Apps dropdown: a small stack of the apps' icons, a "+N" box when there are more,
/// their names, and a chevron that turns when it opens.
struct AppStackRow: View {
    let apps: [AudioApp]
    let isOpen: Bool
    let action: () -> Void
    private let shown = 3

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: -7) {
                ForEach(Array(apps.prefix(shown).enumerated()), id: \.element.id) { index, app in
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .zIndex(Double(shown - index))
                }
                if apps.count > shown {
                    Text("+\(apps.count - shown)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .frame(minWidth: 22, minHeight: 20)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        .padding(.leading, 9)
                }
            }
            .frame(minWidth: 28, alignment: .leading)
            Text(apps.map(\.name).joined(separator: " + "))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
    }
}

/// A live level as a lighter shade over a small slider's track (which macOS draws 4 pt tall,
/// centred, the full width), on a decibel scale like the input level in Sound settings. It's
/// scaled by the slider's value (`scale`, 0...1), so it stays inside the filled part and shows
/// nothing when the slider is at zero: a muted source never looks like it's coming through.
struct MeterShade: View {
    let read: () -> Float
    var scale: Float = 1
    @State private var smoother = MeterSmoother()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation) { _ in
            let level = smoother.next(read()) * min(max(scale, 0), 1)
            GeometryReader { geometry in
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.38) : Color.black.opacity(0.22))
                    .frame(width: max(0, geometry.size.width * CGFloat(level)), height: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Eases the shown level towards the measured one every frame: quickly on the way up (about
/// 60 ms), gently on the way down (about 300 ms), so it glides instead of flickering.
final class MeterSmoother {
    private var shown: Float = 0
    private var last = Date()

    func next(_ peak: Float) -> Float {
        let decibels = 20 * log10(max(peak, 0.000_001))
        let target = min(max((decibels + 54) / 54, 0), 1) // -54 dB … 0 dB
        let now = Date()
        let elapsed = Float(min(now.timeIntervalSince(last), 0.1))
        last = now
        let time: Float = target > shown ? 0.06 : 0.3
        shown += (target - shown) * (1 - exp(-elapsed / time))
        return shown
    }
}

/// An option in a circle (blue when on); clicking anywhere on the row toggles it.
struct OptionRow: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            IconCircle(symbol: symbol, isOn: isOn)
            Text(title).font(.system(size: 13))
        }
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// A plain menu-style item, like "Sound Settings…".
struct TextRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

/// A small capsule toggle, blue when on (Split and Route). `rotation` turns its glyph (both
/// are drawn on their side, pointing right).
struct CapsuleToggle: View {
    static let width: CGFloat = 66
    let title: String
    let symbol: String
    var rotation: Double = 0
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .rotationEffect(.degrees(rotation))
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .frame(width: Self.width) // Mix, Split and Route line up
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// Segments joined into one pill: rounded at the two outer ends, flat where they meet. The
/// chosen one is blue.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isOn = option.value == selection
                let outer: CGFloat = 11
                let shape = UnevenRoundedRectangle(topLeadingRadius: index == 0 ? outer : 0,
                                                   bottomLeadingRadius: index == 0 ? outer : 0,
                                                   bottomTrailingRadius: index == options.count - 1 ? outer : 0,
                                                   topTrailingRadius: index == options.count - 1 ? outer : 0,
                                                   style: .continuous)
                Button { onSelect(option.value) } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(shape.fill(isOn ? Color.accentColor : Color.primary.opacity(0.1)))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

/// A tick in a circle for lists you can pick several from.
struct Checkmark: View {
    let isOn: Bool

    var body: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
    }
}

/// Split's and Route's glyphs, on their side.
enum Glyph {
    static let split = "arrow.triangle.branch"
    static let route = "arrow.triangle.merge"
    static let sideways: Double = 90
}
