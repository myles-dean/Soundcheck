// AirPlay audio sender for Soundcheck.
//
// One realtime audio stream to one speaker: connect, pair if needed, set up the stream, then
// send 44.1 kHz/16-bit stereo PCM over RTP in real time. The protocol steps and their order are
// pyatv's (pyatv/protocols/raop/stream_client.py, protocols/airplayv1.py, protocols/airplayv2.py,
// protocols/raop/__init__.py): https://github.com/postlund/pyatv, MIT License, © Pierre Ståhl.
// Speakers that support PTP are timed the way a Mac times them instead: SETUP (session) with
// timingProtocol PTP, RECORD, SETPEERS, SETUP (stream), and type-215 sync packets on the
// receivers' grandmaster timeline. Those protocol details follow OwnTone's sender (airplay.c,
// rtp_common.c), shairport-sync's receiver and tuxplay's notes on what macOS does (MIT); no code
// from OwnTone or shairport-sync is included.

import CryptoKit
import Foundation
import Network
import Synchronization

/// Streams PCM to one AirPlay speaker.
final class AirPlaySession: @unchecked Sendable {
    let speaker: AirPlaySpeaker
    let timeline: AirPlayTimeline

    /// How long after a frame is current it's sent: lets the producer deliver late without the
    /// sender padding it with silence. Must stay well below the timeline's latency.
    static let sendDelay: TimeInterval = 0.1
    /// The name speakers show for the sender.
    static let senderName = "Soundcheck"

    /// How sessions time their speakers.
    enum TimingPreference: Sendable {
        /// PTP for speakers that support it (feature bit 41), NTP-style sync packets otherwise.
        case automatic
        /// Always the NTP-style path (pyatv's).
        case ntp
    }

    /// Set before starting sessions; AIRPLAY_TIMING=ntp in the environment does the same.
    nonisolated(unsafe) static var timingPreference: TimingPreference =
        ProcessInfo.processInfo.environment["AIRPLAY_TIMING"]?.lowercased() == "ntp" ? .ntp : .automatic

    /// The timing peer ID sent in SETUP; one per process, as OwnTone and tuxplay do.
    private static let timingPeerID = UUID().uuidString.uppercased()

    enum Timing: Sendable {
        /// NTP-style: our timing server and type-212 sync packets on our own clock.
        case ntp
        /// PTP: type-215 sync packets on the receivers' grandmaster timeline.
        case ptp
    }

    private enum State { case idle, starting, streaming, stopped }

    private let lock = NSLock()
    private var state = State.idle
    private var errorHandler: (@Sendable (Error) -> Void)?
    private var pinHandler: (@Sendable (_ reply: @escaping @Sendable (String?) -> Void) -> Void)?
    private var pinCancel: (@Sendable () -> Void)?

    private let queue: DispatchQueue
    private let audioQueue: DispatchQueue
    private let ring = AirPlayRingBuffer()
    private let backlog = AirPlayPacketBacklog()
    private let running = Atomic<Bool>(false)
    /// The next position the sender thread will send (read by the sync timer).
    private let head = Atomic<UInt64>(0)

    // Set up during start, then only read.
    private var rtsp: AirPlayRTSPConnection?
    private var events: AirPlayEventChannel?
    private var timing: AirPlayTimingServer?
    private var control: AirPlayControlChannel?
    private var audio: NWConnection?
    private var audioKey: SymmetricKey?
    private var rtspSession = "0"
    private var syncTimer: DispatchSourceTimer?
    private var keepAlive: Task<Void, Never>?
    private let ssrc: UInt32
    private let firstSequence = UInt16.random(in: .min ... .max)
    private var firstPosition: UInt64 = 0

    // Volume: the latest request, what the speaker has, and whether a change is on its way.
    private var volume: Float?
    private var sentVolume: Float?
    private var volumeInFlight = false
    private var canSetVolume = false
    /// When a volume was last sent: for a moment after, the speaker can still report the levels
    /// it passed through on its way there.
    private var lastVolumeSent = Date.distantPast
    private var speakerVolumeHandler: (@Sendable (Float) -> Void)?

    // PTP
    private var timingMode = Timing.ntp
    private var ptpPeer: UInt32?
    private var inPTPGroup = false
    private var receiverAddress = ""
    private var localAddress = ""

    init(speaker: AirPlaySpeaker, timeline: AirPlayTimeline) {
        self.speaker = speaker
        self.timeline = timeline
        queue = DispatchQueue(label: "AirPlay session \(speaker.name)", qos: .userInitiated)
        audioQueue = DispatchQueue(label: "AirPlay audio \(speaker.name)", qos: .userInteractive)
        ssrc = UInt32.random(in: .min ... .max)
    }

    deinit {
        running.store(false, ordering: .relaxed)
    }

    /// The speaker's own volume changed (0...1), from its buttons, Siri, an iPhone or the Home
    /// app. Called on the session's queue.
    var onSpeakerVolume: (@Sendable (Float) -> Void)? {
        get { lock.withLock { speakerVolumeHandler } }
        set { lock.withLock { speakerVolumeHandler = newValue } }
    }

    /// A volume the speaker reported: unless it's Soundcheck's own change coming back, it's the
    /// speaker's level now (so it isn't sent back to it).
    private func speakerReportedVolume(_ reported: Float) {
        let handler = lock.withLock { () -> (@Sendable (Float) -> Void)? in
            guard Date().timeIntervalSince(lastVolumeSent) > 1, abs((sentVolume ?? -1) - reported) > 0.005 else { return nil }
            volume = reported
            sentVolume = reported
            return speakerVolumeHandler
        }
        if let handler {
            AirPlayLog.logger.notice("\(self.speaker.name, privacy: .public) changed its volume to \(reported, privacy: .public)")
            handler(reported)
        }
    }

    /// Called on the main queue if the stream fails after `start` succeeded (the speaker went
    /// away, another device took it over, the network dropped). The session is stopped by then;
    /// make a new one to reconnect.
    var onError: (@Sendable (Error) -> Void)? {
        get { lock.withLock { errorHandler } }
        set { lock.withLock { errorHandler = newValue } }
    }

