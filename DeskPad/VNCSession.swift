import Foundation
import Network
import Observation
import CryptoKit
import CommonCrypto
import Security

enum VNCConnectionState: Equatable {
    case disconnected
    case connecting
    case handshaking
    case authenticating
    case initializing
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "연결 해제됨"
        case .connecting: "서버 연결 중…"
        case .handshaking: "RFB 협상 중…"
        case .authenticating: "보안 확인 중…"
        case .initializing: "화면 초기화 중…"
        case .connected: "연결됨"
        case .failed(let message): message
        }
    }
}

@Observable
@MainActor
final class VNCSessionModel {
    private(set) var state: VNCConnectionState = .disconnected
    private(set) var framebuffer = Data()
    private(set) var screenWidth = 0
    private(set) var screenHeight = 0
    private(set) var errorDetails: String?

    private(set) var receivedClipboard: String?
    private(set) var clipboardError: String?
    private var generation = UUID()
    private var inputTask: Task<Void, Never>?
    private var client: RFBClient?
    private var sessionTask: Task<Void, Never>?

    func connect(to savedConnection: SavedConnection, password: String? = nil) {
        disconnect()
        let generation = self.generation
        let client = RFBClient(
            host: savedConnection.host,
            port: savedConnection.port,
            username: savedConnection.username,
            password: password,
            model: self,
            generation: generation
        )
        self.client = client
        state = .connecting
        sessionTask = Task { [weak self] in
            do {
                try await client.run()
            } catch is CancellationError {
                // Explicit disconnect already resets the model; input failures retain their error.
            } catch {
                self?.fail(error, generation: generation)
            }
            await client.close()
        }
    }

    isolated deinit {
        sessionTask?.cancel()
        inputTask?.cancel()
        if let client { Task { await client.close() } }
    }

    func disconnect() {
        generation = UUID()
        sessionTask?.cancel()
        sessionTask = nil
        inputTask?.cancel()
        inputTask = nil
        if let client { Task { await client.close() } }
        client = nil
        framebuffer = Data()
        screenWidth = 0
        screenHeight = 0
        errorDetails = nil
        receivedClipboard = nil
        clipboardError = nil
        state = .disconnected
    }

    private func fail(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        reportError(error.localizedDescription)
        errorDetails = String(describing: error)
    }

    func reportError(_ message: String) {
        disconnect()
        state = .failed(message)
        errorDetails = message
    }

    private func enqueueInput(_ operation: @escaping @Sendable (RFBClient) async throws -> Void) {
        guard case .connected = state, let client else { return }
        let generation = self.generation
        let previous = inputTask
        inputTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.generation == generation else { return }
            do { try await operation(client) }
            catch { self?.fail(error, generation: generation) }
        }
    }

    func sendPointer(x: Int, y: Int, buttonMask: UInt8) {
        guard case .connected = state else { return }
        let boundedX = min(max(x, 0), max(screenWidth - 1, 0))
        let boundedY = min(max(y, 0), max(screenHeight - 1, 0))
        enqueueInput { client in
            try await client.sendPointer(x: UInt16(boundedX), y: UInt16(boundedY), buttonMask: buttonMask)
        }
    }

    func sendKey(keysym: UInt32, pressed: Bool) {
        enqueueInput { client in try await client.sendKey(keysym: keysym, pressed: pressed) }
    }

    func sendClipboard(text: String) {
        guard let bytes = text.data(using: .isoLatin1, allowLossyConversion: false), bytes.count <= 1_048_576 else {
            clipboardError = "서버는 Latin-1 클립보드만 지원합니다. Latin-1 문자로 1 MiB 이하의 텍스트를 보내세요."
            return
        }
        clipboardError = nil
        enqueueInput { client in try await client.sendClipboard(bytes: bytes) }
    }

    fileprivate func setState(_ state: VNCConnectionState, generation: UUID) {
        guard self.generation == generation else { return }
        self.state = state
    }

    fileprivate func setScreen(width: Int, height: Int, framebuffer: Data, generation: UUID) {
        guard self.generation == generation else { return }
        state = .initializing
        screenWidth = width
        screenHeight = height
        self.framebuffer = framebuffer
    }

    fileprivate func setFramebuffer(_ framebuffer: Data, generation: UUID) {
        guard self.generation == generation else { return }
        self.framebuffer = framebuffer
        state = .connected
    }

    fileprivate func setClipboard(_ text: String, generation: UUID) {
        guard self.generation == generation else { return }
        receivedClipboard = text
    }

}

