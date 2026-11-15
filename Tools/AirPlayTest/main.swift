// AirPlayTest: a command-line check of Soundcheck's AirPlay sender (App/AirPlay).
//
//   AirPlayTest list
//       Browses for about 3 seconds and prints each speaker with its model, address, and the
//       protocol and pairing path a session will use.
//   AirPlayTest tone "<speaker name>" [seconds] [volume]
//       Plays a quiet 440 Hz tone (default 3 s at volume 0.15). Join names with "+" to play on
//       several speakers at once, in sync ("Living Room+Kitchen").
//
// Speakers with PTP support are timed with PTP, which needs UDP ports 319 and 320 (only one
// process can have them: quit Soundcheck first if it's streaming). AIRPLAY_TIMING=ntp forces the
// older NTP-style timing; SOUNDCHECK_PTP_ROLE=master makes this Mac the PTP grandmaster.
//
// Debug lines from the AirPlay code go to stderr. Ctrl-C stops playback cleanly.

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

/// Mutable state shared with callbacks (all on the main queue).
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

func usage() -> Never {
    print("""
        usage: AirPlayTest list
               AirPlayTest tone "<speaker name>[+<speaker name>…]" [seconds] [volume]
        """)
    exit(2)
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

@MainActor func browse(for seconds: TimeInterval, until done: ([AirPlaySpeaker]) -> Bool = { _ in false }) -> [AirPlaySpeaker] {
    let browser = AirPlayBrowser.shared
    browser.start()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.1)))
        if done(browser.speakers) { break }
    }
    let speakers = browser.speakers
    if speakers.isEmpty {
        print("No AirPlay speakers found.")
        if let problem = browser.problem {
            print(problem)
        } else {
            print("If there should be some, check that this terminal app is allowed in System Settings → Privacy & Security → Local Network.")
        }
    }
    browser.stop()
    return speakers
}

func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16, uppercase: true) }

func pairingDetail(_ speaker: AirPlaySpeaker) -> String {
    switch speaker.pairingRequirement {
    case .notNeeded: return "pairing not needed"
    case .mandatory: return "pairing mandatory (status \(hex(speaker.statusFlags)) has 0x200/0x8)"
    case .disabled: return "pairing disabled (acl=1: only people in its Home), will try anyway"
    case .unsupported: return "pairing type unsupported by pyatv (act=2 or a Mac), will try anyway"
    }
}

@MainActor func list() {
    let speakers = browse(for: 3)
    for speaker in speakers {
        let services = [speaker.raopServiceName.map { _ in "_raop._tcp" }, speaker.airplayServiceName.map { _ in "_airplay._tcp" }]
            .compactMap { $0 }.joined(separator: " + ")
        let paired = AirPlayCredentialStore.contains(deviceID: speaker.id)
        print("\(speaker.name) — \(speaker.model) [\(speaker.symbol)]")
        print("    id \(speaker.id), \(speaker.host):\(speaker.port) (\(services))")
        print("    \(speaker.protocolVersion), \(speaker.authentication(hasSavedPairing: paired))")
        print(speaker.supportsPTP
              ? "    timing: PTP (feature bit 41), realtime stream, rendered \(AirPlayTimeline.ptpLatency) s after each frame's moment"
              : "    timing: NTP-style sync packets (no PTP support), latency \(AirPlayTimeline.defaultLatency) s")
        print("    \(pairingDetail(speaker)); \(paired ? "paired (saved in Keychain)" : "no saved pairing")"
              + "; transient \(speaker.supportsTransientPairing ? "supported" : "not supported")")
        var notes: [String] = []
        if !speaker.pyatvStreams {
            notes.append("no _raop._tcp and no HasUnifiedAdvertiserInfo: pyatv wouldn't stream here; Soundcheck tries AirPlay 2 on the AirPlay port")
        }
        if speaker.requiresPassword { notes.append("password-protected: not supported") }
        if !speaker.acceptsCDAudio { notes.append("audio format \(speaker.audioFormat) isn't 44.1 kHz/16-bit/stereo: not supported") }
        let et = speaker.encryptionTypes.sorted().map(String.init).joined(separator: ",")
        print("    features \(hex(speaker.features.rawValue)), status \(hex(speaker.statusFlags)), et \(et.isEmpty ? "-" : et)"
              + ", audio PCM 44.1 kHz/16-bit stereo")
        for note in notes { print("    note: \(note)") }
    }
}

