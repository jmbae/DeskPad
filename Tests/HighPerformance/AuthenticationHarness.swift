import Foundation
import Security
import CommonCrypto

@main struct AuthenticationHarness {
    static func assertThrows(_ expected: AppleHPAuthentication.Failure, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected failure") }
        catch { precondition(error as? AppleHPAuthentication.Failure == expected, "Unexpected failure: \(error)") }
    }
    static func tlv(_ tag: UInt8, _ bytes: Data) -> Data {
        let size = bytes.count
        let length: [UInt8] = size < 128 ? [UInt8(size)] : [0x82, UInt8(size >> 8), UInt8(size & 255)]
        return Data([tag] + length) + bytes
    }
    static func main() async throws {
        precondition(AppleHPAuthentication.supportsRSA1(serverVersion: "RFB 003.889\n", securityTypes: [30, 33]))
        precondition(!AppleHPAuthentication.supportsRSA1(serverVersion: "RFB 003.008\n", securityTypes: [33]))
        precondition(!AppleHPAuthentication.supportsRSA1(serverVersion: "RFB 003.889\n", securityTypes: [30]))
        for response in [Data(), Data([1,0,0,0,0,2,1,0]), Data([1,0,0,0,0,1,1,1])] {
            await assertThrows(.malformedResponse) { _ = try AppleHPAuthentication.publicKeyDER(response) }
        }
        for credential in [String(repeating: "a", count: 64), "a\0b", String(repeating: "한", count: 22)] {
            await assertThrows(.invalidCredential) {
                _ = try await AppleHPAuthentication.authenticate(username: credential, password: "x", read: { _ in fatalError() }, write: { _ in fatalError() }, verifyKey: { _ in fatalError() })
            }
        }
        await assertThrows(.malformedResponse) {
            _ = try await AppleHPAuthentication.authenticate(username: "x", password: "y", read: { _ in Data([0xff,0xff,0xff,0xff]) }, write: { _ in }, verifyKey: { _ in })
        }
        var error: Unmanaged<CFError>?
        let privateKey = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error)!
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error)! as Data
        let algorithm = Data([0x30,13,6,9,42,134,72,134,247,13,1,1,1,5,0])
        let spki = tlv(0x30, algorithm + tlv(3, Data([0]) + pkcs1))
        let response = Data([0,1,0,0,UInt8(spki.count >> 8),UInt8(spki.count & 255)]) + spki + Data([1])
        let size = response.count
        let prefix = Data([0,0,UInt8(size >> 8),UInt8(size & 255)])
        var reads = [prefix, response, Data(repeating: 0, count: 8)]
        var writes: [Data] = []
        var verified = false
        let secret = try await AppleHPAuthentication.authenticate(username: String(repeating: "u", count: 63), password: "한글", read: { count in
            let next = reads.removeFirst(); precondition(next.count == count); return next
        }, write: { writes.append($0) }, verifyKey: { key in precondition(key == spki); verified = true })
        precondition(verified && reads.isEmpty && writes.count == 2)
        precondition(writes[0] == Data([33,0,0,0,10,1,0,82,83,65,49,0,0,0,0]))
        let auth = writes[1]
        precondition(auth.count == 398 && auth.prefix(4) == Data([0,0,1,138]))
        precondition(auth[140..<142] == Data([0,1]))
        let recovered = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, Data(auth.suffix(256)) as CFData, &error)! as Data
        precondition(recovered == secret && secret.count == 16)
        let cipher = Data(auth[12..<140])
        var plain = Data(count: 128); var written = 0
        let status = plain.withUnsafeMutableBytes { target in cipher.withUnsafeBytes { input in secret.withUnsafeBytes { key in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key.baseAddress, 16, nil, input.baseAddress, 128, target.baseAddress, 128, &written)
        } } }
        precondition(status == kCCSuccess && written == 128)
        precondition(plain.prefix(64) == Data(String(repeating: "u", count: 63).utf8) + Data([0]))
        precondition(plain[64..<71] == Data("한글".utf8) + Data([0]))
        reads = [prefix, response, Data([0,0,0,0,0,0,0,1])]
        await assertThrows(.rejected(1)) {
            _ = try await AppleHPAuthentication.authenticate(username: "x", password: "y", read: { _ in reads.removeFirst() }, write: { _ in }, verifyKey: { _ in })
        }
        print("PASS: RSA1 capability, bounds, UTF-8 credentials, SPKI, encrypted transcript, key recovery and rejection")
    }
}
