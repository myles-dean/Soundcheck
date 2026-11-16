import SwiftUI

/// Whose effects are open.
struct EffectsEditing: Identifiable {
    let target: RemoteShapeTarget
    let name: String
    var id: String { "\(target)" }
}

/// The FX button beside an app's or microphone's EQ button: blue while one of its effects is on.
struct FXButton: View {
    let effects: [RemoteEffect]
    let action: () -> Void

    var body: some View {
        let active = effects.contains(where: \.isOn)
        Button(action: action) {
            RoundButtonFace(isOn: active) {
                Text("FX").font(.system(size: 9.5, weight: .heavy, design: .rounded))
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Effects")
    }
}

/// An app's or microphone's effects, one after the other: each one on or off, its preset and
/// controls, and Add Effect (Soundcheck's own, or the plug-ins on the Mac).
struct EffectsSheet: View {
    let editing: EffectsEditing
    @Environment(\.dismiss) private var dismiss
    private var link: MacLink { .shared }

    private var effects: [RemoteEffect] {
        guard let state = link.state else { return [] }
        switch editing.target {
        case .app(let id): return state.apps.first { $0.id == id }?.effects ?? []
        case .mic(let id): return state.mics.first { $0.id == id }?.effects ?? []
        case .speaker: return []
        }
    }

    var body: some View {
        let effects = self.effects
        NavigationStack {
            List {
                ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                    EffectSection(effect: effect, target: editing.target, isFirst: index == 0, isLast: index == effects.count - 1)
                }
                Section {
                    addMenu(full: effects.count >= 4)
                } footer: {
                    if effects.count >= 4 { Text("Up to four effects each.") }
                }
            }
            .navigationTitle(editing.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addMenu(full: Bool) -> some View {
        let choices = link.state?.effectChoices ?? []
        let own = choices.filter { $0.maker == nil }
        let plugIns = Dictionary(grouping: choices.filter { $0.maker != nil }, by: { $0.maker ?? "" })
        let makers = plugIns.keys.sorted { a, b in
            if (a == "Apple") != (b == "Apple") { return b == "Apple" }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return Menu {
            ForEach(own) { choice in
                Button { add(choice) } label: { Label(choice.name, systemImage: choice.symbol) }
            }
            if !makers.isEmpty {
                Section("Plug-ins on Your Mac") {
                    ForEach(makers, id: \.self) { maker in
                        Menu(maker) {
                            ForEach(plugIns[maker] ?? []) { choice in Button(choice.name) { add(choice) } }
                        }
                    }
                }
            }
        } label: {
            Label("Add Effect", systemImage: "plus")
        }
        .disabled(full)
    }

    private func add(_ choice: RemoteEffectChoice) {
        link.send(.addEffect(target: editing.target, choice: choice.id))
    }
}

/// One effect: on or off, moving and removing it, its preset, and its controls.
private struct EffectSection: View {
    let effect: RemoteEffect
    let target: RemoteShapeTarget
    let isFirst: Bool
    let isLast: Bool
    private var link: MacLink { .shared }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: effect.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(effect.isOn ? Color.white : Color.primary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(effect.isOn ? Color.accentColor : Color(.tertiarySystemFill)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(effect.name).lineLimit(1)
                    if let note {
                        Text(note.text).font(.caption).foregroundStyle(note.isProblem ? Color.orange : Color.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Toggle("On", isOn: Binding(get: { effect.isOn }, set: {
                    link.send(.setEffectOn(target: target, effect: effect.id, on: $0))
                }))
                .labelsHidden()
                Menu {
                    Button { link.send(.moveEffect(target: target, effect: effect.id, offset: -1)) } label: {
                        Label("Move Up", systemImage: "arrow.up")
                    }
                    .disabled(isFirst)
                    Button { link.send(.moveEffect(target: target, effect: effect.id, offset: 1)) } label: {
                        Label("Move Down", systemImage: "arrow.down")
                    }
                    .disabled(isLast)
                    Button(role: .destructive) { link.send(.removeEffect(target: target, effect: effect.id)) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityLabel("More for \(effect.name)")
            }
            if !effect.presets.isEmpty {
                Picker("Preset", selection: Binding(get: { effect.preset.flatMap { effect.presets.firstIndex(of: $0) } ?? -1 }, set: { index in
                    if index >= 0 { link.send(.setEffectPreset(target: target, effect: effect.id, index: index)) }
                })) {
                    if effect.preset == nil { Text("Choose").tag(-1) }
                    ForEach(effect.presets.indices, id: \.self) { index in Text(effect.presets[index]).tag(index) }
                }
                .pickerStyle(.menu)
            }
            ForEach(effect.controls) { control in
                EffectControlRow(control: control) { value in
                    link.send(.setEffectValue(target: target, effect: effect.id, control: control.id, value: value),
                              coalescing: "fx:\(effect.id):\(control.id)")
                }
            }
        } footer: {
            if effect.isPlugIn {
                Text("More of its controls are in its window on your Mac.")
            } else if let help = effect.help {
                Text(help)
            }
        }
    }

    private var note: (text: String, isProblem: Bool)? {
        if let problem = effect.problem { return (problem, problem != "Opening…") }
        if let preset = effect.preset { return (preset, false) }
        return effect.maker.map { ($0, false) }
    }
}

/// One control: a slider with its value (or a switch, or a menu of choices). While it's being
/// dragged it shows the finger's value, not the Mac's echo of it.
private struct EffectControlRow: View {
    let control: RemoteEffectControl
    let onChange: (Float) -> Void
    @State private var dragging: Float?

    var body: some View {
        let value = dragging ?? control.value
        switch control.style {
        case .toggle:
            Toggle(control.name, isOn: Binding(get: { value >= 0.5 }, set: { onChange($0 ? 1 : 0) }))
        case .choice:
            Picker(control.name, selection: Binding(get: { Int(value.rounded()) }, set: { onChange(Float($0)) })) {
                ForEach(Array((control.choices ?? []).enumerated()), id: \.offset) { index, choice in Text(choice).tag(index) }
            }
            .pickerStyle(.menu)
        default:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(control.name).font(.subheadline)
                    Spacer()
                    Text(control.style.format(value, choices: control.choices, unit: control.unit))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(value) }, set: { new in
                    var next = Float(new)
                    if let step = control.step, step > 0 { next = (next / step).rounded() * step }
                    dragging = next
                    onChange(next)
                }), in: Double(control.min)...Double(max(control.max, control.min + 0.0001))) { editing in
                    if !editing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dragging = nil } }
                }
            }
        }
    }
}