private actor RFBClient {
    private enum ClientError: LocalizedError {
        case connection(String)
        case invalidServerMessage(String)
        case unsupportedSecurity([UInt8])
        case passwordRequired
        case usernameRequired
        case invalidCredentialLength
        case authenticationFailed
        case encryptionFailed
        case invalidDHParameters
        case serverRejected(String)
        case invalidScreenSize
        case unsupportedPixelFormat

        var errorDescription: String? {
            switch self {
            case .connection(let message): return "네트워크 연결 오류: \(message)"
            case .invalidServerMessage(let message): return "잘못된 RFB 응답: \(message)"
            case .unsupportedSecurity(let types):
                let offered = types.map(String.init).joined(separator: ", ")
                return "서버가 지원하지 않는 VNC 보안 방식(유형: \(offered))만 제공합니다. Apple 화면 공유 유형 30과 표준 VNC 인증 유형 1·2를 지원합니다."
            case .passwordRequired:
                return "이 VNC 서버는 암호가 필요합니다. 연결 설정에 암호를 입력하세요."
            case .usernameRequired:
                return "Apple 화면 공유 인증에는 Mac 계정 사용자 이름이 필요합니다. 연결 설정에 사용자 이름과 Mac 계정 암호를 입력하세요."
            case .invalidCredentialLength:
                return "Mac 계정 사용자 이름과 암호는 각각 UTF-8 기준 63바이트 이하이며 NUL 문자를 포함하지 않아야 합니다."
            case .authenticationFailed:
                return "화면 공유 인증에 실패했습니다. Mac 계정 사용자 이름과 암호를 확인하세요."
            case .encryptionFailed:
                return "Apple 화면 공유 인증 응답을 생성하지 못했습니다."
            case .invalidDHParameters:
                return "서버가 잘못된 Apple Diffie–Hellman 인증 데이터를 보냈습니다."
            case .serverRejected(let reason): return "서버가 연결을 거부했습니다: \(reason)"
            case .invalidScreenSize: return "서버가 허용 범위를 벗어난 화면 크기를 보냈습니다."
            case .unsupportedPixelFormat: return "서버 픽셀 형식 협상에 실패했습니다."
            }
        }
    }

    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String?
    private weak var model: VNCSessionModel?
    private let generation: UUID
    private var hasFrame = false
    private var firstFrameTimeout: Task<Void, Never>?
    private let queue = DispatchQueue(label: "DeskPad.RFBTransport")
    private var connection: NWConnection?
    private var pixels = Data()
    private var width = 0
    private var height = 0
    private let maximumDimension = 8192
    private let maximumPixels = 32_000_000
    private let responseTimeout: DispatchTimeInterval = .seconds(20)

    init(host: String, port: UInt16, username: String, password: String?, model: VNCSessionModel, generation: UUID) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.model = model
        self.generation = generation
    }

    func run() async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ClientError.connection("포트 번호가 올바르지 않습니다.")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        self.connection = connection
        try await start(connection)

        await model?.setState(.handshaking, generation: generation)
        let serverVersion = try await readExactly(12)
        guard serverVersion.starts(with: Data("RFB ".utf8)),
              serverVersion.suffix(1) == Data([10]),
              let serverVersionString = String(data: serverVersion, encoding: .ascii),
              let serverMinor = UInt16(serverVersionString.dropFirst(8).prefix(3)),
              serverVersionString.dropFirst(4).prefix(3) == "003",
              serverMinor >= 3 else {
            throw ClientError.invalidServerMessage("버전 문자열이 올바르지 않습니다.")
        }
        let negotiatedMinor: UInt16 = serverMinor >= 8 ? 8 : (serverMinor >= 7 ? 7 : 3)
        let version = String(format: "RFB 003.%03d\n", negotiatedMinor)
        try await send(Data(version.utf8))

        await model?.setState(.authenticating, generation: generation)
        let selectedSecurityType: UInt32
        if negotiatedMinor == 3 {
            selectedSecurityType = try await readUInt32()
            guard selectedSecurityType != 0 else {
                let reasonLength = try await readUInt32()
                guard reasonLength <= 4096 else {
                    throw ClientError.invalidServerMessage("거부 사유가 너무 깁니다.")
                }
                let reason = String(decoding: try await readExactly(Int(reasonLength)), as: UTF8.self)
                throw ClientError.serverRejected(reason)
            }
            guard selectedSecurityType == 1 || selectedSecurityType == 2 || selectedSecurityType == 30 else {
                throw ClientError.unsupportedSecurity([UInt8(truncatingIfNeeded: selectedSecurityType)])
            }
            if selectedSecurityType == 2, password == nil {
                throw ClientError.passwordRequired
            }
            if selectedSecurityType == 30 {
                guard !username.isEmpty else { throw ClientError.usernameRequired }
                guard password != nil else { throw ClientError.passwordRequired }
            }
        } else {
            let securityCount = Int(try await readExactly(1)[0])
            guard securityCount > 0 else {
                let reasonLength = try await readUInt32()
                guard reasonLength <= 4096 else {
                    throw ClientError.invalidServerMessage("거부 사유가 너무 깁니다.")
                }
                let reason = String(decoding: try await readExactly(Int(reasonLength)), as: UTF8.self)
                throw ClientError.serverRejected(reason)
            }
            let securityTypes = try await readExactly(securityCount)
            if securityTypes.contains(30), !username.isEmpty, password != nil {
                selectedSecurityType = 30
            } else if securityTypes.contains(2), password != nil {
                selectedSecurityType = 2
            } else if securityTypes.contains(1) {
                selectedSecurityType = 1
            } else if securityTypes.contains(30) {
                if username.isEmpty { throw ClientError.usernameRequired }
                throw ClientError.passwordRequired
            } else if securityTypes.contains(2) {
                throw ClientError.passwordRequired
            } else {
                throw ClientError.unsupportedSecurity(Array(securityTypes))
            }
            try await send(Data([UInt8(selectedSecurityType)]))
        }

        if selectedSecurityType == 2 {
            let challenge = try await readExactly(16)
            guard let password else { throw ClientError.passwordRequired }
            try await send(vncAuthenticationResponse(challenge: challenge, password: password))
        } else if selectedSecurityType == 30 {
            guard let password else { throw ClientError.passwordRequired }
            try await authenticateAppleDiffieHellman(username: username, password: password)
        }

        if negotiatedMinor >= 8 || selectedSecurityType == 2 || selectedSecurityType == 30 {
            let securityResult = try await readUInt32()
            guard securityResult == 0 else {
                // Apple Screen Sharing type 30 omits the RFB 3.8 reason string.
                if selectedSecurityType == 30 { throw ClientError.authenticationFailed }
                if negotiatedMinor >= 8 {
                    let reasonLength = try await readUInt32()
                    guard reasonLength <= 4096 else {
                        throw ClientError.invalidServerMessage("보안 오류 사유가 너무 깁니다.")
                    }
                    let reason = String(decoding: try await readExactly(Int(reasonLength)), as: UTF8.self)
                    throw ClientError.serverRejected(reason.isEmpty ? "보안 협상 실패" : reason)
                }
                throw ClientError.authenticationFailed
            }
        }

        await model?.setState(.initializing, generation: generation)
        try await send(Data([1]))
        let dimensions = try await readExactly(4)
        width = Int(dimensions.readUInt16(at: 0))
        height = Int(dimensions.readUInt16(at: 2))
        try validateDimensions(width: width, height: height)

        let serverPixelFormat = try await readExactly(16)
        guard serverPixelFormat.count == 16 else {
            throw ClientError.invalidServerMessage("픽셀 형식 필드가 잘렸습니다.")
        }
        let nameLength = try await readUInt32()
        guard nameLength <= 4096 else {
            throw ClientError.invalidServerMessage("서버 이름이 너무 깁니다.")
        }
        _ = try await readExactly(Int(nameLength))

        pixels = Data(repeating: 0, count: width * height * 4)
        try await sendPixelFormat()
        try await sendEncodings()
        try await requestUpdate(incremental: false)
        await model?.setScreen(width: width, height: height, framebuffer: Data(), generation: generation)
        armFirstFrameTimeout()

        while !Task.isCancelled {
            try await readServerMessage()
        }
    }

    private func armFirstFrameTimeout() {
        // Empty updates and repeated DesktopSize messages cannot extend this deadline.
        guard firstFrameTimeout == nil else { return }
        firstFrameTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            await self?.expireFirstFrame()
        }
    }

    private func expireFirstFrame() {
        guard !hasFrame else { return }
        connection?.cancel()
    }

    func close() {
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        connection?.cancel()
        connection = nil
        pixels.removeAll(keepingCapacity: false)
    }

    func sendPointer(x: UInt16, y: UInt16, buttonMask: UInt8) async throws {
        var message = Data([5, buttonMask])
        message.appendUInt16(x)
        message.appendUInt16(y)
        try await send(message)
    }

    func sendKey(keysym: UInt32, pressed: Bool) async throws {
        var message = Data([4, pressed ? 1 : 0, 0, 0])
        message.appendUInt32(keysym)
        try await send(message)
    }

    func sendClipboard(bytes: Data) async throws {
        guard bytes.count <= 1_048_576 else {
            throw ClientError.invalidServerMessage("클립보드 데이터가 너무 깁니다.")
        }
        var message = Data([6, 0, 0, 0])
        message.appendUInt32(UInt32(bytes.count))
        message.append(bytes)
        try await send(message)
    }

    private func start(_ connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            let timeout = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = ResumeOnce()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resumed.resume(continuation, returning: ())
                    case .failed(let error):
                        resumed.resume(continuation, throwing: ClientError.connection(error.localizedDescription))
                    case .cancelled:
                        resumed.resume(continuation, throwing: ClientError.connection("연결이 취소되었거나 서버 응답 시간이 초과되었습니다."))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
            try Task.checkCancellation()
        } onCancel: { connection.cancel() }
    }

    private func readExactly(_ count: Int, timeoutEnabled: Bool = true) async throws -> Data {
        guard count >= 0, count <= 128 * 1024 * 1024 else {
            throw ClientError.invalidServerMessage("요청된 데이터 길이가 허용 범위를 벗어났습니다.")
        }
        try Task.checkCancellation()
        guard let connection else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            let timeout = DispatchWorkItem { connection.cancel() }
            if timeoutEnabled { queue.asyncAfter(deadline: .now() + responseTimeout, execute: timeout) }
            defer { timeout.cancel() }
            var result = Data()
            result.reserveCapacity(count)
            while result.count < count {
                try Task.checkCancellation()
                let remaining = count - result.count
                let chunk: Data = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: ClientError.connection(error.localizedDescription))
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: ClientError.connection(isComplete ? "서버가 연결을 종료했습니다." : "서버에서 데이터를 받지 못했습니다."))
                        }
                    }
                }
                result.append(chunk)
            }
            try Task.checkCancellation()
            return result
        } onCancel: { connection.cancel() }
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let connection else { throw CancellationError() }
        try await withTaskCancellationHandler {
            let timeout = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: ClientError.connection(error.localizedDescription))
                    } else { continuation.resume(returning: ()) }
                })
            }
            try Task.checkCancellation()
        } onCancel: { connection.cancel() }
    }

    private func readUInt32() async throws -> UInt32 {
        try await readExactly(4).readUInt32(at: 0)
    }

    private func vncAuthenticationResponse(challenge: Data, password: String) throws -> Data {
        // RFB VNC authentication uses DES-ECB with each password byte's bits reversed.
        var key = [UInt8](repeating: 0, count: kCCKeySizeDES)
        for (index, byte) in password.utf8.prefix(key.count).enumerated() {
            key[index] = (0...7).reduce(UInt8(0)) { result, bit in
                result | (((byte >> bit) & 1) << (7 - bit))
            }
        }

        var response = Data(count: challenge.count)
        let responseCount = response.count
        var bytesWritten = 0
        let status = key.withUnsafeBytes { keyBytes in
            challenge.withUnsafeBytes { challengeBytes in
                response.withUnsafeMutableBytes { responseBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        kCCKeySizeDES,
                        nil,
                        challengeBytes.baseAddress,
                        challenge.count,
                        responseBytes.baseAddress,
                        responseCount,
                        &bytesWritten
                    )
                }
            }
        }
        guard status == kCCSuccess, bytesWritten == challenge.count else {
            throw ClientError.encryptionFailed
        }
        return response
    }

    private func authenticateAppleDiffieHellman(username: String, password: String) async throws {
        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        guard usernameBytes.count < 64, passwordBytes.count < 64,
              !usernameBytes.contains(0), !passwordBytes.contains(0) else {
            throw ClientError.invalidCredentialLength
        }
        let parameters = try await readExactly(4)
        let generator = UInt32(parameters.readUInt16(at: 0))
        let keyLength = Int(parameters.readUInt16(at: 2))
        guard (128...1024).contains(keyLength), (2...255).contains(generator) else {
            throw ClientError.invalidDHParameters
        }

        let modulus = try await readExactly(keyLength)
        let serverPublicKey = try await readExactly(keyLength)
        let modulusInteger = DHInteger(bigEndian: modulus)
        let serverPublicInteger = DHInteger(bigEndian: serverPublicKey)
        guard !modulusInteger.isZero,
              modulus.first.map({ $0 & 0x80 != 0 }) == true,
              modulus.last.map({ $0 & 1 == 1 }) == true,
              serverPublicInteger > .one,
              serverPublicInteger < modulusInteger - .one,
              DHInteger(value: generator, wordCount: modulusInteger.words.count) < modulusInteger - .one else {
            throw ClientError.invalidDHParameters
        }

        var privateBytes = Data(count: 32)
        let privateByteCount = privateBytes.count
        let randomStatus = privateBytes.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, privateByteCount, baseAddress)
        }
        guard randomStatus == errSecSuccess else { throw ClientError.encryptionFailed }
        privateBytes[0] |= 0x80
        privateBytes[privateBytes.count - 1] |= 1
        let privateKey = DHInteger(bigEndian: privateBytes)
        try Task.checkCancellation()
        let clientPublicKey = try DHInteger.power(UInt32(generator), exponent: privateKey, modulus: modulusInteger)
        let sharedSecret = try DHInteger.power(serverPublicInteger, exponent: privateKey, modulus: modulusInteger)
        let sharedBytes = sharedSecret.bigEndianData(length: keyLength)
        let digest = Array(Insecure.MD5.hash(data: sharedBytes))

        var credentials = Data(count: 128)
        let credentialCount = credentials.count
        let credentialRandomStatus = credentials.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, credentialCount, baseAddress)
        }
        guard credentialRandomStatus == errSecSuccess else { throw ClientError.encryptionFailed }
        credentials.replaceSubrange(0..<usernameBytes.count, with: usernameBytes)
        credentials[usernameBytes.count] = 0
        credentials.replaceSubrange(64..<(64 + passwordBytes.count), with: passwordBytes)
        credentials[64 + passwordBytes.count] = 0

        var encryptedCredentials = Data(count: credentials.count)
        let encryptedCredentialCount = encryptedCredentials.count
        var bytesWritten = 0
        let encryptionStatus = digest.withUnsafeBytes { keyBytes in
            credentials.withUnsafeBytes { inputBytes in
                encryptedCredentials.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        kCCKeySizeAES128,
                        nil,
                        inputBytes.baseAddress,
                        credentialCount,
                        outputBytes.baseAddress,
                        encryptedCredentialCount,
                        &bytesWritten
                    )
                }
            }
        }
        guard encryptionStatus == kCCSuccess, bytesWritten == credentialCount else {
            throw ClientError.encryptionFailed
        }
        encryptedCredentials.append(clientPublicKey.bigEndianData(length: keyLength))
        try await send(encryptedCredentials)
    }

    private func sendPixelFormat() async throws {
        var message = Data([0, 0, 0, 0])
        message.append(contentsOf: [32, 24, 0, 1])
        message.appendUInt16(255)
        message.appendUInt16(255)
        message.appendUInt16(255)
        message.append(contentsOf: [16, 8, 0, 0, 0, 0])
        try await send(message)
    }

    private func sendEncodings() async throws {
        var message = Data([2, 0])
        message.appendUInt16(3)
        message.appendInt32(0)
        message.appendInt32(1)
        message.appendInt32(-223)
        try await send(message)
    }

    private func requestUpdate(incremental: Bool) async throws {
        var message = Data([3, incremental ? 1 : 0])
        message.appendUInt16(0)
        message.appendUInt16(0)
        message.appendUInt16(UInt16(width))
        message.appendUInt16(UInt16(height))
        try await send(message)
    }

    private func readServerMessage() async throws {
        let messageType = try await readExactly(1, timeoutEnabled: !hasFrame)[0]
        switch messageType {
        case 0:
            let resized = try await readFramebufferUpdate()
            try await requestUpdate(incremental: !resized)
        case 2:
            break
        case 3:
            _ = try await readExactly(3)
            let length = try await readUInt32()
            guard length <= 1_048_576 else {
                throw ClientError.invalidServerMessage("클립보드 데이터가 너무 깁니다.")
            }
            let clipboard = try await readExactly(Int(length))
            await model?.setClipboard(String(data: clipboard, encoding: .isoLatin1) ?? "", generation: generation)
        default:
            throw ClientError.invalidServerMessage("지원하지 않는 서버 메시지 유형 \(messageType).")
        }
    }

    private func readFramebufferUpdate() async throws -> Bool {
        var resized = false
        let header = try await readExactly(3)
        let rectangleCount = Int(header.readUInt16(at: 1))
        guard rectangleCount <= 4096 else {
            throw ClientError.invalidServerMessage("업데이트 사각형 수가 허용 범위를 넘었습니다.")
        }

        for _ in 0..<rectangleCount {
            let rectangle = try await readExactly(12)
            let x = Int(rectangle.readUInt16(at: 0))
            let y = Int(rectangle.readUInt16(at: 2))
            let rectWidth = Int(rectangle.readUInt16(at: 4))
            let rectHeight = Int(rectangle.readUInt16(at: 6))
            let encoding = rectangle.readInt32(at: 8)

            switch encoding {
            case 0:
                guard rectWidth <= width, rectHeight <= height,
                      x <= width - rectWidth, y <= height - rectHeight else {
                    throw ClientError.invalidServerMessage("Raw 사각형이 화면 경계를 벗어났습니다.")
                }
                let pixelCount = rectWidth.multipliedReportingOverflow(by: rectHeight)
                guard !pixelCount.overflow, pixelCount.partialValue <= maximumPixels else {
                    throw ClientError.invalidServerMessage("Raw 사각형 크기가 허용 범위를 넘었습니다.")
                }
                let dataLength = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
                guard !dataLength.overflow else {
                    throw ClientError.invalidServerMessage("Raw 데이터 길이 overflow.")
                }
                let raw = try await readExactly(dataLength.partialValue)
                if rectWidth > 0 && rectHeight > 0 {
                    hasFrame = true
                    firstFrameTimeout?.cancel()
                    firstFrameTimeout = nil
                }
                copyRaw(raw, x: x, y: y, width: rectWidth, height: rectHeight)
            case 1:
                let source = try await readExactly(4)
                let sourceX = Int(source.readUInt16(at: 0))
                let sourceY = Int(source.readUInt16(at: 2))
                guard rectWidth <= width, rectHeight <= height,
                      x <= width - rectWidth, y <= height - rectHeight,
                      sourceX <= width - rectWidth, sourceY <= height - rectHeight else {
                    throw ClientError.invalidServerMessage("CopyRect가 화면 경계를 벗어났습니다.")
                }
                copyRectangle(sourceX: sourceX, sourceY: sourceY, x: x, y: y, width: rectWidth, height: rectHeight)
            case -223:
                let newWidth = rectWidth
                let newHeight = rectHeight
                try validateDimensions(width: newWidth, height: newHeight)
                width = newWidth
                height = newHeight
                pixels = Data(repeating: 0, count: width * height * 4)
                hasFrame = false
                resized = true
                armFirstFrameTimeout()
                await model?.setScreen(width: width, height: height, framebuffer: Data(), generation: generation)
            default:
                throw ClientError.invalidServerMessage("지원하지 않는 인코딩 \(encoding).")
            }
        }
        if hasFrame { await model?.setFramebuffer(pixels, generation: generation) }
        return resized
    }

    private func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else {
            throw ClientError.invalidScreenSize
        }
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow, product.partialValue <= maximumPixels else {
            throw ClientError.invalidScreenSize
        }
    }

    private func copyRaw(_ source: Data, x: Int, y: Int, width rectWidth: Int, height rectHeight: Int) {
        guard rectWidth > 0, rectHeight > 0 else { return }
        for row in 0..<rectHeight {
            let destinationStart = ((y + row) * width + x) * 4
            for column in 0..<rectWidth {
                let sourceOffset = (row * rectWidth + column) * 4
                let destinationOffset = destinationStart + column * 4
                pixels[destinationOffset] = source[sourceOffset + 2]
                pixels[destinationOffset + 1] = source[sourceOffset + 1]
                pixels[destinationOffset + 2] = source[sourceOffset]
                pixels[destinationOffset + 3] = 255
            }
        }
    }

    private func copyRectangle(sourceX: Int, sourceY: Int, x: Int, y: Int, width rectWidth: Int, height rectHeight: Int) {
        guard rectWidth > 0, rectHeight > 0 else { return }
        let rowBytes = rectWidth * 4
        var copy = Data(count: rowBytes * rectHeight)
        for row in 0..<rectHeight {
            let sourceStart = ((sourceY + row) * width + sourceX) * 4
            let targetStart = row * rowBytes
            copy.replaceSubrange(targetStart..<(targetStart + rowBytes),
                                 with: pixels[sourceStart..<(sourceStart + rowBytes)])
        }
        for row in 0..<rectHeight {
            let targetStart = ((y + row) * width + x) * 4
            let sourceStart = row * rowBytes
            pixels.replaceSubrange(targetStart..<(targetStart + rowBytes),
                                   with: copy[sourceStart..<(sourceStart + rowBytes)])
        }
    }
}

