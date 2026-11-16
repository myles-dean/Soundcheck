import SwiftUI

/// A level slider with a mute button that shows how loud it is (as on the Mac: the waves follow
/// the level, slashed when muted). While it's being dragged it shows the finger's value, not
/// the Mac's echo of it.
struct LevelSlider: View {
    var value: Float
    var range: ClosedRange<Float> = 0...1
    var muted = false
    var kind: Kind = .speaker
    /// The icon even without a mute (the main bar on Apps, as on the Mac).
    var showsIcon = false
    var onMute: (() -> Void)?
    var onChange: (Float) -> Void

    enum Kind { case speaker, mic }

    @State private var dragging: Float?

    private var shown: Float { dragging ?? value }

    private var symbol: String {
        switch kind {
        case .mic:
            return muted ? "mic.slash.fill" : "mic.fill"
        case .speaker:
            if muted { return "speaker.slash.fill" }
            let level = shown / max(range.upperBound, 1)
            if level <= 0.001 { return "speaker.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onMute {
                Button(action: onMute) {
                    // White (not the button's blue), as the main bar's.
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(muted ? Color.secondary : Color.primary)
                        .frame(width: 30, alignment: .leading)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(muted ? "Unmute" : "Mute")
            } else if showsIcon {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 30, alignment: .leading)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            Slider(value: Binding(get: { Double(shown) }, set: { new in
                dragging = Float(new)
                onChange(Float(new))
            }), in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
                if !editing {
                    // Let the Mac catch up before showing its value again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dragging = nil }
                }
            }
            .opacity(muted ? 0.5 : 1)
            if range.upperBound > 1 {
                Text("\(Int((shown * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}

/// An app's icon from the Mac (or a stand-in until it arrives).
struct AppIcon: View {
    let id: String
    var size: CGFloat = 30
    var fallback = "app.fill"

    var body: some View {
        if let image = MacLink.shared.icons[id] {
            Image(uiImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.6))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// A speaker's or microphone's symbol in a circle, filled white when it's on (black in light
/// mode, where white wouldn't show), with the symbol cut out of it.
struct DeviceCircle: View {
    let symbol: String
    let isOn: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isOn ? Color(.systemBackground) : .primary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(isOn ? Color.primary : Color(.tertiarySystemFill)))
    }
}

/// The EQ button beside a bar.
struct EQButton: View {
    let shape: SoundShape
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundButtonFace(isOn: !shape.isFlat) {
                Text("EQ").font(.system(size: 9.5, weight: .heavy, design: .rounded))
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("EQ")
    }
}

/// The round face of a row's small buttons (EQ, FX, Hear Yourself): grey, or blue while it's on,
/// as big as the rows' checkmark circles.
struct RoundButtonFace<Content: View>: View {
    static var size: CGFloat { 26 }
    let isOn: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(isOn ? Color.accentColor : Color(.tertiarySystemFill)))
            .contentShape(Circle())
    }
}

/// What an EQ sheet is for.
struct ShapeEditing: Identifiable {
    let target: RemoteShapeTarget
    let name: String
    var id: String { "\(target)" }
}

/// The EQ: five bands named for what they do, the starting points, and for speakers balance,
/// mono and (for headphones) a volume limit.
struct ShapeSheet: View {
    let editing: ShapeEditing
    @Environment(\.dismiss) private var dismiss
    @State private var shape = SoundShape()
    @State private var loaded = false

    private var link: MacLink { .shared }
    private var speaker: RemoteSpeaker? {
        guard case .speaker(let key) = editing.target else { return nil }
        return link.state?.speakers.first { $0.id == key }
    }

    private var current: SoundShape {
        guard let state = link.state else { return SoundShape() }
        switch editing.target {
        case .speaker(let key): return state.speakers.first { $0.id == key }?.shape ?? SoundShape()
        case .app(let id): return state.apps.first { $0.id == id }?.shape ?? SoundShape()
        case .mic(let id): return state.mics.first { $0.id == id }?.shape ?? SoundShape()
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(EQBand.allCases) { band in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(band.name).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(String(format: "%+.0f dB", shape.gain(band)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(get: { Double(shape.gain(band)) }, set: { value in
                                shape.setGain(Float(value.rounded()), for: band)
                                send()
                            }), in: -12...12, step: 1)
                            Text(band.help).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("EQ")
                }
                Section("Starting Points") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(EQPreset.all) { preset in
                            Button(preset.name) {
                                for band in EQBand.allCases { shape.setGain(preset.gains[band.rawValue], for: band) }
                                send()
                            }
                            .buttonStyle(.bordered)
                            .tint(shape.gains == preset.gains ? .accentColor : .secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if case .speaker = editing.target {
                    Section("Balance") {
                        HStack {
                            Text("L").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { Double(shape.balance) }, set: { value in
                                shape.balance = abs(value) < 0.04 ? 0 : Float(value)
                                send()
                            }), in: -1...1)
                            Text("R").foregroundStyle(.secondary)
                        }
                        Toggle("Mono", isOn: Binding(get: { shape.mono }, set: { shape.mono = $0; send() }))
                    }
                    if let speaker, speaker.isHeadphones {
                        Section {
                            Toggle("Limit Volume", isOn: Binding(get: { speaker.limit != nil }, set: { on in
                                link.send(.setVolumeLimit(id: speaker.id, limit: on ? 0.75 : nil))
                            }))
                            if let limit = speaker.limit {
                                LevelSlider(value: limit) { link.send(.setVolumeLimit(id: speaker.id, limit: max($0, 0.1)), coalescing: "limit") }
                            }
                        } footer: {
                            Text("Headphones never go louder than this.")
                        }
                    }
                }
            }
            .navigationTitle(editing.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        shape = SoundShape()
                        send()
                    }
                    .disabled(shape.isFlat)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if !loaded { shape = current; loaded = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        link.send(.setShape(target: editing.target, shape: shape), coalescing: "shape")
    }
}

/// A row that says something is only done on the Mac.
struct OnTheMacNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "laptopcomputer")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// A Mac as Soundcheck draws System: its symbol in white on a grey app-shaped tile (macOS's
/// icon grid: the tile is 824/1024 of the canvas, with continuous corners).
struct MacTile: View {
    var symbol = "laptopcomputer"
    var size: CGFloat = 84

    var body: some View {
        let side = size * 824 / 1024
        ZStack {
            Superellipse()
                .fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.46)], startPoint: .top, endPoint: .bottom))
                .overlay(Superellipse().stroke(Color.black.opacity(0.12), lineWidth: 0.75 * size / 64))
                .frame(width: side, height: side)
            Image(systemName: symbol)
                .font(.system(size: size * 26 / 64, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The superellipse macOS draws app icons in (exponent 5/2 each way, as Soundcheck's System tile).
struct Superellipse: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 96
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let c = cos(angle), s = sin(angle)
            let x = rect.midX + rect.width / 2 * CGFloat(copysign(pow(abs(c), 2.0 / 5), c))
            let y = rect.midY + rect.height / 2 * CGFloat(copysign(pow(abs(s), 2.0 / 5), s))
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }
}
