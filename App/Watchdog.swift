import CoreAudio
import Foundation
import os

/// Keeps a crash from leaving you without a microphone. Soundcheck Mic is silent without
/// Soundcheck feeding it, so if Soundcheck crashes or is killed, a call would carry on with no
/// sound and no sign why.
///
/// A second copy of Soundcheck's own executable (started with `--watchdog`, no window or menu bar
/// icon) waits on a pipe from Soundcheck. Soundcheck writes "bye" when it quits normally and, from
/// its crash signal handlers, "crash". When the pipe closes (Soundcheck is gone, however it went),
/// the watchdog makes the real microphone macOS's input again if Soundcheck Mic is still it, and
/// after a crash opens Soundcheck again, which takes Soundcheck Mic back. A crash in the first 20
/// seconds isn't retried, so a Soundcheck that can't start doesn't keep crashing. Being killed
/// (Force Quit) isn't a crash: the mic comes back but Soundcheck stays closed.
enum Watchdog {
    static let argument = "--watchdog"
    private static let log = Logger(subsystem: "com.mylesdean.Soundcheck", category: "watchdog")

    // MARK: Inside Soundcheck

    /// The write end of the pipe, for the crash handlers (which can only use plain system calls).
    nonisolated(unsafe) private static var pipeFD: Int32 = -1
    nonisolated(unsafe) private static var pipe: Pipe?

    /// Starts the watchdog beside Soundcheck.
    static func start() {
        guard pipe == nil, let executable = Bundle.main.executableURL else { return }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument]
        process.standardInput = pipe.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("Couldn't start the watchdog: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Only the watchdog keeps the read end, so the pipe closes when Soundcheck goes away.
        try? pipe.fileHandleForReading.close()
        let fd = pipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1) // a watchdog that's gone mustn't take Soundcheck with it
        Self.pipe = pipe
        pipeFD = fd
        installCrashHandlers()
    }

    /// Soundcheck is quitting normally (it gives the real mic back itself).
    static func quitting() {
        send("bye\n")
    }

    private static func send(_ message: StaticString) {
        guard pipeFD >= 0 else { return }
        message.withUTF8Buffer { buffer in _ = write(pipeFD, buffer.baseAddress, buffer.count) }
    }

    /// Crashes tell the watchdog before Soundcheck goes (then crash as they would have, so macOS
    /// still writes its crash report).
    private static func installCrashHandlers() {
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(signalNumber) { caught in
                Watchdog.send("crash\n")
                signal(caught, SIG_DFL)
                raise(caught)
            }
        }
    }

    // MARK: The watchdog

    /// SOUNDCHECK_WATCHDOG_DRY_RUN=1: say what it would do instead (for testing it by hand), and
    /// SOUNDCHECK_WATCHDOG_SETTLE sets how long Soundcheck has to have run for a crash to reopen it.
    private static let environment = ProcessInfo.processInfo.environment
    private static let dryRun = environment["SOUNDCHECK_WATCHDOG_DRY_RUN"] != nil
    private static let settle = environment["SOUNDCHECK_WATCHDOG_SETTLE"].flatMap(TimeInterval.init) ?? 20

    /// Waits for Soundcheck to go, then tidies up after it. Never returns.
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let started = Date()
        var said = Data()
        // Blocks until Soundcheck writes or goes away (empty data: the pipe closed).
        while true {
            let data = FileHandle.standardInput.availableData
            if data.isEmpty { break }
            said.append(data)
        }
        let message = String(decoding: said, as: UTF8.self)
        let crashed = message.contains("crash") && !message.contains("bye")
        // Whatever happened, Soundcheck Mic can't stay the input with nothing feeding it.
        restoreMicrophone()
        if crashed {
            if Date().timeIntervalSince(started) > settle {
                log.notice("Soundcheck crashed; opening it again")
                relaunch()
            } else {
                log.notice("Soundcheck crashed just after it started; leaving it closed")
                if dryRun { print("crashed too soon: leaving it closed") }
            }
        }
        if dryRun { print("done (\(crashed ? "crash" : message.contains("bye") ? "quit" : "killed"))") }
        exit(0)
    }

    /// The real microphone becomes macOS's input again: the one Soundcheck was carrying, or else
    /// the Mac's own, or else any.
    private static func restoreMicrophone() {
        let microphone = HAL.device(forUID: MicDriver.microphoneUID)
        guard microphone.isValid, HAL.defaultInput == microphone else {
            if dryRun { print("microphone: nothing to give back") }
            return
        }
        let inputs = AudioDevice.list(.input).filter { $0.uid != MicDriver.microphoneUID }
        let saved = UserDefaults.standard.string(forKey: AudioEngine.selectedMicrophoneKey)
        guard let real = inputs.first(where: { $0.uid == saved })
                ?? inputs.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn })
                ?? inputs.first else { return }
        if dryRun { print("would give the microphone back to \(real.name)"); return }
        HAL.write(.system, kAudioHardwarePropertyDefaultInputDevice, value: real.id)
        log.notice("Gave the microphone back to \(real.name, privacy: .public)")
    }

    private static func relaunch() {
        if dryRun { print("would open Soundcheck again"); return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", Bundle.main.bundleURL.path, "--args", "--background"]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            log.error("Couldn't open Soundcheck again: \(error.localizedDescription, privacy: .public)")
        }
    }
}
