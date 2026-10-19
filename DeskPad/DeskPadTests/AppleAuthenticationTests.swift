import Foundation
import Testing
@testable import DeskPad

/// Behavior tests at the public seams for Mac username/password (Apple-DH) login.
///
/// Seams under test:
/// 1. `RFBSecurityType.preferred` — which auth method DeskPad chooses
/// 2. `AppleAuthentication.buildAuthResponse` — packet Mac Screen Sharing accepts
/// 3. `AppleAuthentication.ServerParameters` — parsing the server challenge
///
/// Expected values come from independent worked examples / NIST / Python `cryptography`,
/// not from re-running DeskPad's own helpers.
struct AppleAuthenticationTests {

    // MARK: - Seam: RFBSecurityType.preferred

    @Test func choosesMacAuthWhenUsernameAndPasswordAreProvided() {
        let offered: [RFBSecurityType] = [.plain, .appleAuthentication, .vncAuthentication]
        let selected = RFBSecurityType.preferred(
            from: offered,
            hasUsername: true,
            hasPassword: true
        )
        #expect(selected == .appleAuthentication)
    }

    @Test func choosesMacAuthAltWhenPrimaryAppleTypeIsUnavailable() {
        let offered: [RFBSecurityType] = [.appleAuthenticationAlt, .plain]
        let selected = RFBSecurityType.preferred(
            from: offered,
            hasUsername: true,
            hasPassword: true
        )
        #expect(selected == .appleAuthenticationAlt)
    }

    @Test func choosesVNCPasswordWhenOnlyPasswordIsProvided() {
        let offered: [RFBSecurityType] = [.appleAuthentication, .vncAuthentication, .plain]
        let selected = RFBSecurityType.preferred(
            from: offered,
            hasUsername: false,
            hasPassword: true
        )
        #expect(selected == .vncAuthentication)
    }

    @Test func refusesMacOnlyServerWhenCredentialsAreMissing() {
        let offered: [RFBSecurityType] = [.appleAuthentication, .appleAuthenticationAlt, .appleDiffieHellman]
        let selected = RFBSecurityType.preferred(
            from: offered,
            hasUsername: false,
            hasPassword: false
        )
        #expect(selected == nil)
    }

    @Test func refusesAppleTypesWhenUsernameIsPresentWithoutPassword() {
        // Partial credentials must not silently fall through to Plain (type 35),
        // which Mac Screen Sharing treats as a false success with empty fields.
        let offered: [RFBSecurityType] = [.appleAuthentication, .plain]
        let selected = RFBSecurityType.preferred(
            from: offered,
            hasUsername: true,
            hasPassword: false
        )
        #expect(selected == nil)
    }

    @Test func fallsBackToVNCPasswordWhenAppleIsAbsentButCredentialsExist() {
        let offered: [RFBSecurityType] = [.vncAuthentication, .plain]
        let selected = RFBSecurityType.preferred(
            from: offered,
            hasUsername: true,
            hasPassword: true
        )
        #expect(selected == .vncAuthentication)
    }

    // MARK: - Seam: ServerParameters

    @Test func parsesMacScreenSharingChallengeWireFormat() throws {
        var payload = Data()
        payload.append(contentsOf: [0x00, 0x05]) // generator = 5
        payload.append(contentsOf: [0x00, 0x04]) // keyLength = 4
        payload.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        payload.append(contentsOf: [0x0A, 0x0B, 0x0C, 0x0D])

        let params = try AppleAuthentication.ServerParameters(data: payload)
        #expect(params.generator == Data([0x00, 0x05]))
        #expect(params.keyLength == 4)
        #expect(params.prime == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(params.peerPublicKey == Data([0x0A, 0x0B, 0x0C, 0x0D]))
    }

