import AppKit

/// Liquid Glass with rounded corners for a borderless window. The glass rounds its own fill, but
/// its backdrop and the window around it stay rectangular, so everything is clipped to the same
/// rounded shape (and the window's shadow follows it). The window must be exactly the glass's
/// size.
func makeGlassContainer(around content: NSView, cornerRadius: CGFloat) -> NSView {
    let glass = NSGlassEffectView()
    glass.style = .regular
    glass.cornerRadius = cornerRadius
    glass.contentView = content
    glass.autoresizingMask = [.width, .height]

    let clip = NSView()
    clip.wantsLayer = true
    clip.layer?.backgroundColor = .clear
    clip.layer?.cornerRadius = cornerRadius
    clip.layer?.cornerCurve = .continuous
    clip.layer?.masksToBounds = true
    clip.addSubview(glass)
    return clip
}

extension NSWindow {
    /// Sizes the window and the glass inside it together.
    func setGlassFrame(_ frame: NSRect, animated: Bool = false, duration: TimeInterval = 0.3) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
            contentView?.subviews.first?.frame = contentView?.bounds ?? .zero
        }
    }
}
