import AppKit
import Observation
import SwiftUI

/// Which dropdowns are open. They start closed each time the panel opens, like a menu.
@MainActor
@Observable
final class PanelState {
    static let shared = PanelState()
    var outputsOpen = false
    var inputsOpen = false
    /// The app whose own outputs are listed (while split).
    var routingApp: String?
    var optionsOpen = false
    /// The Options section that's open (one at a time).
    var optionsGroup: SettingsGroup?
    var pinsOpen = false
    var airPlayOpen = false
    var appsOpen = false
    /// The EQ that's open: whose, and which bar it was opened from (a speaker's EQ can be opened
    /// from the main bar or from its own bar in the list, and only that one opens).
    var shaping: EQSpot?
    /// The bar whose list of microphones to hear is open (right-clicking its headphones button).
    var hearing: EQSpot?
    /// The app or microphone whose effects are open, and the effect showing its controls.
    var effecting: AudioEngine.ShapeTarget?
    var openEffect: UUID?
    /// Browsers whose tabs are listed under them in Apps.
    var openBrowsers: Set<String> = []

    func reset() {
        outputsOpen = false
        inputsOpen = false
        routingApp = nil
        optionsOpen = false
        optionsGroup = nil
        pinsOpen = false
        airPlayOpen = false
        appsOpen = false
        shaping = nil
        hearing = nil
        effecting = nil
        openEffect = nil
    }
}

/// The panel that drops from the menu bar icon, in Control Center's Liquid Glass. The window is
/// always exactly the size of its glass card and grows or shrinks with it as the dropdowns open
/// and close. It closes when you click anywhere else or press Escape.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 320
    static let cornerRadius: CGFloat = 24
    /// The dropdowns' animation; the window resizes over the same time.
    static let animationDuration: TimeInterval = 0.32

    private let panel: KeyPanel
    private var hosting: NSHostingView<PanelRoot>!
    private var top: CGFloat = 0
    private var left: CGFloat = 0
    private var shadowTimer: Timer?
    private var outsideClicks: Any?
    private var hiddenAt = Date.distantPast
    var onVisibilityChange: ((Bool) -> Void)?

    override init() {
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hide() }
        hosting = NSHostingView(rootView: PanelRoot(onHeight: { [weak self] in self?.contentHeightChanged($0) }))
        hosting.sizingOptions = []
        panel.contentView = makeGlassContainer(around: hosting, cornerRadius: Self.cornerRadius)
    }

    var isVisible: Bool { panel.isVisible }

    /// From the menu bar icon: opens under it, or closes if it's open (including when the click on
    /// the icon is what just closed it).
    func toggle(under anchor: NSRect?) {
        if panel.isVisible || Date().timeIntervalSince(hiddenAt) < 0.3 { hide() } else { show(under: anchor) }
    }

    /// Centred under `anchor` (the menu bar icon's frame on screen), or at the top right of the
    /// screen the pointer is on if there's no icon to hang from.
    func show(under anchor: NSRect?) {
        PanelState.shared.reset()
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } }
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        top = visible.maxY - 6
        left = visible.maxX - Self.width - 8
        if let anchor { left = min(max(anchor.midX - Self.width / 2, visible.minX + 8), visible.maxX - Self.width - 8) }

        panel.setGlassFrame(frame(height: Self.measureHeight()))
        if !panel.isVisible {
            panel.alphaValue = 0
            onVisibilityChange?(true)
        }
        panel.makeKeyAndOrderFront(nil)
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        refreshShadow(for: 0.2)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    func hide() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        guard panel.isVisible else { return }
        hiddenAt = Date()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.onVisibilityChange?(false)
            }
        }
    }

    // Clicking another app, the desktop or the menu bar takes key status away; a window of
    // Soundcheck's own doesn't count.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if let key = NSApp.keyWindow, key !== self.panel { return }
            self.hide()
        }
    }

    /// The card's natural height, measured by laying out a copy of it.
    private static func measureHeight() -> CGFloat {
        let sizing = NSHostingView(rootView: SoundPanelView().frame(width: width).fixedSize(horizontal: false, vertical: true))
        return ceil(sizing.fittingSize.height)
    }

    private func frame(height: CGFloat) -> NSRect {
        NSRect(x: left, y: top - height, width: Self.width, height: height)
    }

    /// A dropdown opened or closed (or an app row came or went): the window follows the card
    /// over the same animation, keeping its top edge where it is.
    private func contentHeightChanged(_ height: CGFloat) {
        let height = ceil(height)
        guard panel.isVisible, abs(height - panel.frame.height) > 0.5 else { return }
        panel.setGlassFrame(frame(height: height), animated: true, duration: Self.animationDuration)
        refreshShadow(for: Self.animationDuration + 0.1)
    }

    /// The window shadow follows the rounded shape only when recomputed, so keep recomputing it
    /// while the window changes size.
    private func refreshShadow(for duration: TimeInterval) {
        shadowTimer?.invalidate()
        let end = Date().addingTimeInterval(duration)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                self?.panel.invalidateShadow()
                if Date() > end { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shadowTimer = timer
    }
}

final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The card at its natural height, pinned to the top of the window. While the window resizes the
/// card is briefly taller or shorter than it; a GeometryReader keeps the card at the top-left
/// even then (a plain frame centres content that doesn't fit, which made it bounce).
struct PanelRoot: View {
    let onHeight: (CGFloat) -> Void

    var body: some View {
        GeometryReader { _ in
            SoundPanelView()
                .frame(width: PanelController.width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
    }
}
