import AppIntents
import SwiftUI
import WidgetKit

/// Control Center controls, and Lock Screen and Home Screen widgets, for the Mac: play it here,
/// play or pause it, turn it up or down. The buttons run their actions in the app, in the
/// background, so nothing opens.
@main
struct CompanionWidgets: WidgetBundle {
    var body: some Widget {
        PlayHereControl()
        PlayPauseControl()
        MacRemoteWidget()
    }
}

// MARK: Control Center

struct PlayHereControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.mylesdean.Soundcheck.Companion.playHere", provider: PlayHereValue()) { isOn in
            ControlWidgetToggle(SharedState.macName, isOn: isOn, action: PlayMacHereIntent()) { on in
                Label(on ? "Playing Here" : "Play Here", systemImage: on ? "hifispeaker.fill" : "hifispeaker")
            }
            .tint(.blue)
        }
        .displayName("Play Mac Here")
        .description("Plays your Mac's sound on this device.")
    }
}

struct PlayHereValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { SharedState.speakerOn }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.mylesdean.Soundcheck.Companion.playPause") {
            ControlWidgetButton(action: MacPlayPauseIntent()) {
                Label("Play/Pause \(SharedState.macName)", systemImage: "playpause.fill")
            }
        }
        .displayName("Play or Pause Mac")
        .description("Plays or pauses whatever's playing on your Mac.")
    }
}

// MARK: Lock Screen and Home Screen

struct MacEntry: TimelineEntry {
    let date = Date()
    let macName: String
    let playing: [String]
    let speakerOn: Bool
}

struct MacProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacEntry { MacEntry(macName: "MacBook", playing: ["Music"], speakerOn: false) }
    func getSnapshot(in context: Context, completion: @escaping (MacEntry) -> Void) { completion(current) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacEntry>) -> Void) {
        completion(Timeline(entries: [current], policy: .never)) // the app reloads it when things change
    }
    private var current: MacEntry {
        MacEntry(macName: SharedState.macName, playing: SharedState.playing, speakerOn: SharedState.speakerOn)
    }
}

struct MacRemoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.mylesdean.Soundcheck.Companion.remote", provider: MacProvider()) { entry in
            MacRemoteView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mac Remote")
        .description("Play, pause and turn your Mac up or down.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

struct MacRemoteView: View {
    let entry: MacEntry
    @Environment(\.widgetFamily) private var family

    private var subtitle: String {
        entry.playing.isEmpty ? "Not playing" : ListFormatter.localizedString(byJoining: entry.playing)
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: MacPlayPauseIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: entry.playing.isEmpty ? "play.fill" : "pause.fill").font(.title2)
                }
            }
            .buttonStyle(.plain)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.macName).font(.headline).widgetAccentable()
                Text(subtitle).font(.caption).lineLimit(1)
                HStack(spacing: 14) {
                    Button(intent: MacVolumeIntent(up: false)) { Image(systemName: "speaker.minus.fill") }
                    Button(intent: MacPlayPauseIntent()) { Image(systemName: entry.playing.isEmpty ? "play.fill" : "pause.fill") }
                    Button(intent: MacVolumeIntent(up: true)) { Image(systemName: "speaker.plus.fill") }
                }
                .buttonStyle(.plain)
                .font(.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let data = SharedState.macTile, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().frame(width: 34, height: 34)
                    }
                    Spacer()
                    Button(intent: PlayMacHereIntent(value: !entry.speakerOn)) {
                        Image(systemName: entry.speakerOn ? "hifispeaker.fill" : "hifispeaker")
                    }
                    .tint(entry.speakerOn ? .blue : .secondary)
                }
                Text(entry.macName).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                HStack {
                    Button(intent: MacVolumeIntent(up: false)) { Image(systemName: "minus") }
                    Spacer()
                    Button(intent: MacPlayPauseIntent()) { Image(systemName: entry.playing.isEmpty ? "play.fill" : "pause.fill") }
                    Spacer()
                    Button(intent: MacVolumeIntent(up: true)) { Image(systemName: "plus") }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            }
        }
    }
}