    /// Called on the main queue when the speaker shows a one-time code (Apple TVs and TVs set to
    /// ask for one): call `reply` with the code the user typed, or nil to cancel. The pairing is
    /// saved in the Keychain, so this happens once per speaker. Without a handler, those speakers
    /// fail with `AirPlayError.pairingRequired` unless transient pairing happens to work.
    var requestPIN: (@Sendable (_ reply: @escaping @Sendable (String?) -> Void) -> Void)? {
        get { lock.withLock { pinHandler } }
        set { lock.withLock { pinHandler = newValue } }
    }

    /// How the session keeps time with its speaker (decided during start).
    var timingMethod: Timing { lock.withLock { timingMode } }

    /// Set to false before `start` to time this speaker the NTP way even if it offers PTP (a
    /// fallback for speakers that won't stream with PTP).
    var allowsPTP: Bool {
        get { lock.withLock { ptpAllowed } }
        set { lock.withLock { ptpAllowed = newValue } }
    }
    private var ptpAllowed = true

    /// The delay the receiver adds (seconds), known after start: a frame enqueued at position P
    /// plays at the timeline's start + P / 44100 + latency. For PTP sessions this is
    /// `AirPlayTimeline.ptpLatency`, the same for all of them.
    var latency: TimeInterval { timingMethod == .ptp ? AirPlayTimeline.ptpLatency : timeline.latency }

    /// How long after a frame's moment on the timeline (`timeline.hostTime(atPosition:)`) the
    /// speaker renders it.
    ///
    /// PTP: exactly `AirPlayTimeline.ptpLatency`. Each sync packet maps RTP times to the
    /// grandmaster's clock so that position P renders at the network time of
    /// `timeline.hostTime(atPosition: P)` plus that latency, so every PTP speaker on the timeline
    /// renders P together (this assumes the receiver renders a sync packet's first RTP time
    /// `AirPlayPacket.ptpRenderOffsetFrames` after its time, as OwnTone and shairport-sync do).
    ///
    /// NTP: speakers that keep time play it after the timeline's latency; ones that play sound as
    /// it arrives (HomePods report this as arrivalToRenderLatencyMs in the stream SETUP reply)
    /// play it after the send delay, one packet, the network and their own delay.
    var playbackDelay: TimeInterval {
        let (mode, arrival) = lock.withLock { (timingMode, arrivalToRender) }
        if mode == .ptp { return AirPlayTimeline.ptpLatency }
        guard let arrival else { return latency }
        let packet = Double(AirPlayPacket.framesPerPacket) / Double(AirPlayTimeline.sampleRate)
        return Self.sendDelay + packet + 0.005 + arrival
    }
    private var arrivalToRender: TimeInterval?

    /// The host time (mach_absolute_time) at which the speaker renders `position`.
    func renderHostTime(ofPosition position: Int64) -> UInt64 {
        timeline.hostTime(atPosition: position) &+ AirPlayClock.hostTicks(fromSeconds: playbackDelay)
    }

    var isStreaming: Bool { lock.withLock { state == .streaming } }

    // MARK: Start

    /// Connects, pairs if needed, sets up the stream. `done` is called on the main queue.
    func start(_ done: @escaping @Sendable (Error?) -> Void) {
        let ok = lock.withLock { () -> Bool in
            guard state == .idle else { return false }
            state = .starting
            return true
        }
        guard ok else {
            DispatchQueue.main.async { done(AirPlayError.protocolError("the session was already started")) }
            return
        }
        Task.detached(priority: .userInitiated) { [self] in
            do {
                try await run()
                let streaming = lock.withLock { () -> Bool in
                    guard state == .starting else { return false }
                    state = .streaming
                    return true
                }
                guard streaming else { throw AirPlayError.cancelled }
                startSending()
                AirPlayLog.debug("Streaming to \(speaker.name)")
                DispatchQueue.main.async { done(nil) }
            } catch {
                let stopped = lock.withLock { () -> Bool in
                    let wasStopped = state == .stopped
                    state = .stopped
                    return wasStopped
                }
                releaseResources(teardown: false)
                let reported: Error = stopped ? AirPlayError.cancelled : error
                AirPlayLog.error("Couldn't start AirPlay to \(speaker.name): \(reported.localizedDescription)")
                DispatchQueue.main.async { done(reported) }
            }
        }
    }

    private var isStopped: Bool { lock.withLock { state == .stopped } }

    private func checkNotStopped() throws {
        if isStopped { throw AirPlayError.cancelled }
    }

    private func run() async throws {
        guard speaker.acceptsCDAudio else {
            let format = speaker.audioFormat
            throw AirPlayError.unsupported("it wants \(format.sampleRate) Hz, \(format.channels) channels, \(format.bytesPerSample * 8)-bit")
        }
        if speaker.requiresPassword { throw AirPlayError.unsupported("it's protected with a password") }
        AirPlayLog.debug("Starting \(speaker.protocolVersion) session to \(speaker.name) (\(speaker.model)) at \(speaker.host):\(speaker.port)")

        var credentials = AirPlayCredentialStore.load(deviceID: speaker.id)
        var pairedNow = false
        let ask = requestPIN
        if speaker.protocolVersion == .airPlay2, credentials == nil, let ask,
           speaker.pairingRequirement == .mandatory || !speaker.supportsTransientPairing {
            credentials = try await pairWithPIN(ask)
            pairedNow = true
        }
        do {
            try await connectAndSetUp(credentials: credentials)
        } catch AirPlayError.authenticationFailed(let detail) where speaker.protocolVersion == .airPlay2 {
            try checkNotStopped()
            releaseResources(teardown: false)
            if credentials != nil {
                AirPlayLog.debug("The saved pairing for \(speaker.name) didn't work (\(detail)); forgetting it")
                AirPlayCredentialStore.remove(deviceID: speaker.id)
            }
            guard let ask, !pairedNow else {
                throw AirPlayError.pairingRequired("\(detail). Pair with the code the speaker shows.")
            }
            AirPlayLog.debug("\(speaker.name) refused \(credentials == nil ? "transient pairing" : "the saved pairing"); pairing with a code")
            credentials = try await pairWithPIN(ask)
            try await connectAndSetUp(credentials: credentials)
        }
    }

