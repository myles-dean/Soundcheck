import AppKit
import SwiftUI

/// The Saved Setups window: make, edit and apply layouts of speakers, apps and Soundcheck Mic.
@MainActor
final class SetupsWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupsWindowController()
    /// Called when it opens (the menu bar panel closes).
    var onOpen: (() -> Void)?
    private var window: NSWindow?

    func show() {
        onOpen?()
        if window == nil {
            let hosting = NSHostingController(rootView: SetupsView())
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = "Saved Setups"
            window.setContentSize(NSSize(width: 780, height: 580))
            window.minSize = NSSize(width: 640, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct SetupsView: View {
    private var store = SetupStore.shared
    private var engine = AudioEngine.shared
    @State private var selection: SavedSetup.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.setups) { setup in
                    Label(setup.name.isEmpty ? "Untitled" : setup.name, systemImage: "square.stack.3d.up")
                        .tag(setup.id)
                        .contextMenu {
                            Button("Apply") { engine.apply(setup) }
                            Button("Delete", role: .destructive) { delete(setup.id) }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .toolbar {
                ToolbarItem {
                    Button(action: add) { Label("New Setup", systemImage: "plus") }
                        .help("Save how your speakers, apps and mics are set up now")
                }
            }
        } detail: {
            if let id = selection, let setup = store.setups.first(where: { $0.id == id }) {
                SetupEditor(setup: Binding(get: { store.setups.first { $0.id == id } ?? setup }, set: { store.update($0) }),
                            delete: { delete(id) })
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Setup", systemImage: "square.stack.3d.up")
                } description: {
                    Text("A setup is a layout of speakers, app volumes and what goes into Soundcheck Mic, ready to apply in one click. Click + to start from how things are now.")
                } actions: {
                    Button("New Setup", action: add)
                }
            }
        }
        .onAppear { if selection == nil { selection = store.setups.first?.id } }
    }

    private func add() {
        let setup = engine.captureSetup(named: "Setup \(store.setups.count + 1)")
        store.add(setup)
        selection = setup.id
    }

    private func delete(_ id: SavedSetup.ID) {
        store.remove(id)
        if selection == id { selection = store.setups.first?.id }
    }
}

/// One setup: its name, speakers, apps and Soundcheck Mic, with Apply.
private struct SetupEditor: View {
    @Binding var setup: SavedSetup
    let delete: () -> Void
    private var engine = AudioEngine.shared
    @State private var applied = false

    init(setup: Binding<SavedSetup>, delete: @escaping () -> Void) {
        _setup = setup
        self.delete = delete
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $setup.name)
                HStack {
                    Button("Apply") {
                        engine.apply(setup)
                        applied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { applied = false }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Use Current Levels") {
                        let current = engine.captureSetup(named: setup.name)
                        setup.speakers = current.speakers
                        setup.apps = current.apps
                        setup.split = current.split
                        setup.route = current.route
                    }
                    .help("Replace this setup with how your speakers, apps and mics are set up now")
                    if applied {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button("Delete Setup", role: .destructive, action: delete)
                }
            }

            Section {
                ForEach(engine.knownSpeakers) { device in
                    speakerRow(device)
                }
            } header: {
                Text("Speakers")
            } footer: {
                Text("Every speaker Soundcheck has seen is here, plugged in or not. The first one you tick is macOS's main output.")
            }

            Section {
                Toggle("Split: send apps to their own speakers", isOn: $setup.split)
                ForEach($setup.apps) { $app in
                    appRow($app)
                }
                HStack {
                    Button("Add App…") {
                        AppLookup.choose(title: "Add Apps to the Setup", prompt: "Add") { ids in addApps(ids) }
                    }
                    let playing = engine.playingApps.filter { app in !setup.apps.contains { $0.id == app.id } }
                    if !playing.isEmpty {
                        Menu("Add Playing App") {
                            ForEach(playing) { app in
                                Button(app.name) { addApps([app.id]) }
                            }
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text("Apps")
            }

            Section {
                Toggle("Route into Soundcheck Mic", isOn: $setup.route.isOn)
                if setup.route.isOn {
                    ForEach(engine.knownMicrophones) { device in
                        micRow(device)
                    }
                    ForEach(setup.apps) { app in
                        Toggle(isOn: Binding(get: { setup.route.apps.contains(app.id) },
                                             set: { on in
                                                 setup.route.apps.removeAll { $0 == app.id }
                                                 if on { setup.route.apps.append(app.id) }
                                             })) {
                            Label { Text("Send \(AppLookup.name(app.id))") } icon: { Image(nsImage: AppLookup.icon(app.id)).resizable().frame(width: 16, height: 16) }
                        }
                    }
                }
            } header: {
                Text("Soundcheck Mic")
            } footer: {
                Text("The microphones and apps mixed into Soundcheck Mic. Add apps above to send them.")
            }
        }
        .formStyle(.grouped)
        .animation(.easeInOut(duration: 0.2), value: applied)
    }

    // MARK: Rows

    private func speakerRow(_ device: AudioEngine.KnownDevice) -> some View {
        let index = setup.speakers.firstIndex { $0.id == device.id }
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { index != nil }, set: { on in
                if on {
                    setup.speakers.append(.init(id: device.id, volume: engine.rememberedSpeakerVolume(device.id)))
                } else {
                    setup.speakers.removeAll { $0.id == device.id }
                }
            })) {
                HStack(spacing: 8) {
                    Image(systemName: device.symbol).frame(width: 18)
                    Text(device.name)
                    if index == 0 && setup.speakers.count > 1 {
                        Text("Main").font(.caption).foregroundStyle(.secondary)
                    }
                    if !device.isConnected {
                        Text("Not connected").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let index {
                volumeSlider($setup.speakers[index].volume)
            }
        }
    }

    private func micRow(_ device: AudioEngine.KnownDevice) -> some View {
        let index = setup.route.microphones.firstIndex { $0.id == device.id }
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { index != nil }, set: { on in
                if on {
                    setup.route.microphones.append(.init(id: device.id, volume: engine.rememberedMicVolume(device.id)))
                } else {
                    setup.route.microphones.removeAll { $0.id == device.id }
                }
            })) {
                HStack(spacing: 8) {
                    Image(systemName: device.symbol).frame(width: 18)
                    Text(device.name)
                    if !device.isConnected {
                        Text("Not connected").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let index {
                volumeSlider($setup.route.microphones[index].volume, low: "mic.fill", high: "mic.and.signal.meter.fill")
            }
        }
    }

    private func appRow(_ app: Binding<SavedSetup.AppLevel>) -> some View {
        let id = app.wrappedValue.id
        return HStack(spacing: 10) {
            Image(nsImage: AppLookup.icon(id)).resizable().frame(width: 22, height: 22)
                .opacity(app.wrappedValue.muted ? 0.4 : 1)
            Text(AppLookup.name(id)).frame(width: 120, alignment: .leading).lineLimit(1)
            Slider(value: app.volume, in: 0...1).disabled(app.wrappedValue.muted)
            Button {
                app.wrappedValue.muted.toggle()
            } label: {
                Image(systemName: app.wrappedValue.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(app.wrappedValue.muted ? "Unmute" : "Mute")
            if setup.split {
                outputMenu(app)
            }
            Button {
                setup.apps.removeAll { $0.id == id }
                setup.route.apps.removeAll { $0 == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from the setup")
        }
    }

    /// Which speakers a split app plays through (none: the setup's main speakers).
    private func outputMenu(_ app: Binding<SavedSetup.AppLevel>) -> some View {
        let outputs = app.wrappedValue.outputs ?? []
        let title = outputs.isEmpty
            ? "Main Speakers"
            : outputs.compactMap { uid in engine.knownSpeakers.first { $0.id == uid }?.name }.joined(separator: " + ")
        return Menu(title) {
            Button("Main Speakers") { app.wrappedValue.outputs = nil }
            Divider()
            ForEach(engine.knownSpeakers) { device in
                Toggle(device.name, isOn: Binding(get: { outputs.contains(device.id) }, set: { on in
                    var list = app.wrappedValue.outputs ?? []
                    list.removeAll { $0 == device.id }
                    if on { list.append(device.id) }
                    app.wrappedValue.outputs = list.isEmpty ? nil : list
                }))
            }
        }
        .frame(width: 150)
    }

    private func volumeSlider(_ value: Binding<Float>, low: String = "speaker.fill", high: String = "speaker.wave.3.fill") -> some View {
        HStack(spacing: 8) {
            Image(systemName: low).foregroundStyle(.secondary).frame(width: 18)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }), in: 0...1)
            Image(systemName: high).foregroundStyle(.secondary)
        }
        .padding(.leading, 26)
    }

    private func addApps(_ ids: [String]) {
        for id in ids where !setup.apps.contains(where: { $0.id == id }) {
            setup.apps.append(.init(id: id, volume: engine.appLevel(id), muted: engine.isAppMuted(id)))
        }
    }
}
