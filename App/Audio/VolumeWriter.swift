import CoreAudio
import Foundation

/// Sets device volumes off the main thread, keeping only the latest value for each device.
/// Some devices (USB microphones and webcams especially) take a while to answer, and a volume
/// key or a slider sends many changes a second, so writing them in line made the pill lag.
final class VolumeWriter: @unchecked Sendable {
    static let shared = VolumeWriter()

    private struct Target: Hashable {
        let device: AudioObjectID
        let scope: AudioObjectPropertyScope
    }

    private let queue = DispatchQueue(label: "com.mylesdean.Soundcheck.volume", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [Target: Float] = [:]
    private var scheduled = false

    func set(_ device: AudioObjectID, scope: AudioObjectPropertyScope, _ volume: Float) {
        lock.lock()
        pending[Target(device: device, scope: scope)] = volume
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule { queue.async { self.flush() } }
    }

    private func flush() {
        lock.lock()
        let work = pending
        pending = [:]
        scheduled = false
        lock.unlock()
        for (target, volume) in work { DeviceVolume.set(target.device, scope: target.scope, volume) }
    }
}