    @Test func rejectsTruncatedMacChallenge() {
        // Claims keyLength=4 but only provides 2 bytes of prime/peer material.
        let truncated = Data([0x00, 0x05, 0x00, 0x04, 0x01, 0x02])
        #expect(throws: AppleAuthentication.AuthError.invalidParameters) {
            _ = try AppleAuthentication.ServerParameters(data: truncated)
        }
    }

    @Test func rejectsZeroKeyLengthChallenge() {
        let invalid = Data([0x00, 0x05, 0x00, 0x00])
        #expect(throws: AppleAuthentication.AuthError.invalidParameters) {
            _ = try AppleAuthentication.ServerParameters(data: invalid)
        }
    }

    // MARK: - Seam: buildAuthResponse

    @Test func rejectsEmptyMacUsernameOrPassword() {
        let params = tinyDHParameters()
        #expect(throws: AppleAuthentication.AuthError.missingCredentials) {
            _ = try AppleAuthentication.buildAuthResponse(
                parameters: params,
                username: "",
                password: "secret",
                privateKey: Data([0x06]),
                randomFill: { buffer in for i in buffer.indices { buffer[i] = 0x22 } }
            )
        }
        #expect(throws: AppleAuthentication.AuthError.missingCredentials) {
            _ = try AppleAuthentication.buildAuthResponse(
                parameters: params,
                username: "alice",
                password: "",
                privateKey: Data([0x06]),
                randomFill: { buffer in for i in buffer.indices { buffer[i] = 0x22 } }
            )
        }
    }

    @Test func buildsAuthPacketMatchingIndependentAppleDHWorkedExample() throws {
        // Worked example (independent of DeskPad):
        // p=23, g=5, peer=8 (=5^6 mod 23), priv=6
        // clientPublic = 5^6 mod 23 = 8
        // sharedSecret = 8^6 mod 23 = 13
        // AES key = MD5([13])
        // credentials filled with 0x22, username "u", password "p"
        // Expected ciphertext computed with Python cryptography AES-128-ECB.
        let expected = Data(hex:
            "1b57d8a020ffb59f56ba8d69be54b1ba" +
            "3f1f4c31e3db47aa32816772997af952" +
            "3f1f4c31e3db47aa32816772997af952" +
            "3f1f4c31e3db47aa32816772997af952" +
            "ee81666a91e19c446a286f7bbf848883" +
            "3f1f4c31e3db47aa32816772997af952" +
            "3f1f4c31e3db47aa32816772997af952" +
            "3f1f4c31e3db47aa32816772997af952" +
            "08"
        )

        let response = try AppleAuthentication.buildAuthResponse(
            parameters: tinyDHParameters(),
            username: "u",
            password: "p",
            privateKey: Data([0x06]),
            randomFill: { buffer in for i in buffer.indices { buffer[i] = 0x22 } }
        )

        #expect(response == expected)
    }

    @Test func buildsAuthPacketForLargerPrimeMatchingIndependentVector() throws {
        // p=104729 (0x019919), g=2, peer=32 (0x000020), priv=7
        // clientPublic = 2^7 mod 104729 = 128
        // sharedSecret = 32^7 mod 104729 = 38590 → padded 00 96 be
        // AES key = MD5(padded shared) — matches gtk-vnc / neatvnc.
        let params = AppleAuthentication.ServerParameters(
            generator: Data([0x00, 0x02]),
            keyLength: 3,
            prime: Data([0x01, 0x99, 0x19]),
            peerPublicKey: Data([0x00, 0x00, 0x20])
        )
        let expected = Data(hex:
            "9388808fdd69f19d4fdaffac569edb98" +
            "9acfa88c3c7e55c7a1387a666d32d71d" +
            "9acfa88c3c7e55c7a1387a666d32d71d" +
            "9acfa88c3c7e55c7a1387a666d32d71d" +
            "847d3af86fe02e83f71ac548760afc94" +
            "9acfa88c3c7e55c7a1387a666d32d71d" +
            "9acfa88c3c7e55c7a1387a666d32d71d" +
            "9acfa88c3c7e55c7a1387a666d32d71d" +
            "000080"
        )

        let response = try AppleAuthentication.buildAuthResponse(
            parameters: params,
            username: "alice",
            password: "secret",
            privateKey: Data([0x00, 0x00, 0x07]),
            randomFill: { buffer in for i in buffer.indices { buffer[i] = 0x44 } }
        )

        #expect(response == expected)
    }

    @Test func modPowMatchesIndependent512BitDiffieHellmanVector() {
        let prime = Data(hex:
            "aafb8ba347ce57d712518f83ee885b17b8002794fe3ed7bb38478fafaf5158ce" +
            "c09e156bad1ef9d790acc9f9e6455693c0da9bb40ba2e577e41ea5efc9c6b55f"
        )
        let privateKey = Data(hex:
            "0000000000000000000000000000000000000000000000000000000000000000" +
            "000000000000000000000000000000000000000000000000ab54a98ceb1f0ad2"
        )
        let expectedPublic = Data(hex:
            "1fb9dcfd3a91b848d838c21e2cee4c3de4f92cb3d131e20c1577efafbac7aa3b" +
            "c6e98f0d5747a7cff063cc52d75c422bb058c6d787bf2d48394ccb516b48fe25"
        )

        let publicKey = AppleAuthentication.modPow(
            base: Data([0x00, 0x02]),
            exponent: privateKey,
            modulus: prime,
            length: 64
        )
        #expect(publicKey == expectedPublic)
    }

    @Test func encryptsUTF8MacAccountNamesInsideAuthPacket() throws {
        // Same tiny DH group; username "한글", password "비번" (UTF-8).
        let expectedCiphertext = Data(hex:
            "2ced863365db19cd6beefdd9995b6b27" +
            "0d13e94d3d35b527efd57ddd25832a25" +
            "0d13e94d3d35b527efd57ddd25832a25" +
            "0d13e94d3d35b527efd57ddd25832a25" +
            "7eefdd10f31dd19ed510b7534f6dc535" +
            "0d13e94d3d35b527efd57ddd25832a25" +
            "0d13e94d3d35b527efd57ddd25832a25" +
            "0d13e94d3d35b527efd57ddd25832a25"
        )

        let response = try AppleAuthentication.buildAuthResponse(
            parameters: tinyDHParameters(),
            username: "한글",
            password: "비번",
            privateKey: Data([0x06]),
            randomFill: { buffer in for i in buffer.indices { buffer[i] = 0x33 } }
        )

        #expect(response.prefix(128) == expectedCiphertext)
        #expect(response.suffix(1) == Data([0x08]))
    }

    @Test func truncatesOverlongCredentialsTo63BytesPerFieldInAuthPacket() throws {
        let longUser = String(repeating: "u", count: 80)
        let longPass = String(repeating: "p", count: 80)
        let expectedCiphertext = Data(hex:
            "dd4ef8219d813205cb83a943aa195d5d" +
            "dd4ef8219d813205cb83a943aa195d5d" +
            "dd4ef8219d813205cb83a943aa195d5d" +
            "a4699bb0b062a6ff1c2527bfb031ee71" +
            "babe7d2c122aaa261e830d50ec68e04b" +
            "babe7d2c122aaa261e830d50ec68e04b" +
            "babe7d2c122aaa261e830d50ec68e04b" +
            "9267550548a871f6ce854ce75163e36f"
        )

        let response = try AppleAuthentication.buildAuthResponse(
            parameters: tinyDHParameters(),
            username: longUser,
            password: longPass,
            privateKey: Data([0x06]),
            randomFill: { buffer in for i in buffer.indices { buffer[i] = 0x11 } }
        )

        #expect(response.prefix(128) == expectedCiphertext)
    }

    @Test func authPacketLengthIsAlwaysCiphertextPlusPublicKey() throws {
        let response = try AppleAuthentication.buildAuthResponse(
            parameters: tinyDHParameters(),
            username: "bob",
            password: "hunter2",
            privateKey: Data([0x06]),
            randomFill: { buffer in for i in buffer.indices { buffer[i] = 0x00 } }
        )
        #expect(response.count == 128 + 1)
    }
}

// MARK: - Fixtures

private func tinyDHParameters() -> AppleAuthentication.ServerParameters {
    AppleAuthentication.ServerParameters(
        generator: Data([0x00, 0x05]),
        keyLength: 1,
        prime: Data([0x17]),
        peerPublicKey: Data([0x08])
    )
}

private extension Data {
    init(hex: String) {
        let normalized = hex.replacingOccurrences(of: " ", with: "")
        var bytes: [UInt8] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            bytes.append(UInt8(normalized[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