    /// Pairs on a connection of its own (as pyatv's pairing handler does), then closes it.
    private func pairWithPIN(_ ask: @escaping @Sendable (_ reply: @escaping @Sendable (String?) -> Void) -> Void) async throws -> AirPlayCredentials {
        AirPlayLog.debug("Pairing with \(speaker.name): asking it to show a code")
        let connection = try await AirPlayRTSPConnection.connect(host: speaker.host, port: speaker.port)
        defer { connection.close() }
        lock.withLock { pinCancel = { connection.close() } }
        defer { lock.withLock { pinCancel = nil } }
        try checkNotStopped()
        let pairing = AirPlayPINPairing(rtsp: connection)
        try await pairing.start()
        guard let pin = await askForPIN(ask) else { throw isStopped ? AirPlayError.cancelled : AirPlayError.pairingCancelled }
        let digits = pin.filter(\.isNumber)
        let code = digits.count < 4 ? String(repeating: "0", count: 4 - digits.count) + digits : digits
        let credentials = try await pairing.finish(pin: code, name: Self.senderName)
        AirPlayCredentialStore.save(credentials, deviceID: speaker.id, speakerName: speaker.name)
        return credentials
    }

    private func askForPIN(_ ask: @escaping @Sendable (_ reply: @escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        let once = AirPlayOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let cancel: @Sendable () -> Void = { if once.claim() { continuation.resume(returning: nil) } }
            lock.withLock {
                let previous = pinCancel
                pinCancel = { previous?(); cancel() }
            }
            if isStopped { cancel(); return }
            DispatchQueue.main.async {
                ask { pin in if once.claim() { continuation.resume(returning: pin) } }
            }
        }
    }

    /// Keeps a resource only while the session is still starting; otherwise closes it.
    private func keep(_ assign: (AirPlaySession) -> Void, orClose close: () -> Void) throws {
        let kept = lock.withLock { () -> Bool in
            guard state == .starting else { return false }
            assign(self)
            return true
        }
        if !kept {
            close()
            throw AirPlayError.cancelled
        }
    }

    /// PTP when the speaker supports it and the process's PTP clock is running.
    private func choosePTP() -> Bool {
        guard Self.timingPreference == .automatic, allowsPTP, speaker.supportsPTP else { return false }
        do {
            try AirPlayPTPClock.shared.start()
            return true
        } catch {
            AirPlayLog.error("PTP unavailable (\(error.localizedDescription)); timing \(speaker.name) the NTP way")
            return false
        }
    }

    private func connectAndSetUp(credentials: AirPlayCredentials?) async throws {
        let usePTP = choosePTP()
        lock.withLock { timingMode = usePTP ? .ptp : .ntp }
        let rtsp = try await AirPlayRTSPConnection.connect(host: speaker.host, port: speaker.port)
        try keep({ $0.rtsp = rtsp }, orClose: { rtsp.close() })
        rtsp.onClose = { [weak self] error in self?.connectionLost(error) }

        // Local UDP endpoints first: their ports go into SETUP.
        let control = try await AirPlayControlChannel.start(queue: queue)
        try keep({ $0.control = control }, orClose: { control.close() })
        control.retransmissions = { [weak self] first, count in self?.backlog.retransmissions(from: first, count: count) ?? [] }
        if usePTP {
            try await connectAndSetUpPTP(rtsp, control: control, credentials: credentials)
            return
        }
        let timing = try await AirPlayTimingServer.start(queue: queue)
        try keep({ $0.timing = timing }, orClose: { timing.close() })
        AirPlayLog.debug("Local ports: control=\(control.port), timing=\(timing.port)")

        // GET /info (pyatv logs it; failures don't matter).
        if let info = try? await rtsp.exchange("GET", uri: "/info", allowError: true), info.code == 200,
           let plist = info.plist {
            let volume = plist["initialVolume"].map { "\($0)" } ?? "?"
            AirPlayLog.debug("/info: \(plist["name"] ?? speaker.name), model \(plist["model"] ?? "?"), initialVolume \(volume)")
        }
        try checkNotStopped()

        if speaker.requiresAuthSetup {
            // Ask to stream unencrypted, with a fixed Curve25519 key (from owntone, via pyatv).
            let key: [UInt8] = [0x59, 0x02, 0xED, 0xE9, 0x0D, 0x4E, 0xF2, 0xBD, 0x4C, 0xB6, 0x8A, 0x63, 0x30, 0x03,
                                0x82, 0x07, 0xA9, 0x4D, 0xBD, 0x50, 0xD8, 0xAA, 0x46, 0x5B, 0x5D, 0x8C, 0x01, 0x2A,
                                0x0C, 0x7E, 0x1D, 0x4E]
            _ = try await rtsp.exchange("POST", uri: "/auth-setup", contentType: "application/octet-stream",
                                        body: Data([0x01] + key), protocolName: "HTTP/1.1")
        }

        let ports: (control: UInt16, data: UInt16)
        switch speaker.protocolVersion {
        case .airPlay2:
            ports = try await setUpAirPlay2(rtsp, credentials: credentials, timingPort: timing.port, controlPort: control.port)
        case .airPlay1:
            ports = try await setUpAirPlay1(rtsp, timingPort: timing.port, controlPort: control.port)
        }
        AirPlayLog.debug("Remote ports: control=\(ports.control), data=\(ports.data)")

        // UDP to the speaker: sync packets from our control port, audio from anywhere.
        await control.connect(to: rtsp.remoteHost, port: ports.control)
        let audio = try await openAudio(host: rtsp.remoteHost, port: ports.data)
        try keep({ $0.audio = audio }, orClose: { audio.cancel() })

        // Where the stream starts: the frame whose send time is now.
        let now = mach_absolute_time()
        let delay = AirPlayClock.hostTicks(fromSeconds: Self.sendDelay)
        let natural = timeline.position(atHostTime: now - min(now, delay)) - Int64(AirPlayPacket.framesPerPacket)
        let first = UInt64(max(0, natural))
        lock.withLock { firstPosition = first }
        head.store(first, ordering: .relaxed)
        startSync()
        try await startFeedback(rtsp)

        // pyatv sets the volume before RECORD and, if that fails, after FLUSH.
        lock.withLock { canSetVolume = true }
        let volumeSet = await sendVolume(rtsp)

        let record = try await rtsp.exchange("RECORD")
        if let latency = record.header("Audio-Latency") { AirPlayLog.debug("Speaker reports Audio-Latency \(latency)") }
        _ = try await rtsp.exchange("FLUSH", headers: [
            ("Range", "npt=0-"),
            ("Session", rtspSession),
            ("RTP-Info", "seq=\(firstSequence);rtptime=\(timeline.rtpTime(atPosition: Int64(first)))"),
        ])
        if !volumeSet { _ = await sendVolume(rtsp) }
        try checkNotStopped()
    }

