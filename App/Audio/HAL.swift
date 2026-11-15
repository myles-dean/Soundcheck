import AudioToolbox
import CoreAudio
import Foundation

/// Small helpers over the Core Audio HAL's property API.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    var isValid: Bool { self != Self.unknown }
}

enum HAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = address(selector, scope)
        return AudioObjectHasProperty(id, &address)
    }

    static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    /// Reads a fixed-size value (UInt32, Float32, pid_t, AudioObjectID…).
    static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var address = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func write<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, value: T) -> OSStatus {
        var address = address(selector, scope)
        var value = value
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func array<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, zero: T) -> [T] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &values) == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    // MARK: Common reads

    static var defaultOutput: AudioObjectID {
        read(.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown) ?? .unknown
    }

    static var defaultInput: AudioObjectID {
        read(.system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID.unknown) ?? .unknown
    }

    static func deviceUID(_ id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    /// How long after an IO cycle hands a device a frame it's heard (seconds): the device's own
    /// latency plus its first output stream's. Bluetooth and HDMI speakers can take a good while
    /// longer than the Mac's own.
    static func outputLatency(_ device: AudioObjectID) -> TimeInterval {
        let scope = kAudioObjectPropertyScopeOutput
        let rate = read(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
        guard rate > 0 else { return 0 }
        let latency = read(device, kAudioDevicePropertyLatency, scope: scope, initial: UInt32(0)) ?? 0
        let stream = array(device, kAudioDevicePropertyStreams, scope: scope, zero: AudioStreamID(0)).first
        let streamLatency = stream.flatMap { read($0, kAudioStreamPropertyLatency, initial: UInt32(0)) } ?? 0
        return Double(latency + streamLatency) / rate
    }

    /// How much later (seconds) each of these outputs has to play to sound together with the
    /// slowest of them.
    static func alignment(_ uids: [String]) -> [TimeInterval] {
        let latencies = uids.map { outputLatency(device(forUID: $0)) }
        let slowest = latencies.max() ?? 0
        return latencies.map { min(slowest - $0, 1) }
    }

    /// Finds hidden devices too (they're left out of the device list).
    static func device(forUID uid: String) -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr ? device : .unknown
    }

    static func isAlive(_ id: AudioObjectID) -> Bool {
        (read(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) ?? 0) != 0
    }
}

/// Calls `handler` on the main queue whenever a HAL property changes, until released.
final class HALListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, handler: @escaping @MainActor () -> Void) {
        self.object = object
        address = HAL.address(selector, scope)
        block = { _, _ in MainActor.assumeIsolated { handler() } }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}

/// Reads and writes a device's volume and mute the way the volume keys do (the "virtual main"
/// volume, which covers devices that only have per-channel controls).
enum DeviceVolume {
    private static let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    static func canSet(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        HAL.isSettable(id, volume, scope: scope)
    }

    static func get(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        HAL.read(id, volume, scope: scope, initial: Float32(0))
    }

    static func set(_ id: AudioObjectID, scope: AudioObjectPropertyScope, _ value: Float) {
        HAL.write(id, volume, scope: scope, value: Float32(min(max(value, 0), 1)))
    }

    static func isMuted(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        (HAL.read(id, kAudioDevicePropertyMute, scope: scope, initial: UInt32(0)) ?? 0) != 0
    }

    static func canMute(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        HAL.isSettable(id, kAudioDevicePropertyMute, scope: scope)
    }

    static func setMuted(_ id: AudioObjectID, scope: AudioObjectPropertyScope, _ muted: Bool) {
        HAL.write(id, kAudioDevicePropertyMute, scope: scope, value: UInt32(muted ? 1 : 0))
    }
}
