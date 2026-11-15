// AirPlay audio sender for Soundcheck.
//
// HomeKit-style pairing over AirPlay: transient pair-setup (fixed PIN 3939, nothing stored),
// one-time pair-setup with the code a speaker shows on screen, and pair-verify with the stored
// keys. Ported from pyatv (pyatv/protocols/airplay/auth/hap_transient.py, hap.py, __init__.py,
// pyatv/auth/hap_srp.py, hap_pairing.py): https://github.com/postlund/pyatv, MIT License,
// © Pierre Ståhl.

import CryptoKit
import Foundation
import Security

/// Long-term pairing keys (pyatv's HapCredentials), stored in pyatv's text form
/// "ltpk:ltsk:atv_id:client_id" (hex), so pyatv credentials can be imported and vice versa.
struct AirPlayCredentials: Sendable, Hashable {
    /// The speaker's long-term Ed25519 public key.
    let ltpk: Data
    /// Our long-term Ed25519 private key (32-byte seed).
    let ltsk: Data
    /// The speaker's pairing identifier.
    let atvID: Data
    /// Our pairing identifier.
    let clientID: Data

    var stringValue: String { [ltpk, ltsk, atvID, clientID].map(\.hexString).joined(separator: ":") }

    init(ltpk: Data, ltsk: Data, atvID: Data, clientID: Data) {
        self.ltpk = ltpk
        self.ltsk = ltsk
        self.atvID = atvID
        self.clientID = clientID
    }

    init?(string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false).map { Data(hexString: String($0)) }
        guard parts.count == 4, let ltpk = parts[0], let ltsk = parts[1], let atvID = parts[2], let clientID = parts[3],
              !ltpk.isEmpty, !ltsk.isEmpty, !atvID.isEmpty, !clientID.isEmpty else { return nil }
        self.init(ltpk: ltpk, ltsk: ltsk, atvID: atvID, clientID: clientID)
    }
}

/// Pairings saved in the login Keychain, one per speaker device ID.
enum AirPlayCredentialStore {
    static let service = "com.mylesdean.Soundcheck.AirPlay"

