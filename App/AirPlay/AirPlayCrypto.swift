// AirPlay audio sender for Soundcheck.
//
// TLV8, ChaCha20-Poly1305 and HKDF helpers, and the HAP framing used to encrypt the RTSP and
// event connections. Ported from pyatv (pyatv/auth/hap_tlv8.py, hap_session.py,
// pyatv/support/chacha20.py, hap_srp.hkdf_expand, support/opack.py):
// https://github.com/postlund/pyatv, MIT License, © Pierre Ståhl.

import CryptoKit
import Foundation

// MARK: - TLV8

/// HomeKit TLV8 tags (hap_tlv8.TlvValue).
enum TLVTag: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case seqNo = 0x06
    case error = 0x07
    case backOff = 0x08
    case signature = 0x0A
    case name = 0x11
    case flags = 0x13
}

enum TLV8 {
    /// Values over 255 bytes are split into several items with the same tag.
    static func encode(_ items: [(TLVTag, Data)]) -> Data {
        var out = Data()
        for (tag, value) in items {
            var offset = value.startIndex
            repeat {
                let size = min(255, value.endIndex - offset)
                out.append(tag.rawValue)
                out.append(UInt8(size))
                out.append(value[offset..<(offset + size)])
                offset += size
            } while offset < value.endIndex
        }
        return out
    }

    /// Repeated tags are concatenated (that's how values over 255 bytes come back).
    static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        var i = data.startIndex
        while i + 1 < data.endIndex {
            let tag = data[i]
            let length = Int(data[i + 1])
            let start = i + 2
            let end = min(start + length, data.endIndex)
            result[tag, default: Data()].append(data[start..<end])
            i = end
        }
        return result
    }

    static func describeError(_ tlv: [UInt8: Data]) -> String? {
        guard let error = tlv[TLVTag.error.rawValue]?.first else { return nil }
        switch error {
        case 0x02: return "authentication failed (wrong code?)"
        case 0x03:
            let seconds = tlv[TLVTag.backOff.rawValue].map { $0.reduce(0) { $0 << 8 | Int($1) } } ?? 0
            return "too many attempts, try again in \(seconds) s"
        case 0x04: return "the speaker has too many pairings"
        case 0x05: return "too many attempts"
        case 0x06: return "pairing isn't available right now"
        case 0x07: return "the speaker is busy pairing with something else"
        default: return "pairing error \(error)"
        }
    }
}

// MARK: - ChaCha20-Poly1305 and HKDF

enum AirPlayCrypto {
    /// HKDF-SHA512 with string salt and info, 32 bytes out (hap_srp.hkdf_expand).
    static func hkdf(_ secret: Data, salt: String, info: String) -> Data {
        let key = HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                         salt: Data(salt.utf8), info: Data(info.utf8),
                                         outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The 12-byte nonce pyatv builds from a counter: four zero bytes, then the counter as
    /// little-endian UInt64.
    static func nonce(counter: UInt64) -> Data {
        var nonce = Data(count: 4)
        nonce.appendLittleEndian(counter)
        return nonce
    }

    /// A short nonce such as "PV-Msg02", left-padded with zeros to 12 bytes.
    static func nonce(label: String) -> Data {
        let bytes = Data(label.utf8)
        return Data(count: max(0, 12 - bytes.count)) + bytes
    }

    /// Ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: Data, aad: Data? = nil) throws -> Data {
        let n = try ChaChaPoly.Nonce(data: nonce)
        let box = if let aad {
            try ChaChaPoly.seal(plaintext, using: key, nonce: n, authenticating: aad)
        } else {
            try ChaChaPoly.seal(plaintext, using: key, nonce: n)
        }
        return Data(box.ciphertext) + box.tag // rebased: SealedBox slices don't start at 0
    }

    static func open(_ sealed: Data, key: SymmetricKey, nonce: Data, aad: Data? = nil) throws -> Data {
        guard sealed.count >= 16 else { throw AirPlayError.protocolError("encrypted data too short") }
        let tagStart = sealed.endIndex - 16
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                           ciphertext: sealed[sealed.startIndex..<tagStart],
                                           tag: sealed[tagStart...])
        if let aad { return try ChaChaPoly.open(box, using: key, authenticating: aad) }
        return try ChaChaPoly.open(box, using: key)
    }

    /// OPACK for a dictionary of short strings (pyatv's opack.pack, just the parts pairing needs).
    static func opack(_ dictionary: KeyValuePairs<String, String>) -> Data {
        func string(_ s: String) -> Data {
            let bytes = Data(s.utf8)
            if bytes.count <= 0x20 { return Data([0x40 + UInt8(bytes.count)]) + bytes }
            return Data([0x61, UInt8(min(bytes.count, 255))]) + bytes.prefix(255)
        }
        var out = Data([0xE0 + UInt8(min(dictionary.count, 14))])
        for (key, value) in dictionary.prefix(14) {
            out.append(string(key))
            out.append(string(value))
        }
        return out
    }
}

// MARK: - HAP framing

/// Encrypts a byte stream the way HAP does (hap_session.HAPSession): frames of up to 1024 bytes,
/// each sent as a 2-byte little-endian length, the ciphertext and a 16-byte tag, with the length
/// as additional data and a per-direction counter as nonce. Not thread-safe: use it on one queue.
final class HAPSession {
    static let frameLength = 1024
    private let outputKey: SymmetricKey
    private let inputKey: SymmetricKey
    private var outputCounter: UInt64 = 0
    private var inputCounter: UInt64 = 0
    private var pending = Data()

    init(outputKey: Data, inputKey: Data) {
        self.outputKey = SymmetricKey(data: outputKey)
        self.inputKey = SymmetricKey(data: inputKey)
    }

    func encrypt(_ data: Data) throws -> Data {
        var out = Data()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + Self.frameLength, data.endIndex)
            var length = Data()
            length.appendLittleEndian(UInt16(end - offset))
            let sealed = try AirPlayCrypto.seal(data[offset..<end], key: outputKey,
                                                nonce: AirPlayCrypto.nonce(counter: outputCounter),
                                                aad: length)
            outputCounter += 1
            out.append(length)
            out.append(sealed)
            offset = end
        }
        return out
    }

    /// Returns whatever whole frames have arrived; keeps a partial frame for next time.
    func decrypt(_ data: Data) throws -> Data {
        pending.append(data)
        var out = Data()
        while pending.count >= 2 {
            let start = pending.startIndex
            let length = Int(pending[start]) | Int(pending[start + 1]) << 8
            let total = 2 + length + 16
            guard pending.count >= total else { break }
            let aad = pending[start..<(start + 2)]
            let sealed = pending[(start + 2)..<(start + total)]
            out.append(try AirPlayCrypto.open(Data(sealed), key: inputKey,
                                              nonce: AirPlayCrypto.nonce(counter: inputCounter),
                                              aad: Data(aad)))
            inputCounter += 1
            pending = Data(pending[(start + total)...])
        }
        return out
    }
}
