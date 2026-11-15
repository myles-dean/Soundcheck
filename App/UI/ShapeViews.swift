import SwiftUI

/// Where an EQ is open: whose it is, and which bar it opened under.
struct EQSpot: Hashable {
    enum Place: Hashable { case main, own }
    let target: AudioEngine.ShapeTarget
    var place: Place = .own
}

/// The EQ button to the left of a speaker's, app's or microphone's volume bar: blue while it's
/// shaped, and it opens (or closes) the EQ under that bar.
struct ShapeButton: View {
    let spot: EQSpot
    let name: String
    /// Everything it shapes (the main bar's can shape every speaker in use); blue if any is shaped.
    var targets: [AudioEngine.ShapeTarget]
    private var engine = AudioEngine.shared
    private var state = PanelState.shared

    init(spot: EQSpot, name: String, targets: [AudioEngine.ShapeTarget]? = nil) {
        self.spot = spot
        self.name = name
        self.targets = targets ?? [spot.target]
    }

    private var target: AudioEngine.ShapeTarget { spot.target }

    var body: some View {
        let shaped = targets.contains { !engine.shape($0).isFlat }
        let open = state.shaping == spot
        Button {
            withAnimation(.easeInOut(duration: PanelController.animationDuration)) {
                state.shaping = open ? nil : spot
                state.hearing = nil
            }
        } label: {
            // The letters read better at this size than a sliders glyph does.
            Text("EQ")
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .foregroundStyle(shaped ? Color.white : (open ? Color.primary : Color.secondary))
                .frame(width: 20, height: 20)
                .background(Circle().fill(shaped ? Color.accentColor : Color.primary.opacity(open ? 0.18 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("EQ for \(name)")
    }

    private var helpText: String {
        switch target {
        case .speaker: "EQ, balance and mono for \(name)"
        default: "EQ for \(name)"
        }
    }
}

/// Beside a speaker's EQ button: hear your mic on that speaker (blue while you do), for streaming
/// or podcasting. A click plays what goes into Soundcheck Mic (or stops); a right-click opens the
/// list of microphones to pick which ones that speaker plays.
struct HearYourselfButton: View {
    /// The speakers it turns it on for (the main bar's: every one in use); on when all of them are.
    let devices: [AudioDevice]
    /// The bar it's on (where its list opens).
    let spot: EQSpot?
    private var engine = AudioEngine.shared
    private var state = PanelState.shared

    init(devices: [AudioDevice], spot: EQSpot?) {
        self.devices = devices
        self.spot = spot
    }

    private var names: String { devices.map(\.name).formatted(.list(type: .and)) }

    var body: some View {
        let isOn = !devices.isEmpty && devices.allSatisfy { engine.isHearingYourself(on: $0) }
        // An AppKit click area takes both clicks (SwiftUI has no right-click of its own).
        Image(systemName: "headphones")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.08)))
            .overlay {
                ClickArea(primary: { toggle(!isOn) }, secondary: openList)
            }
            .help((isOn ? "Stop hearing yourself on \(names)"
                        : "Hear Soundcheck Mic on \(names)" + (devices.allSatisfy(\.isHeadphones) ? "" : " (use headphones, or it can echo)"))
                  + ". Right-click to choose which mics.")
            .accessibilityElement()
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("Hear Yourself on \(names)")
            .accessibilityAction { toggle(!isOn) }
            .accessibilityAction(named: "Choose Mics", openList)
    }

    private func toggle(_ on: Bool) {
        withAnimation(.easeInOut(duration: PanelController.animationDuration)) { engine.setHearYourself(on, on: devices) }
    }

    private func openList() {
        withAnimation(.easeInOut(duration: PanelController.animationDuration)) {
            state.hearing = state.hearing == spot ? nil : spot
            state.shaping = nil
        }
    }
}

/// Which microphones a speaker plays (right-clicking its headphones button): Soundcheck Mic, or the
/// microphones you tick. One that isn't going into Soundcheck Mic is heard here only.
struct HearYourselfPicker: View {
    let devices: [AudioDevice]
    private var engine = AudioEngine.shared

    init(devices: [AudioDevice]) { self.devices = devices }