    private static func query(_ deviceID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: deviceID]
    }

    static func load(deviceID: String) -> AirPlayCredentials? {
        var query = query(deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return AirPlayCredentials(string: text)
    }

    /// Whether a pairing is saved (reads attributes only, so it never prompts).
    static func contains(deviceID: String) -> Bool {
        var query = query(deviceID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func save(_ credentials: AirPlayCredentials, deviceID: String, speakerName: String) {
        remove(deviceID: deviceID)
        var item = query(deviceID)
        item[kSecValueData as String] = Data(credentials.stringValue.utf8)
        item[kSecAttrLabel as String] = "Soundcheck AirPlay pairing (\(speakerName))"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { AirPlayLog.error("Couldn't save the AirPlay pairing (\(status))") }
    }

    static func remove(deviceID: String) {
        SecItemDelete(query(deviceID) as CFDictionary)
    }
}

/// Derives session keys once pairing or verification succeeds (pyatv's PairVerifyProcedure).
struct AirPlayPairVerifier: Sendable {
    /// The transient SRP session key, or the pair-verify X25519 shared secret.
    let sharedSecret: Data

    func encryptionKeys(salt: String, outputInfo: String, inputInfo: String) -> (output: Data, input: Data) {
        (AirPlayCrypto.hkdf(sharedSecret, salt: salt, info: outputInfo),
         AirPlayCrypto.hkdf(sharedSecret, salt: salt, info: inputInfo))
    }
}

enum AirPlayPairing {
    static let transientPIN = "3939"

    /// pyatv's _AIRPLAY_HEADERS; X-Apple-HKP is 3 for normal pairing, 4 for transient.
    static func headers(hkp: Int) -> [(String, String)] {
        [("User-Agent", "AirPlay/320.20"), ("Connection", "keep-alive"), ("X-Apple-HKP", "\(hkp)"),
         ("Content-Type", "application/octet-stream")]
    }

    private static func tlv(_ response: AirPlayHTTPMessage, step: String) throws -> [UInt8: Data] {
        let tlv = TLV8.decode(response.body)
        if let error = TLV8.describeError(tlv) { throw AirPlayError.authenticationFailed("\(step): \(error)") }
        return tlv
    }

    /// Transient pairing (AirPlayHapTransientPairVerifyProcedure): pair-setup M1–M4 with the fixed
    /// PIN; the SRP session key is the shared secret.
    static func transient(_ rtsp: AirPlayRTSPConnection) async throws -> AirPlayPairVerifier {
        let headers = headers(hkp: 4)
        let start = try await rtsp.post("/pair-pin-start", headers: headers, allowError: true)
        if !(200..<300).contains(start.code) { AirPlayLog.debug("pair-pin-start answered \(start.code), carrying on") }

        let m1 = TLV8.encode([(.method, Data([0x00])), (.seqNo, Data([0x01])), (.flags, Data([0x10]))])
        let m2 = try tlv(try await rtsp.post("/pair-setup", headers: headers, body: m1), step: "pair-setup M2")
        guard let salt = m2[TLVTag.salt.rawValue], let serverKey = m2[TLVTag.publicKey.rawValue] else {
            throw AirPlayError.authenticationFailed("pair-setup M2 had no salt or public key")
        }
        let srp = try AirPlaySRPClient(password: transientPIN).process(serverPublicKey: serverKey, salt: salt)
        let m3 = TLV8.encode([(.seqNo, Data([0x03])), (.publicKey, srp.publicKey), (.proof, srp.proof)])
        let m4 = try tlv(try await rtsp.post("/pair-setup", headers: headers, body: m3), step: "pair-setup M4")
        if let proof = m4[TLVTag.proof.rawValue], proof != srp.expectedServerProof {
            AirPlayLog.debug("Transient pairing: the speaker's SRP proof doesn't match ours (pyatv doesn't check it either)")
        }
        AirPlayLog.debug("Transient pairing done")
        return AirPlayPairVerifier(sharedSecret: srp.sessionKey)
    }

    /// Pair-verify with saved keys (AirPlayHapPairVerifyProcedure / SRPAuthHandler.verify1).
    static func verify(_ rtsp: AirPlayRTSPConnection, credentials: AirPlayCredentials) async throws -> AirPlayPairVerifier {
        let headers = headers(hkp: 3)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ourPublic = ephemeral.publicKey.rawRepresentation

        let m1 = TLV8.encode([(.seqNo, Data([0x01])), (.publicKey, ourPublic)])
        let m2 = try tlv(try await rtsp.post("/pair-verify", headers: headers, body: m1), step: "pair-verify M2")
        guard let theirPublic = m2[TLVTag.publicKey.rawValue], let encrypted = m2[TLVTag.encryptedData.rawValue] else {
            throw AirPlayError.authenticationFailed("pair-verify M2 had no public key")
        }
        let shared: Data
        do {
            let secret = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirPublic))
            shared = secret.withUnsafeBytes { Data($0) }
        } catch {
            throw AirPlayError.authenticationFailed("pair-verify: bad public key")
        }
        let sessionKey = SymmetricKey(data: AirPlayCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt",
                                                               info: "Pair-Verify-Encrypt-Info"))
        let inner: [UInt8: Data]
        do {
            inner = TLV8.decode(try AirPlayCrypto.open(encrypted, key: sessionKey, nonce: AirPlayCrypto.nonce(label: "PV-Msg02")))
        } catch {
            throw AirPlayError.authenticationFailed("pair-verify: couldn't decrypt the speaker's reply")
        }
        guard let identifier = inner[TLVTag.identifier.rawValue], let signature = inner[TLVTag.signature.rawValue] else {
            throw AirPlayError.authenticationFailed("pair-verify M2 was incomplete")
        }
        guard identifier == credentials.atvID else {
            throw AirPlayError.authenticationFailed("pair-verify: the speaker isn't the one we paired with")
        }
        let theirInfo = theirPublic + identifier + ourPublic
        guard let longTerm = try? Curve25519.Signing.PublicKey(rawRepresentation: credentials.ltpk),
              longTerm.isValidSignature(signature, for: theirInfo) else {
            throw AirPlayError.authenticationFailed("pair-verify: the speaker's signature is wrong")
        }
        let ourInfo = ourPublic + credentials.clientID + theirPublic
        let ourSignature: Data
        do {
            ourSignature = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk).signature(for: ourInfo)
        } catch {
            throw AirPlayError.authenticationFailed("pair-verify: the saved pairing is damaged")
        }
        let reply = TLV8.encode([(.identifier, credentials.clientID), (.signature, ourSignature)])
        let sealed = try AirPlayCrypto.seal(reply, key: sessionKey, nonce: AirPlayCrypto.nonce(label: "PV-Msg03"))
        let m3 = TLV8.encode([(.seqNo, Data([0x03])), (.encryptedData, sealed)])
        _ = try tlv(try await rtsp.post("/pair-verify", headers: headers, body: m3), step: "pair-verify M4")
        AirPlayLog.debug("Pair-verify done")
        return AirPlayPairVerifier(sharedSecret: shared)
    }
}

