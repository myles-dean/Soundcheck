// AirPlay audio sender for Soundcheck.
//
// A speaker found over Bonjour, and the decisions pyatv makes from its TXT records: AirPlay 1 or 2,
// which pairing it needs, encryption and audio format. Ported from pyatv
// (pyatv/protocols/airplay/utils.py, protocols/raop/parsers.py, protocols/raop/__init__.py and
// protocols/airplay/auth/__init__.py): https://github.com/postlund/pyatv, MIT License,
// © Pierre Ståhl.

import Foundation

/// AirPlay feature flags (`features` on _airplay._tcp, `ft` on _raop._tcp), named as in pyatv.
struct AirPlayFeatures: OptionSet, Hashable, Sendable {
    let rawValue: UInt64
    init(rawValue: UInt64) { self.rawValue = rawValue }

    static let supportsAirPlayAudio = AirPlayFeatures(rawValue: 1 << 9)
    static let hasUnifiedAdvertiserInfo = AirPlayFeatures(rawValue: 1 << 30)
    static let supportsUnifiedMediaControl = AirPlayFeatures(rawValue: 1 << 38)
    static let supportsBufferedAudio = AirPlayFeatures(rawValue: 1 << 40)
    static let supportsPTP = AirPlayFeatures(rawValue: 1 << 41)
    static let supportsSystemPairing = AirPlayFeatures(rawValue: 1 << 43)
    static let supportsHKPairingAndAccessControl = AirPlayFeatures(rawValue: 1 << 46)
    static let supportsCoreUtilsPairingAndEncryption = AirPlayFeatures(rawValue: 1 << 48)

    /// "0x12345678" or "0x12345678,0xABCDEF12" (low word first). pyatv joins the two hex strings
    /// as text, which goes wrong when the low word has fewer than eight digits (the LG TV's does);
    /// this zero-pads it, giving the value the speaker means.
    init?(string: String) {
        let parts = string.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        var words: [UInt64] = []
        for part in parts {
            guard part.lowercased().hasPrefix("0x") else { return nil }
            let hex = part.dropFirst(2)
            guard (1...8).contains(hex.count), let word = UInt64(hex, radix: 16) else { return nil }
            words.append(word)
        }
        rawValue = words.count == 2 ? words[1] << 32 | words[0] : words[0]
    }
}

enum AirPlayProtocolVersion: Sendable, CustomStringConvertible {
    case airPlay1, airPlay2
    var description: String { self == .airPlay1 ? "AirPlay 1" : "AirPlay 2" }
}

/// pyatv's PairingRequirement.
enum AirPlayPairingRequirement: Sendable {
    /// Transient pairing (AirPlay 2) or nothing (AirPlay 1) is enough.
    case notNeeded
    /// The speaker wants a one-time code shown on its screen before it plays (sf/flags 0x200 or 0x8).
    case mandatory
    /// acl=1: only people in the speaker's Home may play to it. pyatv can't pair those.
    case disabled
    /// act=2 ("Current User" access control), which pyatv doesn't support.
    case unsupported
}

/// How a session will authenticate with a speaker.
enum AirPlayAuthentication: Sendable, CustomStringConvertible {
    /// AirPlay 1 without pairing: plain RTSP.
    case none
    /// HomeKit transient pair-setup with the fixed PIN 3939; nothing is stored.
    case transient
    /// One-time pairing with the code the speaker shows, saved in the Keychain, then pair-verify.
    case pinPairing
    /// Pair-verify with the keys saved by an earlier PIN pairing.
    case pairVerify

    var description: String {
        switch self {
        case .none: "no pairing"
        case .transient: "transient pairing (HomeKit SRP, PIN 3939), encrypted RTSP"
        case .pinPairing: "one-time pairing with the code on the speaker's screen, then pair-verify, encrypted RTSP"
        case .pairVerify: "pair-verify with saved pairing, encrypted RTSP"
        }
    }
}

/// An AirPlay speaker on the network (from _airplay._tcp and _raop._tcp, merged by device ID).
struct AirPlaySpeaker: Identifiable, Hashable, Sendable {
    /// Device ID (MAC address, "AA:BB:CC:11:22:33"), stable.
    let id: String
    /// "Living Room"
    let name: String
    /// "AppleTV11,1", "AudioAccessory5,1", …
    let model: String
    /// Bonjour host name ("Living-Room.local.").
    let host: String
    /// The port the RTSP session uses (the _raop._tcp port, or _airplay._tcp's without RAOP).
    let port: UInt16
    /// TXT record of the _raop._tcp service (empty if the speaker doesn't advertise one).
    let raopProperties: [String: String]
    /// TXT record of the _airplay._tcp service (empty if the speaker doesn't advertise one).
    let airplayProperties: [String: String]
    /// "AABBCC112233@Living Room"
    let raopServiceName: String?
    /// "Living Room"
    let airplayServiceName: String?
    /// SF Symbol: "appletv.fill", "homepod.mini.fill", "homepod.fill", "tv", "hifispeaker.fill".
    var symbol: String

    init(id: String, name: String, model: String, host: String, port: UInt16,
         raopProperties: [String: String], airplayProperties: [String: String],
         raopServiceName: String?, airplayServiceName: String?) {
        self.id = id
        self.name = name
        self.model = model
        self.host = host
        self.port = port
        self.raopProperties = raopProperties
        self.airplayProperties = airplayProperties
        self.raopServiceName = raopServiceName
        self.airplayServiceName = airplayServiceName
        symbol = Self.symbol(model: model, name: name, properties: airplayProperties.merging(raopProperties) { a, _ in a })
    }