    var body: some View {
        let feeding = Set(engine.feedingMics.map(\.uid))
        VStack(alignment: .leading, spacing: 2) {
            Text("Hear on " + devices.map(\.name).formatted(.list(type: .and)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            row(symbol: "waveform", title: "Soundcheck Mic", note: "The mics it carries",
                isOn: devices.allSatisfy(engine.hearsSoundcheckMic)) {
                engine.toggleHearSoundcheckMic(on: devices)
            }
            ForEach(engine.hearYourselfMicChoices) { mic in
                row(symbol: mic.symbol(.input), title: mic.name, note: feeding.contains(mic.uid) ? nil : "Only here, not in Soundcheck Mic",
                    isOn: devices.allSatisfy { engine.hearsMic(mic.uid, on: $0) }) {
                    engine.toggleHearMic(mic.uid, on: devices)
                }
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func row(symbol: String, title: String, note: String?, isOn: Bool, action: @escaping () -> Void) -> some View {
        HoverRow(action: { withAnimation(.easeInOut(duration: 0.15)) { action() } }) {
            IconCircle(symbol: symbol, isOn: isOn, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12)).lineLimit(1)
                if let note {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Checkmark(isOn: isOn)
        }
    }
}

/// A volume bar with the EQ button to its left (and for one of the Mac's speakers, the Hear
/// Yourself button), and the EQ opening under it.
struct ShapedBar<Bar: View>: View {
    /// What the EQ changes: one speaker, app or mic, or (the main bar with Mix off) every speaker
    /// in use, all at once.
    let targets: [AudioEngine.ShapeTarget]
    let name: String
    /// The Mac's speakers among them (for Hear Yourself, and headphones' volume limit when it's
    /// just one); none for an app, a mic or an AirPlay speaker.
    var devices: [AudioDevice]
    /// The main bar, or the speaker's (app's, mic's) own.
    var place: EQSpot.Place = .own
    @ViewBuilder let bar: Bar
    private var state = PanelState.shared

    init(target: AudioEngine.ShapeTarget, name: String, device: AudioDevice? = nil, place: EQSpot.Place = .own,
         @ViewBuilder bar: () -> Bar) {
        self.init(targets: [target], name: name, devices: device.map { [$0] } ?? [], place: place, bar: bar)
    }

    init(targets: [AudioEngine.ShapeTarget], name: String, devices: [AudioDevice], place: EQSpot.Place = .own,
         @ViewBuilder bar: () -> Bar) {
        self.targets = targets
        self.name = name
        self.devices = devices
        self.place = place
        self.bar = bar()
    }

    private var spot: EQSpot? { targets.first.map { EQSpot(target: $0, place: place) } }

    var body: some View {
        let hearable = devices.filter { AudioEngine.shared.canHearYourself(on: $0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let spot {
                    ShapeButton(spot: spot, name: name, targets: targets)
                }
                if !hearable.isEmpty {
                    HearYourselfButton(devices: hearable, spot: spot)
                }
                bar
            }
            if let spot, state.shaping == spot {
                ShapePanel(targets: targets, device: devices.count == 1 && targets.count == 1 ? devices.first : nil)
                    .transition(.opacity)
            }
            if let spot, state.hearing == spot, !hearable.isEmpty {
                HearYourselfPicker(devices: hearable)
                    .transition(.opacity)
            }
        }
    }
}

/// The EQ: a vertical bar per band with what it does under it, and starting points. Speakers also
/// get balance and mono, and headphones a volume limit.
struct ShapePanel: View {
    /// What it changes. With several (every speaker in use, from the main bar), it shows the first
    /// one's settings and a change sets that one thing on all of them; the rest of each one's
    /// settings stay its own.
    let targets: [AudioEngine.ShapeTarget]
    var device: AudioDevice?
    private var engine = AudioEngine.shared

    init(target: AudioEngine.ShapeTarget, device: AudioDevice? = nil) {
        self.init(targets: [target], device: device)
    }

    init(targets: [AudioEngine.ShapeTarget], device: AudioDevice? = nil) {
        self.targets = targets
        self.device = device
    }

    private var target: AudioEngine.ShapeTarget { targets[0] }

    private var isSpeaker: Bool {
        if case .speaker = target { return true }
        return false
    }

    /// Makes the same change to every target's shape.
    private func change(_ edit: (inout SoundShape) -> Void) {
        for target in targets {
            var next = engine.shape(target)
            edit(&next)
            engine.setShape(next, for: target)
        }
    }

    var body: some View {
        let shape = engine.shape(target)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(EQBand.allCases) { band in
                    VStack(spacing: 3) {
                        Text(Self.decibels(shape.gain(band)))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(abs(shape.gain(band)) < 0.05 ? Color.secondary : Color.primary)
                        EQBar(value: shape.gain(band)) { value in
                            change { $0.setGain(value, for: band) }
                        }
                        .frame(height: 78)
                        .accessibilityLabel(band.name)
                        Text(band.name)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .help(band.help)
                }
            }

            presets(shape)

            if isSpeaker {
                speakerOptions(shape)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// Starting points, three to a row; the one in place is blue.
    private func presets(_ shape: SoundShape) -> some View {
        let rows = stride(from: 0, to: EQPreset.all.count, by: 3).map { Array(EQPreset.all[$0..<min($0 + 3, EQPreset.all.count)]) }
        return VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row]) { preset in
                        let isOn = (0..<EQBand.count).allSatisfy { abs(shape.gain(EQBand(rawValue: $0)!) - preset.gains[$0]) < 0.05 }
                        Button {
                            change { shape in for band in EQBand.allCases { shape.setGain(preset.gains[band.rawValue], for: band) } }
                        } label: {
                            Text(preset.name)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .foregroundStyle(isOn ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.1)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Balance and mono, and for headphones the loudest they go.
    @ViewBuilder
    private func speakerOptions(_ shape: SoundShape) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Balance, with Mono at its end (both are about the two sides).
            HStack(spacing: 6) {
                Text("Balance").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("L").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(shape.balance) }, set: { value in
                    change { $0.balance = abs(value) < 0.05 ? 0 : Float(value) } // a little stickiness in the middle
                }), in: -1...1) {
                    EmptyView()
                } ticks: {
                    SliderTick(0.0)
                }
                .controlSize(.small)
                Text("R").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                CapsuleToggle(title: "Mono", symbol: "circle.lefthalf.filled", isOn: shape.mono) {
                    let on = !shape.mono
                    change { $0.mono = on }
                }
                .help("Both sides play the same sound (for one earbud, or a speaker in a corner)")
                .padding(.leading, 2)
            }
            if let device, device.isHeadphones {
                volumeLimit(device)
            }
        }
    }

    private func volumeLimit(_ device: AudioDevice) -> some View {
        let limit = engine.volumeLimit(device.uid)
        return HStack(spacing: 6) {
            CapsuleToggle(title: "Limit", symbol: "ear", isOn: limit != nil) {
                engine.setVolumeLimit(limit == nil ? 0.6 : nil, for: device.uid)
            }
            .help("The loudest \(device.name) can go, whatever the slider or volume keys say")
            if let limit {
                Slider(value: Binding(get: { Double(limit) }, set: { engine.setVolumeLimit(Float($0), for: device.uid) }), in: 0.1...1)
                    .controlSize(.small)
                Text("\(Int((limit * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            } else {
                Text("No volume limit").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    static func decibels(_ value: Float) -> String {
        if abs(value) < 0.05 { return "0" }
        let rounded = (value * 2).rounded() / 2
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return rounded > 0 ? "+" + text : text.replacingOccurrences(of: "-", with: "−")
    }
}

/// One EQ band's bar: drag up to boost, down to cut (±12 dB), double-click for flat. It sticks at
/// flat on the way through, so getting back there is easy.
struct EQBar: View {
    let value: Float
    let onChange: (Float) -> Void
    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let travel = (height - knob) / 2
            let middle = height / 2
            let y = middle - CGFloat(value / SoundShape.range.upperBound) * travel
            ZStack(alignment: .top) {
                // The track, with a mark at flat.
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 4, height: height)
                Rectangle()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 12, height: 1)
                    .offset(y: middle - 0.5)
                // Filled from flat to the knob.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: max(abs(y - middle), 0))
                    .offset(y: min(y, middle))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .offset(y: y - knob / 2)
            }
            .frame(width: geometry.size.width, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let raw = Float((middle - drag.location.y) / travel) * SoundShape.range.upperBound
                let snapped = (min(max(raw, SoundShape.range.lowerBound), SoundShape.range.upperBound) * 2).rounded() / 2
                onChange(abs(snapped) <= 0.5 ? 0 : snapped)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
        }
        .accessibilityElement()
        .accessibilityValue("\(ShapePanel.decibels(value)) decibels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 1, SoundShape.range.upperBound))
            case .decrement: onChange(max(value - 1, SoundShape.range.lowerBound))
            @unknown default: break
            }
        }
    }
}
