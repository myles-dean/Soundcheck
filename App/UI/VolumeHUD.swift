import AppKit
import SwiftUI

/// The pill that drops from the menu bar icon when you press a volume key, like macOS's own,
/// with a bar for every output you're playing through.
@MainActor
final class VolumeHUD {
    private let panel: NSPanel
    private let hosting = NSHostingView(rootView: VolumeHUDView())
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false
    var onVisibilityChange: ((Bool) -> Void)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        hosting.sizingOptions = []
        panel.contentView = makeGlassContainer(around: hosting, cornerRadius: 22)
    }

    static let width: CGFloat = 285
    private var shownFrame = NSRect.zero

    /// A message instead of levels (a muted app started, the mics were muted).
    func show(_ notice: HUDNotice, under anchor: NSRect?) {
        HUDState.shared.notice = notice
        present(under: anchor, for: 2.2)
    }

    /// Shows it (or keeps it up) centred under `anchor`, the menu bar icon's frame on screen, and
    /// fades it out a moment after the last key press.
    func show(under anchor: NSRect?) {
        HUDState.shared.notice = nil
        present(under: anchor, for: 1.6)
    }

    private func present(under anchor: NSRect?, for duration: TimeInterval) {
        hideWork?.cancel()
        // Measured on a copy: the hosting view in the window doesn't size itself (its fitting
        // size is zero), so the window can stay exactly the glass's size.
        let size = NSHostingView(rootView: VolumeHUDView()).fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: visible.maxX - size.width - 10, y: visible.maxY - size.height - 6)
        if let anchor { origin.x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8) }
        let frame = NSRect(origin: origin, size: size).integral
        // Only when it changes: resizing on every key press makes the contents redraw (flicker).
        if frame != shownFrame || !isVisible {
            shownFrame = frame
            panel.setGlassFrame(frame)
            panel.invalidateShadow()
        }
        if !isVisible {
            isVisible = true
            onVisibilityChange?(true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }

        let hide = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hide)
    }

    func hide() {
        hideWork?.cancel()
        guard isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.onVisibilityChange?(false)
            }
        }
    }
}

/// Only the group the volume keys are changing: the speakers sound is going to (like macOS's own),
/// the apps in the Apps list, or the microphones in use.
struct VolumeHUDView: View {
    private var engine = AudioEngine.shared
    private var hud = HUDState.shared

    var body: some View {
        if let notice = hud.notice {
            HUDNoticeView(notice: notice)
        } else {
            levels
        }
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch engine.knob {
            case .speakers:
                ForEach(engine.playsLocally ? engine.activeOutputs : []) { device in
                    HUDRow(title: device.name, value: engine.outputVolume(device), muted: engine.isMuted)
                }
                ForEach(engine.activeAirPlay) { speaker in
                    HUDRow(title: speaker.name, value: engine.airPlayVolume(speaker), muted: engine.isMuted)
                }
            case .apps:
                if engine.visibleApps.isEmpty {
                    HUDRow(title: "Apps", value: engine.knobValue, muted: false)
                }
                ForEach(engine.visibleApps) { app in
                    HUDRow(title: app.name, icon: app.icon, value: engine.appLevel(app.id), muted: engine.isAppMuted(app.id))
                }
            case .mics:
                if engine.activeMics.isEmpty {
                    HUDRow(title: "Microphone", value: engine.knobValue, muted: false, low: "mic.fill", high: "mic.and.signal.meter.fill")
                }
                ForEach(engine.activeMics) { device in
                    HUDRow(title: device.name, value: engine.micVolume(device) ?? 0, muted: false,
                           low: "mic.fill", high: "mic.and.signal.meter.fill")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 12)
        .frame(width: VolumeHUD.width, alignment: .leading)
    }
}

/// A name (with the app's icon for apps) over a level bar, laid out like macOS's volume pill.
struct HUDRow: View {
    let title: String
    var icon: NSImage?
    let value: Float
    let muted: Bool
    var low = "speaker.fill"
    var high = "speaker.wave.3.fill"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Solid white (black in light mode), not the glass's softened label colour.
        let ink = colorScheme == .dark ? Color.white : Color.black
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 17, height: 17)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
            HUDBar(value: value, muted: muted, low: low, high: high, ink: ink)
        }
    }
}

/// A 4 pt bar with a speaker at each end and the sixteen volume-key steps marked under it.
struct HUDBar: View {
    let value: Float
    let muted: Bool
    var low = "speaker.fill"
    var high = "speaker.wave.3.fill"
    var ink = Color.white

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: muted ? "speaker.slash.fill" : low)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink)
                .frame(width: 14)
            VStack(spacing: 3) {
                LevelBar(value: muted ? 0 : value, ink: ink)
                    .frame(height: 4)
                HStack(spacing: 0) {
                    ForEach(0...16, id: \.self) { step in
                        Circle().fill(ink.opacity(0.12)).frame(width: 1.5, height: 1.5)
                        if step < 16 { Spacer(minLength: 0) }
                    }
                }
            }
            .padding(.top, 4.5) // keeps the bar level with the speakers, the dots hanging below
            Image(systemName: high)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink)
        }
        .animation(.easeOut(duration: 0.1), value: value)
    }
}

/// A filled bar on a faint track.
struct LevelBar: View {
    let value: Float
    var ink = Color.white

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.1))
                Capsule()
                    .fill(ink)
                    .frame(width: max(geometry.size.height, geometry.size.width * CGFloat(value)))
                    .opacity(value > 0.001 ? 1 : 0)
            }
        }
    }
}