    /// The properties pyatv's RAOP service would have: _raop._tcp's, or, for AirPlay 2 speakers
    /// that only advertise _airplay._tcp, the AirPlay service's (pyatv does this when the
    /// speaker sets HasUnifiedAdvertiserInfo).
    var properties: [String: String] { raopProperties.isEmpty ? airplayProperties : raopProperties }

    var features: AirPlayFeatures {
        let string = properties["ft"] ?? properties["features"] ?? "0x0"
        return AirPlayFeatures(string: string) ?? []
    }

    /// Status flags (`sf` on _raop._tcp, `flags` on _airplay._tcp).
    var statusFlags: UInt64 {
        let string = properties["sf"] ?? properties["flags"] ?? "0x0"
        return UInt64(string.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
    }

    /// pyatv's get_protocol_version (Auto): AirPlay 2 if bit 38 or 48 is set.
    var protocolVersion: AirPlayProtocolVersion {
        features.isDisjoint(with: [.supportsUnifiedMediaControl, .supportsCoreUtilsPairingAndEncryption])
            ? .airPlay1 : .airPlay2
    }

    /// Feature bit 41 (SupportsPTP, as pyatv and OwnTone name it) on an AirPlay 2 speaker: its
    /// realtime stream can be timed with PTP, which is how a Mac syncs it.
    var supportsPTP: Bool { protocolVersion == .airPlay2 && features.contains(.supportsPTP) }

    /// pyatv's is_password_required.
    var requiresPassword: Bool {
        properties["pw"]?.lowercased() == "true" || statusFlags & 0x80 != 0
    }

    /// pyatv's raop.service_info / update_service_details / get_pairing_requirement.
    var pairingRequirement: AirPlayPairingRequirement {
        if airplayProperties["acl"] == "1" { return .disabled }
        if airplayProperties["act"] == "2" { return .unsupported }
        if properties["acl"] == "1" { return .disabled }
        if let model = properties["model"], model.range(of: #"^Mac\d+,\d+$"#, options: .regularExpression) != nil {
            return .unsupported
        }
        if statusFlags & (0x200 | 0x8) != 0 { return .mandatory }
        if properties["act"] == "2" { return .unsupported }
        return .notNeeded
    }

    /// pyatv's extract_credentials without stored credentials: transient pairing when the speaker
    /// supports system pairing or CoreUtils pairing.
    var supportsTransientPairing: Bool {
        let string = properties["features"] ?? properties["ft"] ?? "0x0"
        let flags = AirPlayFeatures(string: string) ?? []
        return !flags.isDisjoint(with: [.supportsSystemPairing, .supportsCoreUtilsPairingAndEncryption])
    }

    /// `et`: 0 = unencrypted, 1 = RSA, 3 = FairPlay, 4 = MFiSAP, 5 = FairPlay SAPv2.5.
    var encryptionTypes: Set<Int> {
        Set((properties["et"] ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// pyatv only does /auth-setup for AirPort Expresses that support MFiSAP.
    var requiresAuthSetup: Bool {
        encryptionTypes.contains(4) && (properties["am"] ?? "").hasPrefix("AirPort")
    }

    /// pyatv's get_audio_properties: sample rate, channels, bytes per sample.
    var audioFormat: (sampleRate: Int, channels: Int, bytesPerSample: Int) {
        (Int(properties["sr"] ?? "") ?? 44100, Int(properties["ch"] ?? "") ?? 2, (Int(properties["ss"] ?? "") ?? 16) / 8)
    }

    /// True when the speaker takes 44.1 kHz, 16-bit stereo (what sessions send).
    var acceptsCDAudio: Bool { audioFormat == (44100, 2, 2) }

    /// False for speakers that only advertise _airplay._tcp without HasUnifiedAdvertiserInfo:
    /// pyatv wouldn't stream to those (sessions still try, as AirPlay 2 over the AirPlay port).
    var pyatvStreams: Bool { !raopProperties.isEmpty || features.contains(.hasUnifiedAdvertiserInfo) }

    /// How a session will authenticate, given whether a pairing is saved for this speaker.
    func authentication(hasSavedPairing: Bool) -> AirPlayAuthentication {
        if protocolVersion == .airPlay1 { return .none }
        if hasSavedPairing { return .pairVerify }
        if pairingRequirement == .mandatory { return .pinPairing }
        return supportsTransientPairing ? .transient : .pinPairing
    }

    /// The authentication a session will use now (looks in the Keychain).
    var authentication: AirPlayAuthentication {
        authentication(hasSavedPairing: AirPlayCredentialStore.contains(deviceID: id))
    }

    static func symbol(model: String, name: String, properties: [String: String]) -> String {
        if model.hasPrefix("AppleTV") { return "appletv.fill" }
        if model.hasPrefix("AudioAccessory5") { return "homepod.mini.fill" }
        if model.hasPrefix("AudioAccessory") { return "homepod.fill" }
        if model.hasPrefix("MacBook") { return "laptopcomputer" }
        if model.hasPrefix("Mac") || model.hasPrefix("iMac") { return "desktopcomputer" }
        let manufacturer = properties["manufacturer"] ?? ""
        let haystack = [model, name, manufacturer].joined(separator: " ")
        if haystack.range(of: #"\bTV\b|webOS|Television|Bravia|Roku|Vizio|Fire ?TV"#,
                          options: [.regularExpression, .caseInsensitive]) != nil {
            return "tv"
        }
        return "hifispeaker.fill"
    }

    /// pyatv's pct_to_dbfs: 0…1 maps to -30…0 dB, and 0 is "muted" (-144).
    static func decibels(forVolume volume: Float) -> Float {
        let clamped = min(max(volume, 0), 1)
        if clamped == 0 { return -144 }
        return -30 + 30 * clamped
    }
}