nonisolated private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    nonisolated func resume<T>(_ continuation: CheckedContinuation<T, Error>, returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }

    nonisolated func resume<T>(_ continuation: CheckedContinuation<T, Error>, throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}

nonisolated private struct DHInteger: Comparable, Sendable {
    private(set) var words: [UInt32]

    static let one = DHInteger(value: 1, wordCount: 1)

    var isZero: Bool {
        words.allSatisfy { $0 == 0 }
    }

    private var bitWidth: Int {
        words.count * 32
    }

    init(bigEndian data: Data) {
        words = Array(repeating: 0, count: (data.count + 3) / 4)
        for (index, byte) in data.enumerated() {
            let significance = data.count - 1 - index
            words[significance / 4] |= UInt32(byte) << ((significance % 4) * 8)
        }
    }

    init(value: UInt32, wordCount: Int) {
        words = Array(repeating: 0, count: wordCount)
        if !words.isEmpty {
            words[0] = value
        }
    }

    static func < (lhs: DHInteger, rhs: DHInteger) -> Bool {
        let count = max(lhs.words.count, rhs.words.count)
        for index in (0..<count).reversed() {
            let left = index < lhs.words.count ? lhs.words[index] : 0
            let right = index < rhs.words.count ? rhs.words[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: DHInteger, rhs: DHInteger) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func - (lhs: DHInteger, rhs: DHInteger) -> DHInteger {
        let count = max(lhs.words.count, rhs.words.count)
        let left = DHInteger(words: lhs.words, wordCount: count)
        let right = DHInteger(words: rhs.words, wordCount: count)
        var difference = Array(repeating: UInt32(0), count: count)
        var borrow: UInt64 = 0
        for index in 0..<count {
            let leftWord = UInt64(left.words[index])
            let rightWord = UInt64(right.words[index]) + borrow
            if leftWord >= rightWord {
                difference[index] = UInt32(leftWord - rightWord)
                borrow = 0
            } else {
                difference[index] = UInt32((UInt64(1) << 32) + leftWord - rightWord)
                borrow = 1
            }
        }
        return DHInteger(words: difference, wordCount: count)
    }

    static func power(_ base: UInt32, exponent: DHInteger, modulus: DHInteger) throws -> DHInteger {
        try power(DHInteger(value: base, wordCount: modulus.words.count), exponent: exponent, modulus: modulus)
    }

    static func power(_ base: DHInteger, exponent: DHInteger, modulus: DHInteger) throws -> DHInteger {
        let wordCount = modulus.words.count
        let one = DHInteger(value: 1, wordCount: wordCount)
        var rSquared = one
        for step in 0..<(wordCount * 64) {
            if step % 64 == 0 { try Task.checkCancellation() }
            rSquared = addModulo(rSquared, rSquared, modulus: modulus)
        }
        var result = montgomeryMultiply(one, rSquared, modulus: modulus)
        let normalizedBase = montgomeryMultiply(
            DHInteger(words: base.words, wordCount: wordCount),
            rSquared,
            modulus: modulus
        )
        guard exponent.bitWidth > 0 else { return one }
        for bit in (0..<exponent.bitWidth).reversed() {
            try Task.checkCancellation()
            result = montgomeryMultiply(result, result, modulus: modulus)
            if exponent.bit(at: bit) {
                result = montgomeryMultiply(result, normalizedBase, modulus: modulus)
            }
        }
        return montgomeryMultiply(result, one, modulus: modulus)
    }

    func bigEndianData(length: Int) -> Data {
        var result = Data(count: length)
        for significance in 0..<length {
            let wordIndex = significance / 4
            let byteIndex = length - 1 - significance
            let word = wordIndex < words.count ? words[wordIndex] : 0
            result[byteIndex] = UInt8(truncatingIfNeeded: word >> ((significance % 4) * 8))
        }
        return result
    }

    private init(words: [UInt32], wordCount: Int) {
        self.words = Array(words.prefix(wordCount))
        if self.words.count < wordCount {
            self.words.append(contentsOf: repeatElement(0, count: wordCount - self.words.count))
        }
    }

    private func bit(at index: Int) -> Bool {
        let wordIndex = index / 32
        guard wordIndex < words.count else { return false }
        return (words[wordIndex] & (UInt32(1) << (index % 32))) != 0
    }

    private static func montgomeryMultiply(
        _ lhs: DHInteger,
        _ rhs: DHInteger,
        modulus: DHInteger
    ) -> DHInteger {
        let count = modulus.words.count
        var inverse: UInt32 = 1
        for _ in 0..<5 {
            inverse = inverse &* (2 &- modulus.words[0] &* inverse)
        }
        let negativeInverse = 0 &- inverse
        var temporary = Array(repeating: UInt32(0), count: count + 2)

        for index in 0..<count {
            var carry: UInt64 = 0
            for word in 0..<count {
                let product = UInt64(temporary[word])
                    + UInt64(lhs.words[word]) * UInt64(rhs.words[index])
                    + carry
                temporary[word] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            let high = UInt64(temporary[count]) + carry
            temporary[count] = UInt32(truncatingIfNeeded: high)
            temporary[count + 1] = UInt32(high >> 32)

            let factor = temporary[0] &* negativeInverse
            let first = UInt64(temporary[0]) + UInt64(factor) * UInt64(modulus.words[0])
            carry = first >> 32
            for word in 1..<count {
                let value = UInt64(temporary[word])
                    + UInt64(factor) * UInt64(modulus.words[word])
                    + carry
                temporary[word - 1] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
            let highValue = UInt64(temporary[count]) + carry
            temporary[count - 1] = UInt32(truncatingIfNeeded: highValue)
            temporary[count] = temporary[count + 1] + UInt32(highValue >> 32)
            temporary[count + 1] = 0
        }

        var result = DHInteger(words: Array(temporary[0...count]), wordCount: count + 1)
        let extendedModulus = DHInteger(words: modulus.words, wordCount: count + 1)
        if !(result < extendedModulus) {
            result = result - extendedModulus
        }
        return DHInteger(words: result.words, wordCount: count)
    }

    private static func addModulo(_ lhs: DHInteger, _ rhs: DHInteger, modulus: DHInteger) -> DHInteger {
        let count = modulus.words.count
        var sum = Array(repeating: UInt32(0), count: count)
        var carry: UInt64 = 0
        for index in 0..<count {
            let value = UInt64(lhs.words[index]) + UInt64(rhs.words[index]) + carry
            sum[index] = UInt32(truncatingIfNeeded: value)
            carry = value >> 32
        }
        let sumValue = DHInteger(words: sum, wordCount: count)
        guard carry > 0 || !(sumValue < modulus) else { return sumValue }

        var difference = Array(repeating: UInt32(0), count: count)
        var borrow: UInt64 = 0
        for index in 0..<count {
            let left = UInt64(sum[index])
            let right = UInt64(modulus.words[index]) + borrow
            if left >= right {
                difference[index] = UInt32(left - right)
                borrow = 0
            } else {
                difference[index] = UInt32((UInt64(1) << 32) + left - right)
                borrow = 1
            }
        }
        return DHInteger(words: difference, wordCount: count)
    }
}

private extension Data {
    nonisolated func readUInt16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    nonisolated func readUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    nonisolated func readInt32(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(at: offset))
    }

    nonisolated mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xff))
    }

    nonisolated mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    nonisolated mutating func appendInt32(_ value: Int32) {
        let bits = UInt32(bitPattern: value)
        append(UInt8(bits >> 24))
        append(UInt8((bits >> 16) & 0xff))
        append(UInt8((bits >> 8) & 0xff))
        append(UInt8(bits & 0xff))
    }
}
