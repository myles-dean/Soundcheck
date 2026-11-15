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
    /// The glyph at the start (none: the bar starts straight away).
    var low: String? = "speaker.fill"
    var high = "speaker.wave.3.fill"
    var lowAction: (() -> Void)?
    /// A live level (the sound's peak before this slider, 0...1), drawn as a lighter shade inside
    /// the bar and scaled by the slider: nothing at zero, up to the knob at most.
    var meter: (() -> Float)?
    /// The bar's own mute: the icon at its end becomes the button (and the start has no icon).
    var mute: MuteControl?
    let onChange: (Float) -> Void

    var body: some View {
        if let mute {
            // Muted: the bar dims but still sets the level, for when it's unmuted.
            HStack(spacing: 8) {
                Slider(value: Binding(get: { Double(value) }, set: { onChange(Float($0)) }), in: 0...1)
                    .controlSize(.small)
                    .opacity(mute.isMuted ? 0.45 : 1)
                    .overlay {
                        if let meter { MeterShade(read: meter, scale: mute.isMuted ? 0 : value) }
                    }
                MuteButton(control: mute, value: value)
            }
            .frame(height: 16)
        } else {
            plainBody
        }
    }

    private var plainBody: some View {
        HStack(spacing: 8) {
            if let low {
                Button { lowAction?() } label: {
                    Image(systemName: low)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(lowAction == nil)
            }
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

/// Takes every click over a SwiftUI view: an ordinary click calls `primary`, a right-click or a
/// Control-click calls `secondary`.
struct ClickArea: NSViewRepresentable {
    let primary: () -> Void
    let secondary: () -> Void

    func makeNSView(context: Context) -> AreaView {
        let view = AreaView()
        view.primary = primary
        view.secondary = secondary
        return view
    }

    func updateNSView(_ view: AreaView, context: Context) {
        view.primary = primary
        view.secondary = secondary
    }

    final class AreaView: NSView {
        var primary: (() -> Void)?
        var secondary: (() -> Void)?
        private var controlClick = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { controlClick = event.modifierFlags.contains(.control) }
        override func mouseUp(with event: NSEvent) {
            // Only a release over it counts, like a button.
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if controlClick { secondary?() } else { primary?() }
        }
        override func rightMouseDown(with event: NSEvent) { secondary?() }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}

/// A bar's own mute, shown as the icon at its end.
struct MuteControl {
    enum Kind { case speaker, mic }
    var kind: Kind = .speaker
    let isMuted: Bool
    let toggle: () -> Void
}

/// The icon at the end of a bar, and its mute button. A speaker shows how loud it is (no waves
/// at zero, then one to three); a mic is just a mic. Muted, it's crossed out.
struct MuteButton: View {
    let control: MuteControl
    let value: Float

    var body: some View {
        Button(action: control.toggle) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                // A speaker's frame fits three waves, so the speaker itself doesn't move as they come
                // and go; a mic's is just the mic, with nothing empty beside it.
                .frame(width: control.kind == .mic ? 12 : 22, height: 16, alignment: control.kind == .mic ? .center : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(control.isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(control.isMuted ? "Unmute" : "Mute")
    }

    private var symbol: String {
        switch control.kind {
        case .mic:
            return control.isMuted ? "mic.slash.fill" : "mic.fill"
        case .speaker:
            if control.isMuted { return "speaker.slash.fill" }
            if value < 0.005 { return "speaker.fill" }
            if value < 0.34 { return "speaker.wave.1.fill" }
            if value < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}

/// The closed Apps dropdown: a small stack of the apps' icons, a "+N" box when there are more,
/// their names, and a chevron that turns when it opens.
struct AppStackRow: View {
    let apps: [AudioApp]
    let isOpen: Bool
    let action: () -> Void
    private let shown = 3

    /// "Dia", "Dia & Music", "Dia, Music, & BitBox", then "Dia, Music, + 5 More".
    static func title(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + " & " + names[1]
        case 3: return names[0] + ", " + names[1] + ", & " + names[2]
        default: return names.prefix(2).joined(separator: ", ") + ", + \(names.count - 2) More"
        }
    }

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
            Text(Self.title(apps.map(\.name)))
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
                if symbol == Glyph.mix {
                    MixGlyph().frame(width: 12, height: 12 * MixGlyphShape.size.height / MixGlyphShape.size.width)
                        .padding(.trailing, 1) // a little more room before "Mix" than the others need
                } else {
                    Image(systemName: symbol)
                        .rotationEffect(.degrees(rotation))
                }
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

/// Split's and Route's glyphs, on their side, and Mix's (drawn to match them).
enum Glyph {
    static let split = "arrow.triangle.branch"
    static let route = "arrow.triangle.merge"
    static let sideways: Double = 90
    /// Not an SF Symbol: CapsuleToggle draws `MixGlyph` for it.
    static let mix = "soundcheck.mix"
}

/// Mix's glyph: an arrow to the right over one to the left, filled like Split's and Route's
/// arrows and taking the text's colour. Drawn from an 87 × 64 SVG, scaled to fit.
struct MixGlyph: View {
    /// A template image, like an SF Symbol, so it takes the capsule's colour exactly as Split's and
    /// Route's glyphs do (a filled shape gets a dimmer treatment on the glass and looks grey).
    static let image: NSImage = {
        let size = NSSize(width: 12, height: 12 * MixGlyphShape.size.height / MixGlyphShape.size.width)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(MixGlyphShape().path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(.template)
            .accessibilityHidden(true)
    }
}

struct MixGlyphShape: Shape {
    static let size = CGSize(width: 87, height: 64)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.size.width, rect.height / Self.size.height)
        let origin = CGPoint(x: rect.midX - Self.size.width * scale / 2, y: rect.midY - Self.size.height * scale / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        path.move(to: p(63.7812, 19.3817))
        path.addLine(to: p(63.7812, 26.1279))
        path.addCurve(to: p(69.3271, 28.4967), control1: p(63.7812, 29.569), control2: p(66.4862, 30.5534))
        path.addLine(to: p(84.3241, 17.7892))
        path.addCurve(to: p(84.3241, 11.8192), control1: p(86.6448, 16.1166), control2: p(86.6448, 13.4917))
        path.addLine(to: p(69.3671, 1.11167))
        path.addCurve(to: p(63.7812, 3.43243), control1: p(66.4862, -0.993029), control2: p(63.7812, -0.048717))
        path.addLine(to: p(63.7812, 10.2267))
        path.addLine(to: p(6.11047, 10.2267))
        path.addCurve(to: p(1.52646, 14.8027), control1: p(3.58329, 10.2267), control2: p(1.52646, 12.2755))
        path.addCurve(to: p(6.11047, 19.3867), control1: p(1.52646, 17.3299), control2: p(3.58329, 19.3867))
        path.addLine(to: p(63.7812, 19.3817))
        path.closeSubpath()
        path.move(to: p(22.2835, 53.3817))
        path.addLine(to: p(22.2835, 60.1279))
        path.addCurve(to: p(16.7375, 62.4967), control1: p(22.2835, 63.569), control2: p(19.5785, 64.5534))
        path.addLine(to: p(1.74057, 51.7892))
        path.addCurve(to: p(1.74057, 45.8192), control1: p(-0.580191, 50.1166), control2: p(-0.580191, 47.4917))
        path.addLine(to: p(16.6975, 35.1117))
        path.addCurve(to: p(22.2835, 37.4324), control1: p(19.5784, 33.007), control2: p(22.2835, 33.9513))
        path.addLine(to: p(22.2835, 44.2267))
        path.addLine(to: p(79.9542, 44.2267))
        path.addCurve(to: p(84.5382, 48.8027), control1: p(82.4814, 44.2267), control2: p(84.5382, 46.2755))
        path.addCurve(to: p(79.9542, 53.3867), control1: p(84.5382, 51.3299), control2: p(82.4814, 53.3867))
        path.addLine(to: p(22.2835, 53.3817))
        path.closeSubpath()
        return path
    }
}
