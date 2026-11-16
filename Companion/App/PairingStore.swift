import CryptoKit
import Foundation
import Security

/// The pairings with Macs, in the keychain. They're synced through iCloud Keychain, so once the
/// iPhone is allowed on a Mac, the iPad on the same Apple Account is too (and the other way).
/// Readable after the first unlock, so a companion woken in the background can still connect.
enum PairingStore {
    struct Pairing: Codable, Equatable {
        var mac: String
        var macName: String
        var pairing: String
        var key: Data
        var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
    }

    private static let service = "Soundcheck Companion pairing"

    static func pairing(for mac: String) -> Pairing? {
        var query = baseQuery(mac)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    static var all: [Pairing] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecReturnAttributes as String] = false
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let list = result as? [Data] else { return [] }
        return list.compactMap { try? JSONDecoder().decode(Pairing.self, from: $0) }
    }

    static func save(_ pairing: Pairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        SecItemDelete(baseQuery(pairing.mac) as CFDictionary)
        var item = baseQuery(pairing.mac)
        item[kSecAttrSynchronizable as String] = true
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecValueData as String] = data
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
            // No iCloud Keychain: kept on this device only.
            item[kSecAttrSynchronizable as String] = false
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func forget(_ mac: String) {
        SecItemDelete(baseQuery(mac) as CFDictionary)
    }

    private static func baseQuery(_ mac: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: mac,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    /// This device (not synced: the iPhone and the iPad are told apart).
    static let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()

    /// "iPhone" or "iPad" (what the Mac lists it as), from the model ("iPad16,3"; the
    /// simulator says which it's pretending to be).
    static let deviceKind: String = {
        var model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if model.isEmpty {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            var machine = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.machine", &machine, &size, nil, 0)
            model = String(cString: machine)
        }
        return model.hasPrefix("iPad") ? "iPad" : "iPhone"
    }()
}
