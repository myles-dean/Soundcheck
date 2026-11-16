import SwiftUI

/// The first thing you see: Soundcheck's icon with its faders moving like a mixing desk and sound
/// rippling out, what the app does, that it needs Soundcheck on a Mac (with where to get it), and
/// Get Started. Nothing asks for a permission until Get Started (looking for the Mac is what asks
/// for the local network).
struct WelcomeView: View {
    let onStart: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var shown = false

    static let soundcheckURL = URL(string: "https://github.com/myles-dean/Soundcheck")!
    static let welcomedKey = "welcomed"
    static var hasStarted: Bool { UserDefaults.standard.bool(forKey: welcomedKey) }
    private var kind: String { PairingStore.deviceKind }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            // Centred when there's room (iPad), scrolling under Get Started when there isn't (a
            // folded iPhone Duo).
            GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    SoundcheckLogo(size: 128, animated: true)
                        // A soft glow of the icon's red around it (wherever it ends up).
                        .background {
                            RadialGradient(colors: [SoundcheckLogo.red.opacity(0.28), .clear], center: .center,
                                           startRadius: 0, endRadius: 420)
                                .frame(width: 840, height: 840)
                                .allowsHitTesting(false)
                        }
                        .padding(.top, 40)
                        .padding(.bottom, 36)

                    Text("Soundcheck")
                        .font(.largeTitle.bold())
                    Text("Your Mac's sound, from your \(kind).")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 22) {
                        feature("slider.horizontal.3", "Control Everything",
                                "Speakers, apps, mics, EQ and effects on your Mac, from here.")
                        feature("hifispeaker.fill", "Play Your Mac Here",
                                "This \(kind) becomes one of your Mac's speakers, in sync with the others.")
                        feature("mic.fill", "Be Its Microphone",
                                "Your Mac hears this \(kind)'s microphone, in every app.")
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 16)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
            .safeAreaInset(edge: .bottom) {
                footer
                    // Solid behind it, with a short fade above, so what scrolls under it doesn't
                    // show through.
                    .background(alignment: .top) {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 32)
                            Color(.systemBackground)
                        }
                        .padding(.top, -32)
                        .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.5)) { shown = true }
        }
    }

    /// What it needs (with where to get it), and Get Started.
    private var footer: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Works with Soundcheck, the free sound app for the Mac's menu bar (macOS 26 or later), on the same Wi-Fi.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Get Soundcheck for Mac") { openURL(Self.soundcheckURL) }
                    .font(.footnote.weight(.semibold))
            }
            Button {
                onStart()
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Soundcheck's icon, drawn live: the red tile and its three faders. Animated, it pops in, the
/// faders sweep up to where the icon has them and then move gently like a mixing desk's, and
/// rings of sound ripple out behind it (still, with Reduce Motion).
struct SoundcheckLogo: View {
    static let red = Color(red: 1, green: 0.12, blue: 0.30)
    static let top = Color(red: 1, green: 0.30, blue: 0.45)
    static let bottom = Color(red: 1, green: 0, blue: 0.18)

    var size: CGFloat
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var appeared = false

    /// The icon's knobs (their centres on the 104-unit-tall glyph, 9 to 95 being the ends of travel).
    private static let rest: [CGFloat] = [63, 31, 75]
    private var moving: Bool { animated && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: !moving)) { context in
            let time = moving ? context.date.timeIntervalSince(start) : 10
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .fill(LinearGradient(colors: [Self.top, Self.bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            .blendMode(.plusLighter)
                    )
                    .shadow(color: Self.red.opacity(0.45), radius: size * 0.16, y: size * 0.06)
                    .frame(width: size, height: size)
                faders(time)
            }
            .frame(width: size, height: size)
            // Behind, and free to spread past the icon without making it bigger.
            .background { if moving { ripples(time) } }
        }
        .scaleEffect(appeared || !moving ? 1 : 0.55)
        .opacity(appeared || !moving ? 1 : 0)
        .onAppear {
            start = Date()
            if moving { withAnimation(.spring(duration: 0.8, bounce: 0.4)) { appeared = true } }
        }
        .accessibilityHidden(true)
    }

    /// Where each knob is at `time`: up from the bottom into place, then a slow, uneven drift
    /// around it (three speeds, so they never move together).
    private func knob(_ index: Int, _ time: TimeInterval) -> CGFloat {
        let rest = Self.rest[index]
        let delay = 0.25 + Double(index) * 0.12
        let rise = min(max((time - delay) / 0.9, 0), 1)
        let eased = 1 - pow(1 - rise, 3) // ease out
        var y = 95 + (rest - 95) * eased
        let settle = max(time - delay - 0.9, 0)
        if settle > 0 {
            let speeds = [1.05, 1.45, 0.85], phases = [0.0, 1.7, 3.1]
            let swing = min(settle / 1.2, 1) * 13 // grows in, so it doesn't jump
            y += CGFloat(swing * (0.65 * sin(settle * speeds[index] * 2 * .pi / 2 + phases[index])
                                  + 0.35 * sin(settle * speeds[index] * 3.1 + phases[index] * 0.5)))
        }
        return min(max(y, 9), 95)
    }

    private func faders(_ time: TimeInterval) -> some View {
        Canvas { context, canvas in
            // The glyph is 120 × 104 units, drawn at 5/1024 of the icon per unit (as in its
            // Icon Composer file), centred.
            let unit = canvas.width * 5 / 1024
            let origin = CGPoint(x: (canvas.width - 120 * unit) / 2, y: (canvas.height - 104 * unit) / 2)
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: origin.x + x * unit, y: origin.y + y * unit, width: width * unit, height: height * unit),
                     cornerRadius: radius * unit, style: .continuous)
            }
            for (index, x) in [CGFloat(15), 56, 97].enumerated() {
                context.fill(rect(x, 2, 8, 100, 4), with: .color(.white))
                let center = knob(index, time)
                context.fill(rect(x - 13, center - 9, 34, 18, 7), with: .color(.white))
            }
        }
        .frame(width: size, height: size)
    }

    /// Rings of sound going out from behind the icon, one after another, fading as they go.
    private func ripples(_ time: TimeInterval) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                let progress = ((time - 0.6) / 3.2 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                let visible = time > 0.6 + Double(ring) * 3.2 / 3
                Circle()
                    .stroke(Self.red.opacity(visible ? 0.45 * (1 - progress) : 0), lineWidth: 2)
                    .frame(width: size * (1.05 + 1.35 * progress), height: size * (1.05 + 1.35 * progress))
            }
        }
    }
}