    // MARK: AirPlay 2 (pyatv's AirPlayV2)

    /// Pair-verify with saved keys, or transient pairing.
    private func verify(_ rtsp: AirPlayRTSPConnection, credentials: AirPlayCredentials?) async throws -> AirPlayPairVerifier {
        if let credentials { return try await AirPlayPairing.verify(rtsp, credentials: credentials) }
        if speaker.supportsTransientPairing { return try await AirPlayPairing.transient(rtsp) }
        throw AirPlayError.pairingRequired("this AirPlay 2 speaker doesn't support transient pairing")
    }

    private func setUpAirPlay2(_ rtsp: AirPlayRTSPConnection, credentials: AirPlayCredentials?,
                               timingPort: UInt16, controlPort: UInt16) async throws -> (control: UInt16, data: UInt16) {
        let verifier = try await verify(rtsp, credentials: credentials)
        let control = verifier.encryptionKeys(salt: "Control-Salt", outputInfo: "Control-Write-Encryption-Key",
                                              inputInfo: "Control-Read-Encryption-Key")
        rtsp.enableEncryption(outputKey: control.output, inputKey: control.input)

        let base = try await rtsp.exchange("SETUP", plist: [
            "deviceID": "AA:BB:CC:DD:EE:FF",
            "sessionUUID": UUID().uuidString.uppercased(),
            "timingPort": Int(timingPort),
            "timingProtocol": "NTP",
            "isMultiSelectAirPlay": true,
            "groupContainsGroupLeader": false,
            "macAddress": "AA:BB:CC:DD:EE:FF",
            "model": "iPhone14,3",
            "name": Self.senderName,
            "osBuildVersion": "20F66",
            "osName": "iPhone OS",
            "osVersion": "16.5",
            "senderSupportsRelay": false,
            "sourceVersion": "690.7.1",
            "statsCollectionEnabled": false,
        ])
        let basePlist = base.plist ?? [:]
        let eventPort = (basePlist["eventPort"] as? NSNumber)?.uint16Value ?? 0
        AirPlayLog.debug("SETUP: eventPort=\(eventPort), timingPort=\(basePlist["timingPort"] ?? "-")")

        if eventPort != 0 {
            // The speaker writes events with its write key, which is our read key.
            let keys = verifier.encryptionKeys(salt: "Events-Salt", outputInfo: "Events-Read-Encryption-Key",
                                               inputInfo: "Events-Write-Encryption-Key")
            let events = try await AirPlayEventChannel.connect(host: rtsp.remoteHost, port: eventPort,
                                                               outputKey: keys.output, inputKey: keys.input, queue: queue)
            events.onVolume = { [weak self] volume in self?.speakerReportedVolume(volume) }
            try keep({ $0.events = events }, orClose: { events.close() })
        } else {
            AirPlayLog.debug("No event port in the SETUP reply; going on without the event channel")
        }

        // pyatv derives the audio key from the event keys too; any key works, it's sent along.
        let shk = verifier.encryptionKeys(salt: "Events-Salt", outputInfo: "Events-Write-Encryption-Key",
                                          inputInfo: "Events-Read-Encryption-Key").output.prefix(32)
        let stream = try await rtsp.exchange("SETUP", plist: [
            "streams": [[
                "audioFormat": 0x800,          // PCM, 44100 Hz, 16-bit, stereo
                "audioMode": "default",
                "controlPort": Int(controlPort),
                "ct": 1,                       // compression type: raw PCM
                "isMedia": true,
                "latencyMax": 88_200,
                "latencyMin": 11_025,
                "shk": Data(shk),
                "spf": AirPlayPacket.framesPerPacket,
                "sr": 44_100,
                "type": 0x60,                  // realtime audio
                "supportsDynamicStreamID": false,
                "streamConnectionID": Int(rtsp.sessionID),
            ] as [String: Any]],
        ])
        AirPlayLog.logger.notice("Stream SETUP reply from \(self.speaker.name, privacy: .public): \(String(describing: stream.plist ?? [:]), privacy: .public)")
        guard let streams = stream.plist?["streams"] as? [[String: Any]], let first = streams.first,
              let remoteControl = (first["controlPort"] as? NSNumber)?.uint16Value,
              let data = (first["dataPort"] as? NSNumber)?.uint16Value else {
            throw AirPlayError.protocolError("the stream SETUP reply had no ports")
        }
        let arrival = (first["arrivalToRenderLatencyMs"] as? NSNumber).map { $0.doubleValue / 1000 }
        lock.withLock {
            audioKey = SymmetricKey(data: Data(shk))
            arrivalToRender = arrival
        }
        return (remoteControl, data)
    }

    // MARK: AirPlay 2 with PTP (what a Mac does)

