import AudioToolbox
import SwiftUI

/// The FX button beside an app's or microphone's EQ button: blue while one of its effects is on,
/// and it opens (or closes) its effects under that bar.
struct EffectsButton: View {
    let target: AudioEngine.ShapeTarget
    let name: String
    private var effects = Effects.shared
    private var state = PanelState.shared

    init(target: AudioEngine.ShapeTarget, name: String) {
        self.target = target
        self.name = name
    }

    var body: some View {
        _ = effects.revision
        let active = effects.isActive(target)
        let open = state.effecting == target
        return Button {
            withAnimation(.easeInOut(duration: PanelController.animationDuration)) {
                state.effecting = open ? nil : target
                state.shaping = nil
                state.hearing = nil
            }
        } label: {
            Text("FX")
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .foregroundStyle(active ? Color.white : (open ? Color.primary : Color.secondary))
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? Color.accentColor : Color.primary.opacity(open ? 0.18 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(active ? "Effects on \(name)" : "Effects for \(name): reverb, echo, pitch, your plug-ins…")
        .accessibilityLabel("Effects for \(name)")
    }
}

/// An app's or microphone's effects, one after the other (top first), with Add Effect under them.
struct EffectsPanel: View {
    let target: AudioEngine.ShapeTarget
    /// Whose they are (for the effects' window titles).
    let name: String

    var body: some View {
        if let rack = Effects.shared.rack(target) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rack.slots) { slot in
                    EffectRow(rack: rack, slot: slot, owner: name)
                }
                AddEffectMenu(rack: rack)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// One effect: on or off (its icon), its name (click to show its controls), and a menu for its
/// window, moving it and removing it.
private struct EffectRow: View {
    let rack: EffectRack
    let slot: EffectSlot
    let owner: String
    private var state = PanelState.shared

    init(rack: EffectRack, slot: EffectSlot, owner: String) {
        self.rack = rack
        self.slot = slot
        self.owner = owner
    }

    private var symbol: String { BuiltInEffect.named(slot.builtIn)?.symbol ?? "puzzlepiece.extension" }
    private var title: String { "\(slot.name) · \(owner)" }

    var body: some View {
        let expanded = state.openEffect == slot.id
        let index = rack.slots.firstIndex { $0.id == slot.id } ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { rack.setOn(slot.id, !slot.isOn) }
                } label: {
                    IconCircle(symbol: symbol, isOn: slot.isOn, size: 22)
                }
                .buttonStyle(.plain)
                .help(slot.isOn ? "Turn \(slot.name) off" : "Turn \(slot.name) on")

                Button {
                    withAnimation(.easeInOut(duration: PanelController.animationDuration)) {
                        state.openEffect = expanded ? nil : slot.id
                    }
                } label: {
                    HStack(spacing: 4) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(slot.name).font(.system(size: 12)).lineLimit(1)
                            if let note {
                                Text(note.text)
                                    .font(.system(size: 10))
                                    .foregroundStyle(note.isProblem ? Color.orange : Color.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide \(slot.name)'s controls" : "Show \(slot.name)'s controls")

                Menu {
                    Button("Open Window…") { EffectWindows.shared.open(slot.id, in: rack, title: title) }
                        .disabled(!rack.hasWindow(slot.id))
                    Divider()
                    Button("Move Up") { withAnimation(.easeInOut(duration: 0.15)) { rack.move(slot.id, by: -1) } }
                        .disabled(index == 0)
                    Button("Move Down") { withAnimation(.easeInOut(duration: 0.15)) { rack.move(slot.id, by: 1) } }
                        .disabled(index >= rack.slots.count - 1)
                    Divider()
                    Button("Remove", role: .destructive) {
                        withAnimation(.easeInOut(duration: PanelController.animationDuration)) { rack.remove(slot.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More for \(slot.name)")
            }
            if expanded {
                EffectEditor(rack: rack, slot: slot, title: title)
                    .padding(.leading, 30)
                    .transition(.opacity)
            }
        }
    }

    /// Under the name: what's wrong, or that it's opening, or its preset, or who makes it.
    private var note: (text: String, isProblem: Bool)? {
        if let problem = rack.problems[slot.id] { return (problem, true) }
        if rack.loading.contains(slot.id) { return ("Opening…", false) }
        if let preset = slot.preset { return (preset, false) }
        if !slot.maker.isEmpty { return (slot.maker, false) }
        return BuiltInEffect.named(slot.builtIn).map { ($0.help, false) }
    }
}

/// An effect's presets and controls (Soundcheck's choice of them for its own, a plug-in's first
/// several), and its window for the rest.
private struct EffectEditor: View {
    let rack: EffectRack
    let slot: EffectSlot
    let title: String

    var body: some View {
        let presets = rack.presets(slot.id)
        let controls = rack.controls(slot.id)
        VStack(alignment: .leading, spacing: 6) {
            if !presets.isEmpty {
                HStack(spacing: 6) {
                    Text("Preset").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: EffectSlider.labelWidth, alignment: .leading)
                    Menu(slot.preset ?? "Choose") {
                        ForEach(presets.indices, id: \.self) { index in
                            Button(presets[index]) { rack.choosePreset(index, for: slot.id) }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            }
            ForEach(controls) { control in
                EffectSlider(control: control) { rack.setValue($0, address: control.address, for: slot.id) }
            }
            if rack.hasWindow(slot.id) {
                Button(slot.builtIn == nil ? "Open \(slot.name)…" : "All Controls…") {
                    EffectWindows.shared.open(slot.id, in: rack, title: title)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
    }
}

/// One control: its name, a slider (or a switch, or a menu of choices), and its value.
private struct EffectSlider: View {
    static let labelWidth: CGFloat = 62
    let control: EffectControlInfo
    let onChange: (AUValue) -> Void
    /// While dragging, the finger's value (the effect's own catches up a moment later).
    @State private var dragging: AUValue?

    var body: some View {
        let value = dragging ?? control.value
        HStack(spacing: 6) {
            Text(control.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Self.labelWidth, alignment: .leading)
                .help(control.name)
            switch control.style {
            case .toggle:
                Toggle("", isOn: Binding(get: { value >= 0.5 }, set: { onChange($0 ? 1 : 0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                Spacer(minLength: 0)
            case .choice:
                Picker("", selection: Binding(get: { Int(value.rounded()) }, set: { onChange(AUValue($0)) })) {
                    ForEach(Array((control.choices ?? []).enumerated()), id: \.offset) { index, choice in
                        Text(choice).tag(index)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer(minLength: 0)
            default:
                Slider(value: Binding(get: { Double(value) }, set: { new in
                    var next = AUValue(new)
                    if let step = control.step, step > 0 { next = (next / step).rounded() * step }
                    dragging = next
                    onChange(next)
                }), in: Double(control.range.lowerBound)...Double(control.range.upperBound)) { editing in
                    if !editing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dragging = nil } }
                }
                .controlSize(.small)
                Text(control.format(value))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }
}

/// Add Effect: Soundcheck's own, then plug-ins by who makes them.
private struct AddEffectMenu: View {
    let rack: EffectRack
    private var effects = Effects.shared

    init(rack: EffectRack) { self.rack = rack }

    var body: some View {
        let own = effects.choices.filter { $0.builtIn != nil }
        let plugIns = Dictionary(grouping: effects.choices.filter { $0.builtIn == nil }, by: \.maker)
        // Other makers first, then Apple's others.
        let makers = plugIns.keys.sorted { a, b in
            if (a == "Apple") != (b == "Apple") { return b == "Apple" }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        Menu {
            ForEach(own) { choice in
                Button { add(choice) } label: { Label(choice.name, systemImage: choice.symbol) }
            }
            if !makers.isEmpty {
                Section("Plug-ins") {
                    ForEach(makers, id: \.self) { maker in
                        Menu(maker) {
                            ForEach(plugIns[maker] ?? []) { choice in
                                Button(choice.name) { add(choice) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(rack.isFull ? "Up to \(EffectControl.maxEffects) effects" : "Add Effect", systemImage: "plus")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(rack.isFull)
    }

    private func add(_ choice: EffectChoice) {
        withAnimation(.easeInOut(duration: PanelController.animationDuration)) {
            rack.add(choice)
            PanelState.shared.openEffect = rack.slots.last?.id
        }
    }
}
