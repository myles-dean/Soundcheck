import CoreAudio
import CoreGraphics
import Foundation
import IOKit.ps

enum AudioDirection {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }
}

/// An output or input device you can pick (no hidden devices, and none of Soundcheck's own).
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    /// The built-in output's current data source (speakers or headphones), 0 if it has none.
    let outputSource: UInt32

    /// Soundcheck's own aggregate devices start with this UID.
    static let ownUIDPrefix = "com.mylesdean.Soundcheck."

    var isAirPlay: Bool { transport == kAudioDeviceTransportTypeAirPlay }

    /// Headphones for Switch to Headphones: anything Bluetooth (AirPods, headphones), a USB or
    /// other device named like headphones, or the Mac's own jack with headphones plugged in.
    var isHeadphones: Bool {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            return outputSource == 0x6864_706E // 'hdpn'
        default:
            let lower = name.lowercased()
            return ["headphone", "headset", "airpods", "earbud", "earphone"].contains(where: lower.contains)
        }
    }

    /// Whether macOS can set its volume (displays over HDMI or DisplayPort usually can't, so
    /// Soundcheck turns their sound down itself).
    var hasHardwareVolume: Bool { DeviceVolume.canSet(id, scope: kAudioObjectPropertyScopeOutput) }

    func symbol(_ direction: AudioDirection) -> String {
        let lower = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            if direction == .output && outputSource == 0x6864_706E /* 'hdpn' */ { return "headphones" }
            return Self.macSymbol
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lower.contains("airpods max") { return "airpods.max" }
            if lower.contains("airpods pro") { return "airpods.pro" }
            if lower.contains("airpods") { return "airpods" }
            if lower.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        case kAudioDeviceTransportTypeVirtual:
            return "waveform"
        case kAudioDeviceTransportTypeAggregate:
            return "hifispeaker.2"
        default:
            if direction == .input {
                return ["cam", "link", "facetime"].contains(where: lower.contains) ? "web.camera" : "mic"
            }
            return "hifispeaker"
        }
    }

    /// The Mac's own speakers and microphone are drawn as the Mac itself.
    static let macSymbol: String = {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
           list.contains(where: { source in
               let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
               return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
           }) {
            return "laptopcomputer"
        }
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &displays, &count)
        if displays.prefix(Int(count)).contains(where: { CGDisplayIsBuiltin($0) != 0 }) { return "desktopcomputer" }
        return "macmini"
    }()

    // MARK: Listing

    static func list(_ direction: AudioDirection) -> [AudioDevice] {
        HAL.array(.system, kAudioHardwarePropertyDevices, zero: AudioObjectID.unknown).compactMap { id in
            guard let uid = HAL.deviceUID(id), !uid.hasPrefix(ownUIDPrefix),
                  (HAL.read(id, kAudioDevicePropertyIsHidden, initial: UInt32(0)) ?? 0) == 0,
                  !HAL.array(id, kAudioDevicePropertyStreams, scope: direction.scope, zero: AudioStreamID(0)).isEmpty,
                  (HAL.read(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: direction.scope, initial: UInt32(0)) ?? 0) != 0
            else { return nil }
            return AudioDevice(id: id)
        }
    }

    init?(id: AudioObjectID) {
        guard let uid = HAL.deviceUID(id) else { return nil }
        self.id = id
        self.uid = uid
        name = HAL.string(id, kAudioObjectPropertyName) ?? "Unknown Device"
        transport = HAL.read(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
        outputSource = HAL.read(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) ?? 0
    }
}