/// One-time pairing with the code the speaker shows (AirPlayHapPairSetupProcedure).
final class AirPlayPINPairing: @unchecked Sendable {
    private let rtsp: AirPlayRTSPConnection
    private let signingKey = Curve25519.Signing.PrivateKey()
    /// pyatv: str(uuid.uuid4()).encode()
    private let pairingID = Data(UUID().uuidString.lowercased().utf8)
    private var salt = Data()
    private var serverKey = Data()

    init(rtsp: AirPlayRTSPConnection) { self.rtsp = rtsp }

    /// Makes the speaker show its code, and does M1/M2.
    func start() async throws {
        let headers = AirPlayPairing.headers(hkp: 3)
        _ = try await rtsp.post("/pair-pin-start", headers: headers)
        let m1 = TLV8.encode([(.method, Data([0x00])), (.seqNo, Data([0x01]))])
        let response = try await rtsp.post("/pair-setup", headers: headers, body: m1)
        let m2 = TLV8.decode(response.body)
        if let error = TLV8.describeError(m2) { throw AirPlayError.authenticationFailed("pair-setup M2: \(error)") }
        guard let salt = m2[TLVTag.salt.rawValue], let key = m2[TLVTag.publicKey.rawValue] else {
            throw AirPlayError.authenticationFailed("pair-setup M2 had no salt or public key")
        }
        self.salt = salt
        serverKey = key
    }

    /// M3–M6 with the code the user typed.
    func finish(pin: String, name: String) async throws -> AirPlayCredentials {
        let headers = AirPlayPairing.headers(hkp: 3)
        let srp = try AirPlaySRPClient(password: pin).process(serverPublicKey: serverKey, salt: salt)
        let m3 = TLV8.encode([(.seqNo, Data([0x03])), (.publicKey, srp.publicKey), (.proof, srp.proof)])
        let m4 = TLV8.decode(try await rtsp.post("/pair-setup", headers: headers, body: m3).body)
        if let error = TLV8.describeError(m4) { throw AirPlayError.authenticationFailed("pair-setup M4: \(error)") }

        let K = srp.sessionKey
        let deviceX = AirPlayCrypto.hkdf(K, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let sessionKey = SymmetricKey(data: AirPlayCrypto.hkdf(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info"))
        let ourPublic = signingKey.publicKey.rawRepresentation
        let signature = try signingKey.signature(for: deviceX + pairingID + ourPublic)
        let inner = TLV8.encode([(.identifier, pairingID), (.publicKey, ourPublic), (.signature, signature),
                                 (.name, AirPlayCrypto.opack(["name": name]))])
        let sealed = try AirPlayCrypto.seal(inner, key: sessionKey, nonce: AirPlayCrypto.nonce(label: "PS-Msg05"))
        let m5 = TLV8.encode([(.seqNo, Data([0x05])), (.encryptedData, sealed)])
        let m6 = TLV8.decode(try await rtsp.post("/pair-setup", headers: headers, body: m5).body)
        if let error = TLV8.describeError(m6) { throw AirPlayError.authenticationFailed("pair-setup M6: \(error)") }
        guard let encrypted = m6[TLVTag.encryptedData.rawValue] else {
            throw AirPlayError.authenticationFailed("pair-setup M6 had no data")
        }
        let accessory: [UInt8: Data]
        do {
            accessory = TLV8.decode(try AirPlayCrypto.open(encrypted, key: sessionKey, nonce: AirPlayCrypto.nonce(label: "PS-Msg06")))
        } catch {
            throw AirPlayError.authenticationFailed("pair-setup M6 couldn't be decrypted")
        }
        guard let atvID = accessory[TLVTag.identifier.rawValue], let ltpk = accessory[TLVTag.publicKey.rawValue] else {
            throw AirPlayError.authenticationFailed("pair-setup M6 was incomplete")
        }
        // pyatv doesn't check the speaker's signature here; log if it's off rather than fail.
        if let theirSignature = accessory[TLVTag.signature.rawValue],
           let key = try? Curve25519.Signing.PublicKey(rawRepresentation: ltpk) {
            let accessoryX = AirPlayCrypto.hkdf(K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
            if !key.isValidSignature(theirSignature, for: accessoryX + atvID + ltpk) {
                AirPlayLog.debug("PIN pairing: the speaker's M6 signature didn't verify")
            }
        }
        AirPlayLog.debug("PIN pairing done")
        return AirPlayCredentials(ltpk: ltpk, ltsk: signingKey.rawRepresentation, atvID: atvID, clientID: pairingID)
    }
}
