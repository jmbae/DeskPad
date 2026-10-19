import Foundation
import CommonCrypto
import CryptoKit
import Security

/// Apple Remote Desktop / Mac Screen Sharing authentication (RFB security type 30).
///
/// Protocol:
/// 1. Server sends: generator(2) + keyLength(2) + prime[keyLength] + peerPublicKey[keyLength]
/// 2. Client performs Diffie-Hellman, MD5(sharedSecret) → AES-128 key
/// 3. Client sends: AES-ECB(credentials[128]) + clientPublicKey[keyLength]
///    credentials = username[64] + password[64], each null-terminated
enum AppleAuthentication {

    struct ServerParameters {
        let generator: Data
        let keyLength: Int
        let prime: Data
        let peerPublicKey: Data

        init(generator: Data, keyLength: Int, prime: Data, peerPublicKey: Data) {
            self.generator = generator
            self.keyLength = keyLength
            self.prime = prime
            self.peerPublicKey = peerPublicKey
        }

        init(data: Data) throws {
            guard data.count >= 4 else { throw AuthError.invalidParameters }
            let keyLength = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
            guard keyLength > 0, data.count >= 4 + keyLength * 2 else {
                throw AuthError.invalidParameters
            }
            let genStart = data.startIndex
            let primeStart = genStart + 4
            let peerStart = primeStart + keyLength
            self.generator = data[genStart..<(genStart + 2)]
            self.keyLength = keyLength
            self.prime = data[primeStart..<peerStart]
            self.peerPublicKey = data[peerStart..<(peerStart + keyLength)]
        }
    }

    enum AuthError: Error {
        case invalidParameters
        case missingCredentials
        case cryptographyFailed
    }

    // MARK: - Public API

    static func buildAuthResponse(
        parameters: ServerParameters,
        username: String,
        password: String,
        privateKey: Data? = nil,
        randomFill: ((inout [UInt8]) -> Void)? = nil
    ) throws -> Data {
        guard !username.isEmpty, !password.isEmpty else {
            throw AuthError.missingCredentials
        }

        let keyLength = parameters.keyLength
        let priv = try privateKey ?? randomPrivateKey(length: keyLength, lessThan: parameters.prime)
        let clientPublicKey = modPow(
            base: parameters.generator,
            exponent: priv,
            modulus: parameters.prime,
            length: keyLength
        )
        // Shared secret must be left-padded to keyLength before MD5.
        // gtk-vnc / neatvnc / Java ARD clients all hash the fixed-width buffer.
        let sharedSecret = modPow(
            base: parameters.peerPublicKey,
            exponent: priv,
            modulus: parameters.prime,
            length: keyLength
        )
        let aesKey = md5(sharedSecret)

        let credentials = packCredentials(
            username: username,
            password: password,
            randomFill: randomFill
        )
        let ciphertext = aes128ECB(key: aesKey, plaintext: Data(credentials))
        guard ciphertext.count == 128 else { throw AuthError.cryptographyFailed }

        var response = Data()
        response.append(ciphertext)
        response.append(clientPublicKey)
        return response
    }

    static func packCredentials(
        username: String,
        password: String,
        randomFill: ((inout [UInt8]) -> Void)? = nil
    ) -> [UInt8] {
        var credentials = [UInt8](repeating: 0, count: 128)
        if let randomFill {
            randomFill(&credentials)
        } else {
            _ = SecRandomCopyBytes(kSecRandomDefault, credentials.count, &credentials)
        }

        let userBytes = Array(username.utf8.prefix(63))
        let passBytes = Array(password.utf8.prefix(63))
        for (index, byte) in userBytes.enumerated() {
            credentials[index] = byte
        }
        credentials[userBytes.count] = 0
        for (index, byte) in passBytes.enumerated() {
            credentials[64 + index] = byte
        }
        credentials[64 + passBytes.count] = 0
        return credentials
    }

    // MARK: - Crypto primitives

    static func modPow(base: Data, exponent: Data, modulus: Data, length: Int) -> Data {
        let result = BigEndianUInt(base).modPow(
            exponent: BigEndianUInt(exponent),
            modulus: BigEndianUInt(modulus)
        )
        return result.padded(to: length)
    }

    static func aes128ECB(key: Data, plaintext: Data) -> Data {
        var output = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var numBytesEncrypted = 0
        let status = key.withUnsafeBytes { keyPtr in
            plaintext.withUnsafeBytes { dataPtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, kCCKeySizeAES128,
                    nil,
                    dataPtr.baseAddress, plaintext.count,
                    &output, output.count,
                    &numBytesEncrypted
                )
            }
        }
        guard status == kCCSuccess else { return Data() }
        return Data(output.prefix(numBytesEncrypted))
    }

    static func md5(_ data: Data) -> Data {
        // ARD protocol requires MD5; CryptoKit exposes it under Insecure for this use.
        Data(Insecure.MD5.hash(data: data))
    }

    // MARK: - Helpers

    private static func randomPrivateKey(length: Int, lessThan prime: Data) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        for _ in 0..<32 {
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { throw AuthError.cryptographyFailed }
            // Keep 1 < priv < prime
            bytes[0] &= 0x7F
            if bytes.allSatisfy({ $0 == 0 }) { continue }
            let candidate = Data(bytes)
            if BigEndianUInt(candidate) < BigEndianUInt(prime) {
                return candidate
            }
        }
        throw AuthError.cryptographyFailed
    }
}

