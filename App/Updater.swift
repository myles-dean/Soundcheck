import Sparkle

/// Updates for copies installed from the DMG (Homebrew installs can update through brew too).
/// Sparkle checks the latest GitHub release's appcast once a day and offers what's new; an update
/// only installs if it's signed with Soundcheck's update key (SUPublicEDKey in Info.plist).
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    private init() {}

    func start() {
        controller.startUpdater()
    }

    /// Options › Check for Updates…
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
