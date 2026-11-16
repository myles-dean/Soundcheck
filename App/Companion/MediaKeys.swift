import AppKit

/// The keyboard's media keys, pressed for a companion's play/pause and skip buttons (whatever's
/// playing on the Mac answers them, as it would the keys). Posting key events needs the
/// Accessibility permission, which Soundcheck has for the volume keys.
enum MediaKeys {
    enum Key: Int32 {
        case playPause = 16 // NX_KEYTYPE_PLAY
        case next = 17 // NX_KEYTYPE_NEXT
        case previous = 18 // NX_KEYTYPE_PREVIOUS
    }

    static func press(_ key: Key) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | (down ? 0xA00 : 0xB00))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