// MARK: - Minimal big-endian unsigned integer for DH

private struct BigEndianUInt: Comparable {
    /// Little-endian limbs for arithmetic; value is Σ limbs[i] * 2^(64i)
    private var limbs: [UInt64]

    init(_ data: Data) {
        var bytes = Array(data)
        while bytes.first == 0, bytes.count > 1 {
            bytes.removeFirst()
        }
        if bytes.isEmpty {
            limbs = [0]
            return
        }
        // Convert big-endian bytes to little-endian 64-bit limbs
        var result: [UInt64] = []
        var index = bytes.count
        while index > 0 {
            let start = max(0, index - 8)
            var limb: UInt64 = 0
            for byte in bytes[start..<index] {
                limb = (limb << 8) | UInt64(byte)
            }
            result.append(limb)
            index = start
        }
        limbs = result
        normalize()
    }

    private init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    static func < (lhs: BigEndianUInt, rhs: BigEndianUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] < rhs.limbs[i]
            }
        }
        return false
    }

    static func == (lhs: BigEndianUInt, rhs: BigEndianUInt) -> Bool {
        lhs.limbs == rhs.limbs
    }

    func padded(to length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        var offset = length
        for limb in limbs {
            var value = limb
            for _ in 0..<8 {
                guard offset > 0 else { break }
                offset -= 1
                bytes[offset] = UInt8(value & 0xFF)
                value >>= 8
            }
        }
        return Data(bytes)
    }

    func modPow(exponent: BigEndianUInt, modulus: BigEndianUInt) -> BigEndianUInt {
        precondition(!(modulus.limbs.count == 1 && modulus.limbs[0] == 0))
        var result = BigEndianUInt(limbs: [1])
        var base = self % modulus
        var exp = exponent

        while !(exp.limbs.count == 1 && exp.limbs[0] == 0) {
            if exp.limbs[0] & 1 == 1 {
                result = (result * base) % modulus
            }
            base = (base * base) % modulus
            exp = exp.shiftedRightByOne()
        }
        return result
    }

    private func shiftedRightByOne() -> BigEndianUInt {
        var result = [UInt64](repeating: 0, count: limbs.count)
        var carry: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let value = limbs[i]
            result[i] = (value >> 1) | (carry << 63)
            carry = value & 1
        }
        return BigEndianUInt(limbs: result)
    }

    private mutating func normalize() {
        while limbs.last == 0, limbs.count > 1 {
            limbs.removeLast()
        }
        if limbs.isEmpty {
            limbs = [0]
        }
    }

    static func * (lhs: BigEndianUInt, rhs: BigEndianUInt) -> BigEndianUInt {
        if (lhs.limbs.count == 1 && lhs.limbs[0] == 0) || (rhs.limbs.count == 1 && rhs.limbs[0] == 0) {
            return BigEndianUInt(limbs: [0])
        }
        var result = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt128 = 0
            for j in 0..<rhs.limbs.count {
                carry += UInt128(result[i + j])
                    + UInt128(lhs.limbs[i]) * UInt128(rhs.limbs[j])
                result[i + j] = UInt64(carry & 0xFFFF_FFFF_FFFF_FFFF)
                carry >>= 64
            }
            result[i + rhs.limbs.count] = UInt64(carry)
        }
        return BigEndianUInt(limbs: result)
    }

    static func % (lhs: BigEndianUInt, rhs: BigEndianUInt) -> BigEndianUInt {
        precondition(!(rhs.limbs.count == 1 && rhs.limbs[0] == 0))
        if lhs < rhs { return lhs }
        if lhs == rhs { return BigEndianUInt(limbs: [0]) }

        var remainder = lhs
        let shift = lhs.bitWidth - rhs.bitWidth
        if shift > 0 {
            var divisor = rhs.shiftedLeft(by: shift)
            for s in stride(from: shift, through: 0, by: -1) {
                if remainder >= divisor {
                    remainder = remainder.subtracting(divisor)
                }
                if s > 0 {
                    divisor = divisor.shiftedRightByOne()
                }
            }
        } else {
            while remainder >= rhs {
                remainder = remainder.subtracting(rhs)
            }
        }
        return remainder
    }

    private var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - top.leadingZeroBitCount)
    }

    private func shiftedLeft(by bits: Int) -> BigEndianUInt {
        guard bits > 0 else { return self }
        let limbShift = bits / 64
        let bitShift = bits % 64
        var result = [UInt64](repeating: 0, count: limbs.count + limbShift + 1)
        if bitShift == 0 {
            for i in 0..<limbs.count {
                result[i + limbShift] = limbs[i]
            }
        } else {
            var carry: UInt64 = 0
            for i in 0..<limbs.count {
                let value = limbs[i]
                result[i + limbShift] = (value << bitShift) | carry
                carry = value >> (64 - bitShift)
            }
            result[limbs.count + limbShift] = carry
        }
        return BigEndianUInt(limbs: result)
    }

    private func subtracting(_ other: BigEndianUInt) -> BigEndianUInt {
        precondition(self >= other)
        var result = limbs
        var borrow: UInt64 = 0
        for i in 0..<result.count {
            let sub = i < other.limbs.count ? other.limbs[i] : 0
            let (diff1, overflow1) = result[i].subtractingReportingOverflow(sub)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            result[i] = diff2
            borrow = (overflow1 || overflow2) ? 1 : 0
        }
        return BigEndianUInt(limbs: result)
    }
}
