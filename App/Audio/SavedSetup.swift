import AppIntents
import Foundation
import Observation

/// A saved layout: which speakers play and how loud, each app's level, mute and outputs, and
/// what's routed into Soundcheck Mic. Speakers and mics in a setup don't have to be plugged in.
struct SavedSetup: Codable, Identifiable, Equatable {
    struct Level: Codable, Equatable, Identifiable {
        var id: String // device UID
        var volume: Float
    }

    struct AppLevel: Codable, Equatable, Identifiable {
        var id: String // bundle ID
        var volume: Float
        var muted = false
        /// Its own speakers (used when the setup splits apps); nil follows the main speakers.
        var outputs: [String]?
    }

    struct Route: Codable, Equatable {
        var isOn = false
        var microphones: [Level] = []
        var apps: [String] = []
    }

    /// When a setup puts itself in place: a speaker or mic connecting (its UID), or an app opening
    /// (its bundle ID).
    struct Trigger: Codable, Equatable {
        enum Kind: String, Codable { case deviceConnects, appOpens }
        var kind: Kind
        var id: String
    }

    var id = UUID()
    var name: String
    /// Applied by itself when this happens (nil: only by hand).
    var trigger: Trigger?
    /// The speakers to play through, the first being macOS's default.
    var speakers: [Level] = []
    var apps: [AppLevel] = []
    var split = false
    var route = Route()
}

/// The saved setups, kept in Soundcheck's settings.
@MainActor
@Observable
final class SetupStore {
    static let shared = SetupStore()
    private static let key = "savedSetups"

    private(set) var setups: [SavedSetup] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([SavedSetup].self, from: data) {
            setups = saved
        }
    }

    func add(_ setup: SavedSetup) {
        setups.append(setup)
        save()
    }

    func update(_ setup: SavedSetup) {
        guard let index = setups.firstIndex(where: { $0.id == setup.id }) else { return }
        setups[index] = setup
        save()
    }

    func remove(_ id: SavedSetup.ID) {
        setups.removeAll { $0.id == id }
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(setups), forKey: Self.key)
        // Siri's "Apply <setup> in Soundcheck" learns the new names.
        SoundcheckShortcuts.updateAppShortcutParameters()
    }
}
