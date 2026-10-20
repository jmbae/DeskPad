import Foundation
import Security
import CommonCrypto

/// Experimental Apple RSA1 authentication. This negotiates credentials only;
/// a successful result is not evidence that the host supports media streaming.
enum AppleHPAuthentication {
    enum Failure: Error, Equatable {
        case unsupportedServer, invalidCredential, malformedResponse, unsupportedKey
        case randomFailed, encryptionFailed, rejected(UInt32)
    }

    typealias Read = (Int) async throws -> Data
    typealias Write = (Data) async throws -> Void

    static func supportsRSA1(serverVersion: String, securityTypes: [UInt8]) -> Bool {
        serverVersion == "RFB 003.889\n" && securityTypes.contains(33)
    }

    /// Includes the security-type selector. Invoke after reading the offered
    /// security list, before sending any selector. verifyKey allows caller-owned
    /// key pinning without retaining credentials or keys in this helper.
    static func authenticate(
        username: String, password: String,
        read: Read, write: Write,
        verifyKey: (Data) async throws -> Void
    ) async throws -> Data {
        try validateCredential(username)
        try validateCredential(password)
        try await write(Data([33, 0, 0, 0, 10, 1, 0, 82, 83, 65, 49, 0, 0, 0, 0]))
        let sizeData = try await exact(4, read)
        let size = Int(uint32(sizeData))
        guard (7...8192).contains(size) else { throw Failure.malformedResponse }
        let response = try await exact(size, read)
        let der = try publicKeyDER(response)
        let key = try importRSA(der)
        try await verifyKey(der)
        let wrappingKey = try random(16)
        let credentialData = try credentialSlot(username) + credentialSlot(password)
        let ciphertext = try encryptCredentials(credentialData, key: wrappingKey)
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, wrappingKey as CFData, &error) as Data? else {
            throw Failure.encryptionFailed
        }
        var body = Data([1, 0, 82, 83, 65, 49, 0, 1])
        body.append(ciphertext)
        body.append(contentsOf: [0, 1])
        body.append(wrapped)
        var packet = bigEndian(UInt32(body.count))
        packet.append(body)
        try await write(packet)
        // The non-SRP branch carries a four-byte proof placeholder before RFB SecurityResult.
        let result = try await exact(8, read)
        let status = uint32(Data(result.suffix(4)))
        guard status == 0 else { throw Failure.rejected(status) }
        return wrappingKey
    }

    static func publicKeyDER(_ response: Data) throws -> Data {
        let bytes = [UInt8](response)
        guard bytes.count >= 7, Array(bytes.prefix(2)) == [0, 1] else {
            throw Failure.malformedResponse
        }
        let length = bytes[2..<6].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 8185, bytes.count == length + 7 else {
            throw Failure.malformedResponse
        }
        return Data(bytes[6..<(6 + length)])
    }

    private static func importRSA(_ der: Data) throws -> SecKey {
        // Security.framework imports PKCS#1. Apple sends SubjectPublicKeyInfo;
        // unwrap its RSA algorithm identifier and zero-unused-bits BIT STRING.
        var outer = DERReader(bytes: [UInt8](der))
        let sequence = try outer.take(0x30)
        guard outer.atEnd else { throw Failure.unsupportedKey }
        var contents = DERReader(bytes: sequence)
        let algorithm = try contents.take(0x30)
        guard algorithm == [6, 9, 42, 134, 72, 134, 247, 13, 1, 1, 1, 5, 0] else {
            throw Failure.unsupportedKey
        }
        let bits = try contents.take(3)
        guard contents.atEnd, bits.count > 1, bits[0] == 0 else { throw Failure.unsupportedKey }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(bits.dropFirst()) as CFData, attributes as CFDictionary, &error),
              (256...512).contains(SecKeyGetBlockSize(key)),
              SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1) else {
            throw Failure.unsupportedKey
        }
        return key
    }

    private struct DERReader {
        let bytes: [UInt8]
        var offset = 0
        var atEnd: Bool { offset == bytes.count }
        mutating func take(_ tag: UInt8) throws -> [UInt8] {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw Failure.unsupportedKey }
            offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 {
                let count = length & 127
                guard (1...2).contains(count), offset + count <= bytes.count, bytes[offset] != 0 else { throw Failure.unsupportedKey }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[offset]); offset += 1 }
                guard length >= 128 else { throw Failure.unsupportedKey }
            }
            guard length <= bytes.count - offset else { throw Failure.unsupportedKey }
            let result = Array(bytes[offset..<(offset + length)]); offset += length
            return result
        }
    }

    private static func validateCredential(_ value: String) throws {
        guard !value.utf8.contains(0), value.utf8.count <= 63 else { throw Failure.invalidCredential }
    }

    private static func credentialSlot(_ value: String) throws -> Data {
        var result = Data(value.utf8)
        result.append(0)
        result.append(try random(64 - result.count))
        return result
    }

    private static func random(_ count: Int) throws -> Data {
        if count == 0 { return Data() }
        var result = Data(count: count)
        let status = result.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.randomFailed }
        return result
    }

    private static func encryptCredentials(_ input: Data, key: Data) throws -> Data {
        var output = Data(count: input.count)
        var written = 0
        let status = output.withUnsafeMutableBytes { target in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { secret in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            secret.baseAddress, key.count, nil, source.baseAddress, input.count,
                            target.baseAddress, input.count, &written)
                }
            }
        }
        guard status == kCCSuccess, written == input.count else { throw Failure.encryptionFailed }
        return output
    }

    private static func exact(_ size: Int, _ read: Read) async throws -> Data {
        let data = try await read(size)
        guard data.count == size else { throw Failure.malformedResponse }
        return data
    }
    private static func uint32(_ data: Data) -> UInt32 { data.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func bigEndian(_ number: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: number >> 24), UInt8(truncatingIfNeeded: number >> 16), UInt8(truncatingIfNeeded: number >> 8), UInt8(truncatingIfNeeded: number)])
    }
}
