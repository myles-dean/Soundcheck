import AppIntents
import Foundation

/// What the intents do, in the app: connect to the Mac if need be, then ask.
@MainActor
enum CompanionActions {
    static func send(_ command: RemoteCommand) async {
        guard await MacLink.shared.whenConnected(timeout: 8) else { return }
        MacLink.shared.send(command)
        // Give it a moment to go before iOS suspends the app again.
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func useAsSpeaker(_ on: Bool) async {
        guard await MacLink.shared.whenConnected(timeout: 8) else { return }
        MacLink.shared.send(.useAsSpeaker(on))
        guard on else {
            SpeakerPlayer.shared.stop()
            return
        }
        // The Mac answers with the sound to play; playing keeps the app running from then on.
        for _ in 0..<30 where !SpeakerPlayer.shared.isPlaying {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

extension SharedState {
    @MainActor static func update(from state: RemoteState) {
        macName = state.macShortName
        playing = state.playing
        let me = state.companions.first { $0.id == PairingStore.deviceID }
        if let me {
            if !me.isSpeaker && !SpeakerPlayer.shared.isPlaying { speakerOn = false }
            micOn = me.isMicrophone
        }
    }
}

struct CompanionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMacHereIntent(value: true), phrases: ["Play my Mac on \(.applicationName)", "\(.applicationName) play Mac here"],
                    shortTitle: "Play Mac Here", systemImageName: "hifispeaker")
        AppShortcut(intent: MacPlayPauseIntent(), phrases: ["Pause my Mac with \(.applicationName)", "\(.applicationName) play or pause"],
                    shortTitle: "Play or Pause Mac", systemImageName: "playpause")
        AppShortcut(intent: MacVolumeIntent(up: true), phrases: ["Turn my Mac up with \(.applicationName)"],
                    shortTitle: "Turn Mac Up", systemImageName: "speaker.plus")
        AppShortcut(intent: MacVolumeIntent(up: false), phrases: ["Turn my Mac down with \(.applicationName)"],
                    shortTitle: "Turn Mac Down", systemImageName: "speaker.minus")
    }
}
