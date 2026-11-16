import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// The volume buttons, for the Mac: while the app's open (and connected), whatever is or isn't
/// playing, and while this device plays as a speaker. Each press moves what the main bar controls
/// (Speakers, Apps or Mics, chosen at the top of Sound and kept the same as on the Mac), and this
/// device's own volume is put back where it was, so the buttons keep working both ways.
@MainActor
@Observable
final class VolumeButtons {
    static let shared = VolumeButtons()

    private var observation: NSKeyValueObservation?
    private var parked: Float?
    /// Until when changes are this app putting the volume back (and not a press).
    private var ignoreUntil = Date.distantPast
    /// MPVolumeView's slider is the only way an app can set the volume; it's kept off screen
    /// (and having one in a window also keeps iOS's volume pop-up from covering the app).
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    private var managingSession = false
    /// This device's volume before it was moved off the top or bottom (put back afterwards).
    private var nudgedFrom: Float?

    var isActive: Bool { observation != nil }

    /// Starts or stops listening to the buttons as the app opens and closes, the link comes and
    /// goes, and playing here starts and stops.
    func update() {
        let open = UIApplication.shared.applicationState == .active && MacLink.shared.isConnected
        let wanted = SpeakerPlayer.shared.isPlaying || open
        if wanted && observation == nil { begin() } else if !wanted && observation != nil { end() }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        if !SpeakerPlayer.shared.isPlaying && !MicStreamer.shared.isRunning {
            // The volume is only reported while the session's active; mixing, so nothing else stops.
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(true)
            managingSession = true
        }
        attachVolumeView()
        // At the very top or bottom a press can't be seen: start just inside.
        var volume = session.outputVolume
        nudgedFrom = nil
        if volume >= 0.999 { nudgedFrom = volume; volume = 15.0 / 16; setSystemVolume(volume) }
        if volume <= 0.001 { nudgedFrom = volume; volume = 1.0 / 16; setSystemVolume(volume) }
        parked = volume
        observation = session.observe(\.outputVolume, options: [.new, .old]) { _, change in
            guard let new = change.newValue, let old = change.oldValue else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { VolumeButtons.shared.changed(from: old, to: new) } }
        }
    }

    private func end() {
        observation?.invalidate()
        observation = nil
        // Moved off the top or bottom to see presses: back where it was.
        if let nudgedFrom, let parked, abs(AVAudioSession.sharedInstance().outputVolume - parked) < 0.001 {
            setSystemVolume(nudgedFrom)
        }
        nudgedFrom = nil
        parked = nil
        if managingSession {
            managingSession = false
            if !SpeakerPlayer.shared.isPlaying && !MicStreamer.shared.isRunning {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func changed(from old: Float, to new: Float) {
        guard let parked else { return }
        // This app putting the volume back (it can take a step or two to land): not a press.
        if Date() < ignoreUntil { return }
        let delta = new - old
        guard abs(delta) > 0.001 else { return }
        // Whatever the main bar controls, as the Mac's own volume keys do; one press is a sixteenth.
        let knob = MacLink.shared.state?.knob ?? "speakers"
        let step: Float = delta > 0 ? 1.0 / 16 : -1.0 / 16
        MacLink.shared.stepKnobLocally(step)
        MacLink.shared.send(.step(knob: knob, delta: step))
        // Put this device's own volume back once the presses stop (not between them, which
        // would swallow the next), or now if it's at the top or bottom, where presses can't be seen.
        resetWork?.cancel()
        if new <= 0.001 || new >= 0.999 {
            putBack(parked)
        } else {
            let work = DispatchWorkItem { MainActor.assumeIsolated { VolumeButtons.shared.putBack(parked) } }
            resetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }

    private var resetWork: DispatchWorkItem?

    private func putBack(_ volume: Float) {
        resetWork = nil
        guard abs(AVAudioSession.sharedInstance().outputVolume - volume) > 0.001 else { return }
        ignoreUntil = Date().addingTimeInterval(0.35)
        setSystemVolume(volume)
    }

    private func attachVolumeView() {
        guard volumeView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        volumeView.alpha = 0.01
        window?.addSubview(volumeView)
    }

    private func setSystemVolume(_ volume: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = volume
        slider.sendActions(for: .valueChanged)
    }
}
