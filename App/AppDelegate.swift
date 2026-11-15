import AppIntents
import AppKit
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // The crash watchdog is this same executable, started by Soundcheck with --watchdog.
        if CommandLine.arguments.contains(Watchdog.argument) { Watchdog.run() }
        // A Chrome-based browser starting Soundcheck as its extension's native messaging helper.
        if BrowserHelper.isLaunch(CommandLine.arguments) { BrowserHelper.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let engine = AudioEngine.shared
    private var statusItem: StatusItemController!
    private var panel: PanelController!
    private var hud: VolumeHUD!
    private let welcome = WelcomeWindowController()
    private var isQuitting = false
    private var termSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Watchdog.start()
        NSApp.mainMenu = makeMainMenu()
        engine.start()
        SoundcheckShortcuts.updateAppShortcutParameters()
        Updater.shared.start()
        BrowserTabs.shared.onCallsChanged = { AudioEngine.shared.browserCallsChanged() }
        BrowserTabs.shared.start()

        statusItem = StatusItemController()
        panel = PanelController()
        hud = VolumeHUD()
        statusItem.onClick = { [weak self] in self?.togglePanel() }
        panel.onVisibilityChange = { [weak self] visible in
            self?.statusItem.hold("panel", visible)
            self?.engine.holdApps("panel", visible)
            self?.engine.setMetering(visible)
        }
        hud.onVisibilityChange = { [weak self] visible in
            self?.statusItem.hold("hud", visible)
            self?.engine.holdApps("hud", visible)
        }

        VolumeKeys.shared.onKey = { [weak self] key, fine in self?.volumeKey(key, fine: fine) }
        VolumeKeys.shared.start()
        MicMuteShortcut.shared.onPress = { [weak self] in
            guard let self else { return }
            self.engine.setMicsMuted(!self.engine.micsMuted)
        }
        MicMuteShortcut.shared.start()
        // Pills for things that happen by themselves: a muted app starting, the mics muted from
        // the shortcut, headphones taking over.
        engine.onNotice = { [weak self] notice in self?.showNotice(notice) }
        engine.onHeadphones = { [weak self] in self?.showLevels() }
        SetupsWindowController.shared.onOpen = { [weak self] in self?.panel.hide() }
        BrowserSetupWindowController.shared.onOpen = { [weak self] in self?.panel.hide() }
        handleTermSignal()

        // The first time, start at login (it replaces the Sound menu) and show the panel. After
        // that, opening the app yourself shows the panel; starting at login doesn't.
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: "launchedBefore")
        defaults.set(true, forKey: "launchedBefore")
        if firstLaunch { try? SMAppService.mainApp.register() }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginItem = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let isOpenApp = event?.eventClass == kCoreEventClass && event?.eventID == kAEOpenApplication
        if !WelcomeWindowController.hasBeenSeen {
            // The first time: the walkthrough (settings, permissions, hiding the Sound icon).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.welcome.show() }
        } else if isOpenApp && !isLoginItem && !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if welcome.isVisible || !WelcomeWindowController.hasBeenSeen { welcome.show() } else { showPanel() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit()
        return .terminateNow
    }

    // MARK: Panel

    private func togglePanel() {
        panel.toggle(under: statusItem.frameOnScreen)
    }

    /// Opened as an app (Spotlight, Launchpad, Finder): the icon appears in the menu bar if it
    /// isn't there, and the panel drops from it.
    private func showPanel() {
        statusItem.hold("panel", true)
        statusItem.whenPlaced { [weak self] frame in self?.panel.show(under: frame) }
    }

    // MARK: Volume keys

    private func volumeKey(_ key: VolumeKeys.Key, fine: Bool) {
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .up: engine.step(step)
        case .down: engine.step(-step)
        case .mute: engine.setMuted(!engine.isMuted)
        }
        showLevels()
    }

    /// The pill with the levels the volume keys move. It takes the panel's place, hanging from the
    /// menu bar icon (which may need a moment to appear).
    private func showLevels() {
        panel.hide()
        statusItem.hold("hud", true)
        statusItem.whenPlaced { [weak self] frame in self?.hud.show(under: frame) }
    }

    private func showNotice(_ notice: HUDNotice) {
        statusItem.hold("hud", true)
        statusItem.whenPlaced { [weak self] frame in self?.hud.show(notice, under: frame) }
    }

    // MARK: Quitting

    /// Every app gets its own sound back (the taps go away with Soundcheck anyway, but this is
    /// tidier and immediate).
    private func quit() {
        guard !isQuitting else { return }
        isQuitting = true
        Watchdog.quitting()
        engine.shutdown()
    }

    private func handleTermSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.quit()
            exit(0)
        }
        source.resume()
        termSignal = source
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Soundcheck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return main
    }
}
