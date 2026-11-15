// AirPlay audio sender for Soundcheck.
//
// SRP-6a client (3072-bit group, SHA-512) as used by HomeKit pairing. It reproduces what pyatv
// gets from srptools (pyatv/auth/hap_srp.py + srptools' SRPContext/SRPClientSession), including
// which values are padded and which are hashed as minimal big-endian bytes.
// pyatv: https://github.com/postlund/pyatv, MIT License, © Pierre Ståhl.

import CryptoKit
import Foundation

// MARK: - Big unsigned integers (only what SRP needs)

/// An unsigned big integer: little-endian 64-bit limbs, no high zero limbs.
struct BigUInt: Comparable, Sendable {
    private(set) var limbs: [UInt64]

    init(_ value: UInt64 = 0) { limbs = value == 0 ? [] : [value] }

    init(limbs: [UInt64]) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    /// From big-endian bytes.
    init<Bytes: Collection>(bytes: Bytes) where Bytes.Element == UInt8 {
        var limbs: [UInt64] = []
        var current: UInt64 = 0
        var shift: UInt64 = 0
        for byte in bytes.reversed() {
            current |= UInt64(byte) << shift
            shift += 8
            if shift == 64 {
                limbs.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 { limbs.append(current) }
        self.init(limbs: limbs)
    }

    init?(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        if digits.count % 2 == 1 {
            guard let byte = UInt8(String(digits[index]), radix: 16) else { return nil }
            bytes.append(byte)
            index = digits.index(after: index)
        }
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes: bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    /// Minimal big-endian bytes (srptools' `int_to_bytes`).
    var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 8)
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        if let first = out.firstIndex(where: { $0 != 0 }) { return Array(out[first...]) }
        return []
    }

    /// Big-endian bytes left-padded with zeros (srptools' `pad`).
    func bytes(paddedTo length: Int) -> [UInt8] {
        let raw = bytes
        return raw.count >= length ? raw : [UInt8](repeating: 0, count: length - raw.count) + raw
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool { compare(lhs.limbs, rhs.limbs) < 0 }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var out = [UInt64](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let a = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (s1, o1) = a.addingReportingOverflow(b)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        out[count] = carry
        return BigUInt(limbs: out)
    }

    /// `lhs - rhs`; requires `lhs >= rhs`.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(!(lhs < rhs), "BigUInt subtraction underflow")
        var out = lhs.limbs
        subtract(&out, rhs.limbs)
        return BigUInt(limbs: out)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt() }
        var out = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let a = lhs.limbs[i]
            for j in 0..<rhs.limbs.count {
                let (hi, lo) = a.multipliedFullWidth(by: rhs.limbs[j])
                let (s1, o1) = out[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                out[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            out[i + rhs.limbs.count] = carry
        }
        return BigUInt(limbs: out)
    }

    /// Compares limb arrays of any length (high zero limbs allowed).
    static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        let count = max(a.count, b.count)
        var i = count - 1
        while i >= 0 {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    /// `a -= b` in place, ignoring a final borrow.
    static func subtract(_ a: inout [UInt64], _ b: [UInt64]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let y = i < b.count ? b[i] : 0
            let (d1, o1) = a[i].subtractingReportingOverflow(y)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            a[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
    }
}

/// Montgomery arithmetic modulo a fixed odd modulus (CIOS multiplication).
struct Montgomery: Sendable {
    let modulus: BigUInt
    private let n: [UInt64]
    private let count: Int
    private let n0inv: UInt64
    private let rSquared: [UInt64]

    init(modulus: BigUInt) {
        precondition(modulus.bit(0), "Montgomery needs an odd modulus")
        self.modulus = modulus
        n = modulus.limbs
        count = n.count
        // -n^-1 mod 2^64 by Newton iteration.
        var inverse: UInt64 = 1
        for _ in 0..<6 { inverse = inverse &* (2 &- n[0] &* inverse) }
        n0inv = 0 &- inverse
        // R^2 mod n, R = 2^(64·count), by doubling 1 that many times (2·64·count doublings).
        var value = [UInt64](repeating: 0, count: count)
        value[0] = 1
        for _ in 0..<(2 * 64 * count) {
            var carry: UInt64 = 0
            for i in 0..<count {
                let next = value[i] >> 63
                value[i] = value[i] << 1 | carry
                carry = next
            }
            if carry != 0 || BigUInt.compare(value, n) >= 0 { BigUInt.subtract(&value, n) }
        }
        rSquared = value
    }

    private func padded(_ x: BigUInt) -> [UInt64] {
        var limbs = x.limbs
        precondition(limbs.count <= count, "value too large for Montgomery form")
        limbs.append(contentsOf: repeatElement(0, count: count - limbs.count))
        return limbs
    }

    /// a·b·R⁻¹ mod n, for a < R and b < n (or both < n).
    private func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let s = count
        var t = [UInt64](repeating: 0, count: s + 2)
        a.withUnsafeBufferPointer { a in
        n.withUnsafeBufferPointer { n in
        t.withUnsafeMutableBufferPointer { t in
            for i in 0..<s {
                var c: UInt64 = 0
                let bi = b[i]
                for j in 0..<s {
                    let (hi, lo) = a[j].multipliedFullWidth(by: bi)
                    let (s1, o1) = t[j].addingReportingOverflow(lo)
                    let (s2, o2) = s1.addingReportingOverflow(c)
                    t[j] = s2
                    c = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
                }
                let (ts, to) = t[s].addingReportingOverflow(c)
                t[s] = ts
                t[s + 1] = to ? 1 : 0

                let m = t[0] &* n0inv
                let (hi0, lo0) = m.multipliedFullWidth(by: n[0])
                let (_, o0) = t[0].addingReportingOverflow(lo0)
                c = hi0 &+ (o0 ? 1 : 0)
                for j in 1..<s {
                    let (hi, lo) = m.multipliedFullWidth(by: n[j])
                    let (s1, o1) = t[j].addingReportingOverflow(lo)
                    let (s2, o2) = s1.addingReportingOverflow(c)
                    t[j - 1] = s2
                    c = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
                }
                let (ts2, to2) = t[s].addingReportingOverflow(c)
                t[s - 1] = ts2
                t[s] = t[s + 1] &+ (to2 ? 1 : 0)
            }
        }
        }
        }
        var result = Array(t[0..<s])
        if t[s] != 0 || BigUInt.compare(result, n) >= 0 { BigUInt.subtract(&result, n) }
        return result
    }

    private func toMontgomery(_ x: BigUInt) -> [UInt64] { multiply(padded(x), rSquared) }

    private func fromMontgomery(_ x: [UInt64]) -> BigUInt {
        var one = [UInt64](repeating: 0, count: count)
        one[0] = 1
        return BigUInt(limbs: multiply(x, one))
    }

    /// x mod n, for any x below 2^(64·count).
    func reduce(_ x: BigUInt) -> BigUInt { fromMontgomery(toMontgomery(x)) }

    /// a·b mod n.
    func multiply(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        fromMontgomery(multiply(toMontgomery(reduce(a)), toMontgomery(reduce(b))))
    }

    /// base^exponent mod n (left-to-right square and multiply).
    func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        let b = toMontgomery(reduce(base))
        var acc = toMontgomery(BigUInt(1))
        var i = exponent.bitWidth - 1
        while i >= 0 {
            acc = multiply(acc, acc)
            if exponent.bit(i) { acc = multiply(acc, b) }
            i -= 1
        }
        return fromMontgomery(acc)
    }
}

// MARK: - SRP-6a client

/// The client half of SRP-6a with the RFC 5054 3072-bit group and SHA-512, as HomeKit pairing
/// (and therefore AirPlay pairing) uses it. Values are hashed exactly as srptools hashes them.
struct AirPlaySRPClient: Sendable {
    static let prime = BigUInt(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6\
        3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245\
        E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411\
        7C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
        83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08\
        CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9\
        DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D\
        04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D8760273\
        3EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB31\
        43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """)!
    static let generator = BigUInt(5)
    static let group = Montgomery(modulus: prime)
    static let username = "Pair-Setup"

    struct Result: Sendable {
        /// A, the client's public value (minimal big-endian bytes).
        let publicKey: Data
        /// M1, the client's proof.
        let proof: Data
        /// K = H(S), the shared session key (64 bytes).
        let sessionKey: Data
        /// M2 = H(A | M1 | K), what the server's proof should be.
        let expectedServerProof: Data
    }

    private let password: String
    private let privateKey: BigUInt
    /// A = g^a mod N.
    let publicKey: BigUInt

    /// `password` is the PIN as a string (e.g. "3939" for transient pairing).
    init(password: String, privateKey: [UInt8]? = nil) {
        self.password = password
        // pyatv seeds srptools with 32 random bytes (it reuses its Ed25519 seed); any random
        // 256-bit value works the same.
        let a = privateKey ?? (0..<32).map { _ in UInt8.random(in: 0...255) }
        self.privateKey = BigUInt(bytes: a)
        publicKey = Self.group.power(Self.generator, self.privateKey)
    }

    private static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var sha = SHA512()
        for part in parts { sha.update(data: part) }
        return Array(sha.finalize())
    }

    /// srptools turns integer-valued hashes back into bytes without their leading zero bytes.
    private static func minimal(_ bytes: [UInt8]) -> [UInt8] {
        guard let first = bytes.firstIndex(where: { $0 != 0 }) else { return [] }
        return Array(bytes[first...])
    }

    func process(serverPublicKey: Data, salt: Data) throws -> Result {
        let N = Self.prime
        let g = Self.generator
        let padLength = N.bytes.count
        let B = BigUInt(bytes: serverPublicKey)
        guard !Self.group.reduce(B).isZero else {
            throw AirPlayError.authenticationFailed("the speaker sent an invalid SRP public key")
        }
        let saltBytes = [UInt8](salt)

        // k = H(N | PAD(g))
        let k = BigUInt(bytes: Self.hash(N.bytes, g.bytes(paddedTo: padLength)))
        // u = H(PAD(A) | PAD(B))
        let u = BigUInt(bytes: Self.hash(publicKey.bytes(paddedTo: padLength), B.bytes(paddedTo: padLength)))
        // x = H(s | H(I | ":" | P))
        let inner = Self.hash(Array("\(Self.username):\(password)".utf8))
        let x = BigUInt(bytes: Self.hash(saltBytes, inner))
        // S = (B - k·g^x) ^ (a + u·x) mod N
        let v = Self.group.power(g, x)
        let kv = Self.group.multiply(k, v)
        let b = Self.group.reduce(B)
        let base = kv < b || kv == b ? b - kv : (b + N) - kv
        let S = Self.group.power(base, privateKey + u * x)
        // K = H(S)
        let K = Self.hash(S.bytes)
        // M1 = H(H(N) xor H(g) | H(I) | s | A | B | K)
        let hN = Self.hash(N.bytes)
        let hg = Self.hash(g.bytes)
        let xor = zip(hN, hg).map { $0 ^ $1 }
        let hI = Self.hash(Array(Self.username.utf8))
        let M1 = Self.hash(Self.minimal(xor), Self.minimal(hI), saltBytes, publicKey.bytes, B.bytes, K)
        // M2 = H(A | M1 | K)
        let M2 = Self.hash(publicKey.bytes, M1, K)
        return Result(publicKey: Data(publicKey.bytes), proof: Data(M1), sessionKey: Data(K),
                      expectedServerProof: Data(M2))
    }
}