    private func connectAndSetUpPTP(_ rtsp: AirPlayRTSPConnection, control: AirPlayControlChannel,
                                    credentials: AirPlayCredentials?) async throws {
        AirPlayLog.debug("Local control port \(control.port); timing with PTP")
        if let info = try? await rtsp.exchange("GET", uri: "/info", allowError: true) {
            if info.code == 200, let plist = info.plist {
                let volume = plist["initialVolume"].map { "\($0)" } ?? "?"
                AirPlayLog.debug("/info: \(plist["name"] ?? speaker.name), model \(plist["model"] ?? "?"), initialVolume \(volume)")
            } else {
                AirPlayLog.debug("GET /info answered \(info.code)")
            }
        }
        try checkNotStopped()

        let ports = try await setUpAirPlay2PTP(rtsp, credentials: credentials, controlPort: control.port)
        AirPlayLog.debug("Remote ports: control=\(ports.control), data=\(ports.data)")
        await control.connect(to: rtsp.remoteHost, port: ports.control)
        let audio = try await openAudio(host: rtsp.remoteHost, port: ports.data)
        try keep({ $0.audio = audio }, orClose: { audio.cancel() })

        // Hold the stream until the clock has locked to the receivers' grandmaster (about 0.4 s
        // from the first announce, tuxplay measured), so the first sync packet is on its timeline.
        let started = Date()
        let clock = await AirPlayPTPClock.shared.settledTimeline()
        try checkNotStopped()
        let waited = Int(Date().timeIntervalSince(started) * 1000)
        switch clock.state {
        case .following:
            AirPlayLog.debug(String(format: "PTP: timing %@ on grandmaster %016llX (waited %d ms)", speaker.name, clock.clockID, waited))
        default:
            AirPlayLog.debug(String(format: "PTP: no receiver clock to follow for %@; this Mac (%016llX) is the grandmaster (waited %d ms)",
                                    speaker.name, clock.clockID, waited))
        }

        let now = mach_absolute_time()
        let delay = AirPlayClock.hostTicks(fromSeconds: Self.sendDelay)
        let natural = timeline.position(atHostTime: now - min(now, delay)) - Int64(AirPlayPacket.framesPerPacket)
        let first = UInt64(max(0, natural))
        lock.withLock { firstPosition = first }
        head.store(first, ordering: .relaxed)
        startSync()
        try await startFeedback(rtsp)
        lock.withLock { canSetVolume = true }
        _ = await sendVolume(rtsp)
        try checkNotStopped()
    }

    /// The receiver's PTP address from the SETUP reply: the one we talk to it on if it's listed,
    /// else its first of the same family (tuxplay's timing_address_pick).
    private static func timingAddress(_ reply: [String: Any], rtspAddress: String) -> String? {
        guard let info = reply["timingPeerInfo"] as? [String: Any],
              let addresses = info["Addresses"] as? [String], !addresses.isEmpty else { return nil }
        if addresses.contains(rtspAddress) { return rtspAddress }
        let v6 = rtspAddress.contains(":")
        return addresses.first { $0.contains(":") == v6 }
    }

    private func setUpAirPlay2PTP(_ rtsp: AirPlayRTSPConnection, credentials: AirPlayCredentials?,
                                  controlPort: UInt16) async throws -> (control: UInt16, data: UInt16) {
        let verifier = try await verify(rtsp, credentials: credentials)
        let keys = verifier.encryptionKeys(salt: "Control-Salt", outputInfo: "Control-Write-Encryption-Key",
                                           inputInfo: "Control-Read-Encryption-Key")
        rtsp.enableEncryption(outputKey: keys.output, inputKey: keys.input)

        let clock = AirPlayPTPClock.shared
        let local = rtsp.localIP
        let peerInfo: [String: Any] = [
            "ID": Self.timingPeerID,
            "DeviceType": 0,
            "ClockID": Int64(bitPattern: clock.clockID),
            "SupportsClockPortMatchingOverride": true,
            "Addresses": [local],
        ]
        let session = try await rtsp.exchange("SETUP", plist: [
            "deviceID": "AA:BB:CC:DD:EE:FF",
            "sessionUUID": UUID().uuidString.uppercased(),
            "timingProtocol": "PTP",
            "timingPeerInfo": peerInfo,
            "timingPeerList": [peerInfo],
            "groupUUID": timeline.groupUUID,
            "groupContainsGroupLeader": false,
            "isMultiSelectAirPlay": true,
            "macAddress": "AA:BB:CC:DD:EE:FF",
            "model": "iPhone14,3",
            "name": Self.senderName,
            "osBuildVersion": "20F66",
            "osName": "iPhone OS",
            "osVersion": "16.5",
            "senderSupportsRelay": false,
            "sourceVersion": "690.7.1",
            "statsCollectionEnabled": false,
        ])
        let reply = session.plist ?? [:]
        let eventPort = (reply["eventPort"] as? NSNumber)?.uint16Value ?? 0
        let timingAddress = Self.timingAddress(reply, rtspAddress: rtsp.remoteIP) ?? rtsp.remoteIP
        AirPlayLog.debug("SETUP (session): eventPort=\(eventPort), PTP peer \(timingAddress)")
        let peer = clock.addPeer(timingAddress)
        let kept = lock.withLock { () -> Bool in
            guard state == .starting else { return false }
            ptpPeer = peer
            receiverAddress = rtsp.remoteIP
            localAddress = local
            return true
        }
        if !kept {
            if let peer { clock.removePeer(peer) }
            throw AirPlayError.cancelled
        }

        if eventPort != 0 {
            let eventKeys = verifier.encryptionKeys(salt: "Events-Salt", outputInfo: "Events-Read-Encryption-Key",
                                                    inputInfo: "Events-Write-Encryption-Key")
            let events = try await AirPlayEventChannel.connect(host: rtsp.remoteHost, port: eventPort,
                                                               outputKey: eventKeys.output, inputKey: eventKeys.input, queue: queue)
            events.onVolume = { [weak self] volume in self?.speakerReportedVolume(volume) }
            try keep({ $0.events = events }, orClose: { events.close() })
        }

        let record = try await rtsp.exchange("RECORD")
        if let latency = record.header("Audio-Latency") { AirPlayLog.debug("Speaker reports Audio-Latency \(latency)") }

        // Every receiver on this timeline is told about every other, so they elect one
        // grandmaster and all render on its timeline.
        timeline.joinPTPGroup(ObjectIdentifier(self), address: rtsp.remoteIP) { [weak self] in self?.groupChanged() }
        lock.withLock { inPTPGroup = true }
        try await sendPeers(rtsp)

        let shk = verifier.encryptionKeys(salt: "Events-Salt", outputInfo: "Events-Write-Encryption-Key",
                                          inputInfo: "Events-Read-Encryption-Key").output.prefix(32)
        let stream = try await rtsp.exchange("SETUP", plist: [
            "streams": [[
                "audioFormat": 0x800,          // PCM, 44100 Hz, 16-bit, stereo
                "audioMode": "default",
                "controlPort": Int(controlPort),
                "ct": 1,                       // compression type: raw PCM
                "isMedia": true,
                "latencyMax": 88_200,
                "latencyMin": Int(AirPlayPacket.ptpRenderOffsetFrames),
                "shk": Data(shk),
                "spf": AirPlayPacket.framesPerPacket,
                "sr": 44_100,
                "type": 0x60,                  // realtime audio
                "supportsDynamicStreamID": false,
                "streamConnectionID": Int(rtsp.sessionID),
            ] as [String: Any]],
        ])
        AirPlayLog.debug("SETUP (stream) reply: \(String(describing: stream.plist ?? [:]))")
        guard let streams = stream.plist?["streams"] as? [[String: Any]], let first = streams.first,
              let remoteControl = (first["controlPort"] as? NSNumber)?.uint16Value,
              let data = (first["dataPort"] as? NSNumber)?.uint16Value else {
            throw AirPlayError.protocolError("the stream SETUP reply had no ports")
        }
        let arrival = (first["arrivalToRenderLatencyMs"] as? NSNumber).map { $0.doubleValue / 1000 }
        lock.withLock {
            audioKey = SymmetricKey(data: Data(shk))
            arrivalToRender = arrival
        }
        return (remoteControl, data)
    }

