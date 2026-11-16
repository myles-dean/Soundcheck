import AppIntents

// Intent descriptions mustn't name Mac, iPhone or iPad: App Store Connect rejects the build
// (ITMS-90626, Siri support). Titles and phrases may.
import Foundation

// Actions for Control Center, the Lock Screen, widgets, Shortcuts and Siri. They're audio
// playback intents, so iOS runs them in the app (in the background, without opening it), which
// can then start playing; the widgets only show the buttons.

struct PlayMacHereIntent: SetValueIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Mac Here"
    static let description = IntentDescription("Plays your computer's sound on this device, as one of its speakers, in sync with the others.")

    @Parameter(title: "Play Here")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    func perform() async throws -> some IntentResult {
        #if COMPANION_APP
        await CompanionActions.useAsSpeaker(value)
        #endif
        return .result()
    }
}

struct MacPlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause Mac"
    static let description = IntentDescription("Plays or pauses whatever's playing on your computer.")

    func perform() async throws -> some IntentResult {
        #if COMPANION_APP
        await CompanionActions.send(.playPause)
        #endif
        return .result()
    }
}

struct MacNextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip on Mac"
    static let description = IntentDescription("Skips to the next track on your computer.")

    func perform() async throws -> some IntentResult {
        #if COMPANION_APP
        await CompanionActions.send(.nextTrack)
        #endif
        return .result()
    }
}

struct MacVolumeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Turn Mac Up or Down"
    static let description = IntentDescription("Turns your computer's speakers up or down a step.")

    @Parameter(title: "Up")
    var up: Bool

    init() {}
    init(up: Bool) { self.up = up }

    func perform() async throws -> some IntentResult {
        #if COMPANION_APP
        await CompanionActions.send(.step(knob: "speakers", delta: up ? 1.0 / 16 : -1.0 / 16))
        #endif
        return .result()
    }
}
