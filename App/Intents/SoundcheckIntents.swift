import AppIntents
import AppKit

// Shortcuts actions (and Siri phrases): switch speakers, set an app's volume, apply a setup.
// They run inside Soundcheck, which Shortcuts opens if it isn't running.

// MARK: Speakers

struct SpeakerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Speaker"
    static let defaultQuery = SpeakerQuery()

    /// A device UID, or "airplay:" and an AirPlay speaker's ID.
    let id: String
    let name: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct SpeakerQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [SpeakerEntity.ID]) async throws -> [SpeakerEntity] {
        let all = Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SpeakerEntity] {
        Self.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SpeakerEntity] { Self.all() }

    /// Speakers connected now, ones Soundcheck has played through before, and the AirPlay
    /// speakers on the network.
    @MainActor
    static func all() -> [SpeakerEntity] {
        let engine = AudioEngine.shared
        engine.start()
        var speakers = engine.knownSpeakers.map { SpeakerEntity(id: $0.id, name: $0.name, symbol: $0.symbol) }
        for speaker in AirPlayBrowser.shared.speakers {
            let key = AudioEngine.airPlayKey(speaker.id)
            if !speakers.contains(where: { $0.id == key }) {
                speakers.append(SpeakerEntity(id: key, name: speaker.name, symbol: speaker.symbol))
            }
        }
        return speakers
    }
}

struct SwitchSpeakersIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Speakers"
    static let description = IntentDescription("Plays your Mac's sound through the speakers you choose, AirPlay speakers included.")

    @Parameter(title: "Speakers")
    var speakers: [SpeakerEntity]

    static var parameterSummary: some ParameterSummary {
        Summary("Play through \(\.$speakers)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = AudioEngine.shared
        engine.start()
        guard !speakers.isEmpty else { throw SoundcheckIntentError.noSpeakers }
        engine.playThrough(speakers.map(\.id))
        return .result(dialog: "Playing through \(speakers.map(\.name).formatted(.list(type: .and))).")
    }
}

// MARK: Apps

struct AudioAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let defaultQuery = AudioAppQuery()

    /// The app's bundle ID.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct AudioAppQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [AudioAppEntity.ID]) async throws -> [AudioAppEntity] {
        AudioEngine.shared.start()
        return identifiers.map(Self.entity)
    }

    @MainActor
    func entities(matching string: String) async throws -> [AudioAppEntity] {
        var apps = Self.known()
        // Any installed app with that name, even one Soundcheck hasn't heard yet.
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> AudioAppEntity? in
            guard let id = app.bundleIdentifier, app.activationPolicy == .regular else { return nil }
            return AudioAppEntity(id: id, name: app.localizedName ?? id)
        }
        for app in running where !apps.contains(where: { $0.id == app.id }) { apps.append(app) }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AudioAppEntity] { Self.known() }

    /// Apps Soundcheck knows: playing, pinned, with a level or EQ of their own, or in a setup.
    @MainActor
    static func known() -> [AudioAppEntity] {
        let engine = AudioEngine.shared
        engine.start()
        return engine.knownAppIDs.map(entity)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor
    static func entity(_ id: String) -> AudioAppEntity {
        let name = AudioEngine.shared.apps.first { $0.id == id }?.name ?? AudioApp.pinned(id).name
        return AudioAppEntity(id: id, name: name)
    }
}

struct SetAppVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set App Volume"
    static let description = IntentDescription("Sets one app's volume in Soundcheck, without changing the others. Past 100% needs Boost Apps on.")

    @Parameter(title: "App")
    var app: AudioAppEntity

    @Parameter(title: "Volume", description: "0 to 100, or up to 200 with Boost Apps on.", default: 50,
               controlStyle: .field, inclusiveRange: (0, 200))
    var volume: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$app) to \(\.$volume)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = AudioEngine.shared
        engine.start()
        let level = Float(min(max(volume, 0), engine.allowBoost ? 200 : 100)) / 100
        engine.setAppLevel(level, for: app.id)
        if level > 0 && engine.isAppMuted(app.id) { engine.setAppMuted(false, for: app.id) }
        return .result(dialog: "\(app.name) is at \(Int((level * 100).rounded()))%.")
    }
}

// MARK: Saved setups

struct SetupEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Setup"
    static let defaultQuery = SetupQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SetupQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [SetupEntity.ID]) async throws -> [SetupEntity] {
        let setups = SetupStore.shared.setups
        return identifiers.compactMap { id in setups.first { $0.id == id }.map { SetupEntity(id: $0.id, name: $0.name) } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SetupEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SetupEntity] {
        SetupStore.shared.setups.map { SetupEntity(id: $0.id, name: $0.name) }
    }
}

struct ApplySetupIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Setup"
    static let description = IntentDescription("Puts one of your saved setups in place: its speakers, app levels and microphones.")

    @Parameter(title: "Setup")
    var setup: SetupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$setup)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = AudioEngine.shared
        engine.start()
        guard let saved = SetupStore.shared.setups.first(where: { $0.id == setup.id }) else {
            throw SoundcheckIntentError.setupGone(setup.name)
        }
        engine.apply(saved)
        return .result(dialog: "\(saved.name) is on.")
    }
}

enum SoundcheckIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noSpeakers
    case setupGone(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noSpeakers: "Choose at least one speaker."
        case .setupGone(let name): "There's no saved setup called \(name) any more."
        }
    }
}

// MARK: Siri and Spotlight

struct SoundcheckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ApplySetupIntent(),
                    phrases: ["Apply \(\.$setup) in \(.applicationName)",
                              "Switch \(.applicationName) to \(\.$setup)",
                              "Apply a setup in \(.applicationName)"],
                    shortTitle: "Apply Setup",
                    systemImageName: "square.stack.3d.up")
        AppShortcut(intent: SwitchSpeakersIntent(),
                    phrases: ["Switch speakers in \(.applicationName)",
                              "Change speakers in \(.applicationName)"],
                    shortTitle: "Switch Speakers",
                    systemImageName: "hifispeaker.2")
        AppShortcut(intent: SetAppVolumeIntent(),
                    phrases: ["Set an app's volume in \(.applicationName)",
                              "Change an app's volume in \(.applicationName)"],
                    shortTitle: "Set App Volume",
                    systemImageName: "slider.horizontal.3")
    }
}