@MainActor func tone(names: [String], seconds: Double, volume: Float) {
    AirPlayLog.handler = { line in
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        printError("[\(stamp)] \(line)")
    }
    let wanted = names.map { $0.lowercased() }
    let found = browse(for: 8) { speakers in
        wanted.allSatisfy { name in speakers.contains { $0.name.lowercased() == name } }
    }
    var targets: [AirPlaySpeaker] = []
    for name in wanted {
        guard let speaker = found.first(where: { $0.name.lowercased() == name }) else {
            print("No speaker named \"\(name)\". Found: \(found.map(\.name).joined(separator: ", "))")
            exit(1)
        }
        targets.append(speaker)
    }

    let timeline = AirPlayTimeline()
    let sessions = targets.map { AirPlaySession(speaker: $0, timeline: timeline) }
    let failed = Box(false)

    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    interrupt.setEventHandler {
        print("Stopping.")
        sessions.forEach { $0.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(130) }
    }
    interrupt.resume()

    let pending = Box(sessions.count)
    for session in sessions {
        let name = session.speaker.name
        session.setVolume(volume)
        session.requestPIN = { reply in
            print("\(name) is showing a code. Type it and press Return:", terminator: " ")
            fflush(stdout)
            DispatchQueue.global().async { reply(readLine()) }
        }
        session.onError = { error in
            print("\(name): \(error.localizedDescription)")
            failed.value = true
        }
        print("Connecting to \(name) (\(session.speaker.protocolVersion), \(session.speaker.authentication))…")
        session.start { error in
            pending.value -= 1
            if let error {
                print("\(name): couldn't start: \(error.localizedDescription)")
                failed.value = true
            } else {
                print("\(name): streaming, \(session.timingMethod == .ptp ? "PTP" : "NTP") timing, heard \(String(format: "%.3f", session.playbackDelay)) s after each frame's moment")
            }
        }
    }
    while pending.value > 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if failed.value {
        sessions.forEach { $0.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        exit(1)
    }

    // The tone: frames from now on, written up to 0.25 s ahead of the timeline.
    let rate = AirPlayTimeline.sampleRate
    let first = timeline.currentPosition
    let total = Int64(seconds * Double(rate))
    let end = first + total
    let written = Box(first)
    let fade = Double(rate) * 0.02
    let amplitude = 0.2 * 32_767.0
    let chunk = 1024
    let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: chunk * 2)
    let producer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "tone", qos: .userInitiated))
    producer.setEventHandler {
        let target = min(end, timeline.currentPosition + Int64(Double(rate) * 0.25))
        while written.value < target {
            let frames = Int(min(Int64(chunk), target - written.value))
            for i in 0..<frames {
                let n = written.value + Int64(i) - first
                let envelope = min(1, Double(n) / fade, Double(total - n) / fade)
                let sample = Int16(amplitude * max(0, envelope) * sin(2 * .pi * 440 * Double(n) / Double(rate)))
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            }
            for session in sessions { session.enqueue(buffer, frames: frames, position: UInt64(written.value)) }
            written.value += Int64(frames)
        }
    }
    producer.schedule(deadline: .now(), repeating: .milliseconds(10))
    producer.resume()
    print("Playing 440 Hz for \(seconds) s at volume \(volume) (starts in about \(String(format: "%.1f", timeline.latency)) s)…")

    // Wait until the last frame has played, then stop.
    let finish = timeline.playbackHostTime(ofPosition: end) + AirPlayClock.hostTicks(fromSeconds: 0.5)
    while mach_absolute_time() < finish && !failed.value {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    producer.cancel()
    sessions.forEach { $0.stop() }
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    print(failed.value ? "Stopped after an error." : "Done.")
    exit(failed.value ? 1 : 0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list":
    MainActor.assumeIsolated { list() }
case "tone":
    guard arguments.count >= 2 else { usage() }
    let names = arguments[1].split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let seconds = arguments.count >= 3 ? Double(arguments[2]) ?? 3 : 3
    let volume = arguments.count >= 4 ? Float(arguments[3]) ?? 0.15 : 0.15
    guard !names.isEmpty, seconds > 0, seconds <= 600, (0...1).contains(volume) else { usage() }
    MainActor.assumeIsolated { tone(names: names, seconds: seconds, volume: volume) }
default:
    usage()
}
