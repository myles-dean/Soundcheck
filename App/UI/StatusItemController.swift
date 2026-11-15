import AppKit
import Symbols

/// The menu bar icon: a speaker whose waves fill in with the volume, crossed out when muted,
/// animating between them like macOS's own Sound icon. It's only there while an app is playing
/// sound or listening to a microphone, or while the panel or the volume pill is showing.
@MainActor
final class StatusItemController: NSObject {
    /// The size of macOS's own Sound icon (measured from the menu bar).
    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)

    private let item: NSStatusItem
    private let iconView = NSImageView()
    private let engine = AudioEngine.shared
    private var holds: Set<String> = []
    private var hideWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var shownSymbol: String?
    private var shownValue: Double = -1
    private var latestImage: NSImage?
    private var transitionEnd: DispatchWorkItem?
    var onClick: (() -> Void)?

    override init() {
        // Wide enough for the speaker with all its waves, so the icon doesn't change width (and
        // nudge the other menu bar icons) when it's muted.
        let width = (NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbolConfiguration)?.size.width ?? 24) + 10
        item = NSStatusBar.system.statusItem(withLength: ceil(width))
        super.init()
        item.autosaveName = "Soundcheck"
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("Soundcheck")
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleNone
            iconView.contentTintColor = .labelColor
            iconView.isHidden = true
            button.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        item.isVisible = false
        for name in [AudioEngine.didChangeVolume, AudioEngine.didChangeActivity] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        update()
    }

    /// The icon's frame on screen, once it's in its place in the menu bar (just after it
    /// appears, its window can still be elsewhere).
    var frameOnScreen: NSRect? {
        guard item.isVisible, let button = item.button, let window = button.window, let screen = window.screen else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frame.width > 0, frame.minY >= screen.visibleFrame.maxY - 4 else { return nil }
        return frame
    }

    /// Calls `body` with the icon's frame as soon as it's in the menu bar (or nil if it isn't
    /// there within half a second).
    func whenPlaced(_ body: @escaping (NSRect?) -> Void, attempts: Int = 25) {
        if let frame = frameOnScreen { body(frame); return }
        guard attempts > 0 else { body(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.whenPlaced(body, attempts: attempts - 1)
        }
    }

    /// Keeps the icon in the menu bar for a reason ("panel", "hud") until released.
    func hold(_ reason: String, _ on: Bool) {
        if on { holds.insert(reason) } else { holds.remove(reason) }
        if reason == "panel" { item.button?.highlight(on) }
        update()
    }

    func update() {
        // The speakers' volume (the loudest speaker in use), whatever the main slider controls.
        let volume = Double(engine.speakersVolume)
        let muted = engine.isMuted || volume < 0.001
        let symbol = muted ? "speaker.slash.fill" : "speaker.wave.3.fill"
        let value = muted ? 1 : volume
        if symbol != shownSymbol || abs(value - shownValue) > 0.001,
           let image = NSImage(systemSymbolName: symbol, variableValue: value, accessibilityDescription: "Volume")?
            .withSymbolConfiguration(Self.symbolConfiguration) {
            image.isTemplate = true
            latestImage = image
            if let button = item.button, shownSymbol != nil && symbol != shownSymbol {
                // Muting draws the slash on and unmuting takes it off, like the Sound icon. The
                // animation plays in an image view over the button, which then gets the icon back.
                iconView.image = button.image
                iconView.isHidden = false
                button.image = nil
                iconView.setSymbolImage(image, contentTransition: ReplaceSymbolEffect.replace.magic(fallback: .replace))
                transitionEnd?.cancel()
                let end = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.item.button?.image = self.latestImage
                    self.iconView.isHidden = true
                    self.transitionEnd = nil
                }
                transitionEnd = end
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: end)
            } else if transitionEnd == nil {
                // Volume changes just fill the waves in or out, drawn by the menu bar itself.
                item.button?.image = image
            }
            shownSymbol = symbol
            shownValue = value
        }

        if engine.keepInMenuBar || engine.isPlaying || engine.isListening || !holds.isEmpty {
            hideWork?.cancel()
            hideWork = nil
            item.isVisible = true
        } else if item.isVisible && hideWork == nil {
            // A short grace period, so gaps between songs don't make it blink.
            let hide = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                if !self.engine.keepInMenuBar && !self.engine.isPlaying && !self.engine.isListening && self.holds.isEmpty {
                    self.item.isVisible = false
                }
            }
            hideWork = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: hide)
        }
    }

    @objc private func clicked() { onClick?() }
}