    /// SETPEERS, as a Mac lists it: the receiver itself, us, then every other receiver on the
    /// timeline (tuxplay's setpeers_send). The content type really is "/peer-list-changed".
    private func sendPeers(_ rtsp: AirPlayRTSPConnection) async throws {
        let (receiver, local) = lock.withLock { (receiverAddress, localAddress) }
        let others = timeline.ptpGroupAddresses.filter { $0 != receiver }
        let list = [receiver, local] + others
        let body = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        _ = try await rtsp.exchange("SETPEERS", contentType: "/peer-list-changed", body: body)
        AirPlayLog.debug("SETPEERS \(speaker.name): \(list.joined(separator: ", "))")
    }

    /// Another receiver joined or left the timeline's group: tell this one.
    private func groupChanged() {
        guard let rtsp = lock.withLock({ (state == .starting || state == .streaming) && inPTPGroup ? self.rtsp : nil }) else { return }
        Task.detached(priority: .utility) { [weak self] in
            do { try await self?.sendPeers(rtsp) } catch {
                AirPlayLog.debug("SETPEERS update failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: AirPlay 1 (pyatv's AirPlayV1)

    private func setUpAirPlay1(_ rtsp: AirPlayRTSPConnection, timingPort: UInt16,
                               controlPort: UInt16) async throws -> (control: UInt16, data: UInt16) {
        // No legacy pairing support: pyatv's null pair-verify does nothing.
        let sdp = """
            v=0\r
            o=iTunes \(rtsp.sessionID) 0 IN IP4 \(rtsp.localIP)\r
            s=iTunes\r
            c=IN IP4 \(rtsp.remoteIP)\r
            t=0 0\r
            m=audio 0 RTP/AVP 96\r
            a=rtpmap:96 L16/44100/2\r
            a=fmtp:96 \(AirPlayPacket.framesPerPacket) 0 16 40 10 14 2 255 0 0 44100\r

            """
        _ = try await rtsp.exchange("ANNOUNCE", contentType: "application/sdp", body: Data(sdp.utf8))
        let setup = try await rtsp.exchange("SETUP", headers: [
            ("Transport", "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(controlPort);timing_port=\(timingPort)"),
        ])
        var options: [String: String] = [:]
        for option in (setup.header("Transport") ?? "").split(separator: ";") {
            let pair = option.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { options[String(pair[0])] = String(pair[1]) }
        }
        guard let remoteControl = options["control_port"].flatMap({ UInt16($0) }),
              let server = options["server_port"].flatMap({ UInt16($0) }) else {
            throw AirPlayError.protocolError("the SETUP reply had no ports")
        }
        let session = setup.header("Session")?.split(separator: ";").first.map(String.init) ?? "0"
        lock.withLock { rtspSession = session }
        return (remoteControl, server)
    }

    // MARK: Streaming

    private func openAudio(host: NWEndpoint.Host, port: UInt16) async throws -> NWConnection {
        guard let remote = NWEndpoint.Port(rawValue: port) else { throw AirPlayError.protocolError("bad data port") }
        let connection = NWConnection(host: host, port: remote, using: .udp)
        let once = AirPlayOnce()
        let ready: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled: if once.claim() { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: audioQueue)
            audioQueue.asyncAfter(deadline: .now() + 5) { if once.claim() { continuation.resume(returning: false) } }
        }
        guard ready else {
            connection.cancel()
            throw AirPlayError.connectionFailed("couldn't open the audio connection")
        }
        return connection
    }

    /// Sync packets once a second (pyatv's ControlClient._sync_task).
    private func startSync() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let first = AirPlayOnce()
        timer.setEventHandler { [weak self] in self?.sendSync(first: first) }
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(5))
        let kept = lock.withLock { () -> Bool in
            guard state == .starting || state == .streaming else { return false }
            syncTimer = timer
            return true
        }
        if kept { timer.resume() }
    }

    /// NTP: RTP time of the next packet minus the latency plays at that packet's NTP time.
    /// PTP: the next packet's frame renders at its moment's network time plus `ptpLatency`.
    private func sendSync(first: AirPlayOnce) {
        let (control, mode) = lock.withLock { (self.control, timingMode) }
        guard let control else { return }
        let position = Int64(head.load(ordering: .relaxed))
        let rtpNow = timeline.rtpTime(atPosition: position)
        switch mode {
        case .ntp:
            control.send(AirPlayPacket.sync(first: first.claim(), rtpNowMinusLatency: rtpNow &- timeline.latencyFrames,
                                            ntp: timeline.ntpTime(atPosition: position), rtpNow: rtpNow))
        case .ptp:
            // Not while waiting for, or relocking to, the grandmaster: the receivers keep the
            // last mapping meanwhile.
            let clock = AirPlayPTPClock.shared.timeline()
            guard clock.isUsable else { return }
            let local = AirPlayPTPClock.localNs(hostTime: timeline.hostTime(atPosition: position))
            let network = UInt64(max(0, clock.networkTime(localNs: local)))
            let lead = Self.ptpLatencyFrames - AirPlayPacket.ptpRenderOffsetFrames
            control.send(AirPlayPacket.ptpSync(first: first.claim(), rtpRendered: rtpNow &- lead, networkNs: network,
                                               rtpNow: rtpNow, clockID: clock.clockID))
        }
    }

    private static let ptpLatencyFrames = UInt32((AirPlayTimeline.ptpLatency * Double(AirPlayTimeline.sampleRate)).rounded())

    /// AirPlay 2: POST /feedback every 2 s, best effort. AirPlay 1: every 25 s if the first works.
    private func startFeedback(_ rtsp: AirPlayRTSPConnection) async throws {
        let interval: UInt64
        switch speaker.protocolVersion {
        case .airPlay2:
            interval = 2_000_000_000
        case .airPlay1:
            let first = try await rtsp.exchange("POST", uri: "/feedback", allowError: true)
            guard first.code == 200 else {
                AirPlayLog.debug("Keep-alive not supported")
                return
            }
            interval = 25_000_000_000
        }
        let immediate = speaker.protocolVersion == .airPlay2
        let task = Task.detached(priority: .utility) { [weak rtsp] in
            var send = immediate
            while !Task.isCancelled {
                if send {
                    guard let rtsp else { return }
                    _ = try? await rtsp.exchange("POST", uri: "/feedback", allowError: true)
                }
                send = true
                try? await Task.sleep(nanoseconds: interval)
            }
        }
        let kept = lock.withLock { () -> Bool in
            guard state == .starting || state == .streaming else { return false }
            keepAlive = task
            return true
        }
        if !kept { task.cancel() }
    }

    private func startSending() {
        let config = lock.withLock { () -> SendConfig? in
            guard let audio else { return nil }
            let ptp = timingMode == .ptp
            // OwnTone sends SSRC 0 on PTP sessions.
            return SendConfig(audio: audio, key: audioKey, firstPosition: firstPosition, ssrc: ptp ? 0 : ssrc,
                              latency: ptp ? AirPlayTimeline.ptpLatency : timeline.latency,
                              minimumLead: ptp ? 0.1 : 0.25)
        }
        guard let config else { return }
        running.store(true, ordering: .relaxed)
        let thread = Thread { [self] in sendLoop(config) }
        thread.name = "AirPlay audio (\(speaker.name))"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private struct SendConfig: @unchecked Sendable {
        let audio: NWConnection
        let key: SymmetricKey?
        let firstPosition: UInt64
        let ssrc: UInt32
        /// From a frame's moment to its playing, and how long before that a packet must be sent.
        let latency: TimeInterval
        let minimumLead: TimeInterval
    }

    /// Sends one packet per 352 frames, each `sendDelay` after its last frame is current.
    /// Falls back to silence for frames the producer hasn't delivered.
    private func sendLoop(_ config: SendConfig) {
        let frames = AirPlayPacket.framesPerPacket
        let delay = AirPlayClock.hostTicks(fromSeconds: Self.sendDelay)
        let minimumLead = AirPlayClock.hostTicks(fromSeconds: config.minimumLead)
        let latency = AirPlayClock.hostTicks(fromSeconds: config.latency)
        let pause = AirPlayClock.hostTicks(fromSeconds: 0.001)
        let longestWait = AirPlayClock.hostTicks(fromSeconds: 0.05)
        let samples = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
        defer { samples.deallocate() }
        var position = config.firstPosition
        var sequence = firstSequence
        var counter: UInt64 = 0
        var first = true
        var burst = 0
        var silentPackets = 0

        while running.load(ordering: .relaxed) {
            let now = mach_absolute_time()
            let due = timeline.hostTime(atPosition: Int64(position) + Int64(frames)) &+ delay
            if now < due {
                burst = 0
                mach_wait_until(min(due, now + longestWait))
                continue
            }
            // Stalled for so long that this packet would arrive too late to play: skip ahead.
            if timeline.hostTime(atPosition: Int64(position)) &+ latency < now + minimumLead {
                let caughtUp = timeline.position(atHostTime: now - min(now, delay)) - Int64(frames)
                if caughtUp > Int64(position) {
                    AirPlayLog.debug("\(speaker.name): sender fell behind, skipping \(caughtUp - Int64(position)) frames")
                    position = UInt64(caughtUp)
                    head.store(position, ordering: .relaxed)
                }
            }

            let real = ring.read(into: samples, frames: frames, position: position)
            silentPackets = real == 0 ? silentPackets + 1 : 0
            var payload = Data(count: frames * 4)
            payload.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for i in 0..<(frames * 2) { out[i] = samples[i].bigEndian } // RTP L16 is big-endian
            }
            var packet = AirPlayPacket.audioHeader(first: first, sequence: sequence,
                                                   timestamp: timeline.rtpTime(atPosition: Int64(position)), ssrc: config.ssrc)
            var sendable = true
            if let key = config.key {
                // AirPlay 2: ChaCha20-Poly1305 with the RTP timestamp and SSRC as additional data;
                // the 8-byte nonce counter goes at the end of the packet.
                let nonce = AirPlayCrypto.nonce(counter: counter)
                counter += 1
                if let sealed = try? AirPlayCrypto.seal(payload, key: key, nonce: nonce, aad: packet[4..<12]) {
                    packet.append(sealed)
                    packet.append(nonce.suffix(8))
                } else {
                    sendable = false
                }
            } else {
                packet.append(payload)
            }
            if sendable {
                config.audio.send(content: packet, completion: .idempotent)
                backlog.store(packet, sequence: sequence)
            }
            sequence &+= 1
            position += UInt64(frames)
            head.store(position, ordering: .relaxed)
            first = false

            burst += 1
            if burst >= 4 { // catching up: a few packets at a time, not one big burst
                burst = 0
                mach_wait_until(mach_absolute_time() + pause)
            }
        }
    }

    /// 0...1, mapped to AirPlay volume dB (pyatv's mapping; muted = -144).
    func setVolume(_ volume: Float) {
        let (ready, connection) = lock.withLock { () -> (Bool, AirPlayRTSPConnection?) in
            self.volume = min(max(volume, 0), 1)
            return (canSetVolume && (state == .starting || state == .streaming), rtsp)
        }
        guard ready, let connection else { return }
        Task.detached(priority: .userInitiated) { [self] in _ = await sendVolume(connection) }
    }

    /// Sends the latest volume, coalescing changes made while one is on its way. Returns false if
    /// the speaker refused it.
    private func sendVolume(_ rtsp: AirPlayRTSPConnection) async -> Bool {
        while true {
            let next = lock.withLock { () -> Float? in
                guard !volumeInFlight, let volume, abs(volume - (sentVolume ?? -1)) > 0.0005 else { return nil }
                volumeInFlight = true
                lastVolumeSent = Date()
                return volume
            }
            guard let next else { return true }
            let decibels = AirPlaySpeaker.decibels(forVolume: next)
            let ok: Bool
            do {
                _ = try await rtsp.exchange("SET_PARAMETER", contentType: "text/parameters",
                                            body: Data(String(format: "volume: %.6f", decibels).utf8))
                ok = true
            } catch {
                AirPlayLog.debug("Setting the volume failed: \(error.localizedDescription)")
                ok = false
            }
            lock.withLock {
                volumeInFlight = false
                if ok { sentVolume = next }
            }
            if !ok { return false }
        }
    }

    /// 44.1 kHz, 16-bit signed, stereo interleaved PCM, starting at `position` (frames since the
    /// timeline's frame 0). Callable from any thread, including a real-time audio thread: copies
    /// into a lock-free ring buffer; the network work happens on the session's own thread. Use one
    /// producer at a time, and stay within ~5 s ahead of the timeline's current position.
    func enqueue(_ samples: UnsafePointer<Int16>, frames: Int, position: UInt64) {
        ring.write(samples, frames: frames, position: position)
    }

    // MARK: Stop

    func stop() {
        let previous = lock.withLock { () -> State in
            let previous = state
            state = .stopped
            return previous
        }
        guard previous != .stopped else { return }
        let cancelPIN = lock.withLock { pinCancel }
        cancelPIN?()
        releaseResources(teardown: previous == .streaming)
        AirPlayLog.debug("Stopped streaming to \(speaker.name)")
    }

    private func connectionLost(_ error: AirPlayError) {
        let wasStreaming = lock.withLock { () -> Bool in
            guard state == .streaming else { return false }
            state = .stopped
            return true
        }
        // While starting, the failed request makes start() report the error instead.
        guard wasStreaming else { return }
        releaseResources(teardown: false)
        AirPlayLog.error("Lost AirPlay to \(speaker.name): \(error.localizedDescription)")
        let handler = onError
        DispatchQueue.main.async { handler?(error) }
    }

    private func releaseResources(teardown: Bool) {
        running.store(false, ordering: .relaxed)
        let resources = lock.withLock { () -> (AirPlayRTSPConnection?, AirPlayEventChannel?, AirPlayTimingServer?,
                                               AirPlayControlChannel?, NWConnection?, DispatchSourceTimer?, Task<Void, Never>?) in
            defer {
                rtsp = nil; events = nil; timing = nil; control = nil; audio = nil; syncTimer = nil; keepAlive = nil
                canSetVolume = false
            }
            return (rtsp, events, timing, control, audio, syncTimer, keepAlive)
        }
        let (rtsp, events, timing, control, audio, timer, keepAlive) = resources
        let (peer, grouped) = lock.withLock { () -> (UInt32?, Bool) in
            defer { ptpPeer = nil; inPTPGroup = false }
            return (ptpPeer, inPTPGroup)
        }
        if let peer { AirPlayPTPClock.shared.removePeer(peer) }
        if grouped { timeline.leavePTPGroup(ObjectIdentifier(self)) }
        timer?.cancel()
        keepAlive?.cancel()
        events?.close()
        timing?.close()
        control?.close()
        audio?.cancel()
        backlog.clear()
        guard let rtsp else { return }
        rtsp.onClose = nil
        if teardown {
            let session = lock.withLock { rtspSession }
            Task.detached(priority: .utility) {
                _ = try? await rtsp.exchange("TEARDOWN", headers: [("Session", session)], timeout: 2)
                rtsp.close()
            }
        } else {
            rtsp.close()
        }
    }
}

/// The last 1000 packets sent (pyatv's PACKET_BACKLOG_SIZE), for retransmit requests.
final class AirPlayPacketBacklog: @unchecked Sendable {
    private static let size = 1024
    private let lock = NSLock()
    private var packets = [Data?](repeating: nil, count: AirPlayPacketBacklog.size)
    private var sequences = [UInt16](repeating: 0, count: AirPlayPacketBacklog.size)

    func store(_ packet: Data, sequence: UInt16) {
        let slot = Int(sequence) % Self.size
        lock.withLock {
            packets[slot] = packet
            sequences[slot] = sequence
        }
    }

    /// Each packet wrapped as pyatv does: 0x80 0xD6, the original sequence number, the packet.
    func retransmissions(from first: UInt16, count: UInt16) -> [Data] {
        lock.withLock {
            var out: [Data] = []
            for offset in 0..<min(count, 128) {
                let sequence = first &+ offset
                let slot = Int(sequence) % Self.size
                guard sequences[slot] == sequence, let packet = packets[slot], packet.count >= 4 else { continue }
                var resend = Data([0x80, 0xD6])
                resend.append(packet[(packet.startIndex + 2)..<(packet.startIndex + 4)])
                resend.append(packet)
                out.append(resend)
            }
            return out
        }
    }

    func clear() {
        lock.withLock {
            packets = [Data?](repeating: nil, count: Self.size)
        }
    }
}
