import Foundation

@main struct Harness {
    @MainActor static func main() async throws {
        precondition(RFBReceiveBudget.rawSeconds(byteCount: 0) == 20)
        precondition(RFBReceiveBudget.rawSeconds(byteCount: 81_432_576) == 98)
        precondition(RFBReceiveBudget.rawSeconds(byteCount: 128 * 1024 * 1024) == 120)
        let model = VNCSessionModel()
        let port = UInt16(CommandLine.arguments[1])!
        let mode = CommandLine.arguments[2]
        let marker = URL(fileURLWithPath: CommandLine.arguments[3])
        func waitUntil(_ label: String, seconds: Double = 5, allowFailure: Bool = false, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            while !condition() {
                if !allowFailure, case .failed(let message) = model.state { fatalError("\(label): \(message) \(model.errorDetails ?? "")") }
                precondition(ContinuousClock.now < deadline, "Timed out waiting for \(label), state: \(model.state)")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func signalServer() throws { try Data().write(to: marker) }
        func connect() { model.connect(to: SavedConnection(id: UUID(), name: "Test", host: "127.0.0.1", port: port, username: ["apple", "apple-failure"].contains(mode) ? "alice" : "", lastConnected: nil), password: ["apple", "apple-failure", "vnc33"].contains(mode) ? "secret" : nil, colorQuality: mode == "rgb565" ? .lowLatency : .fullColor) }
        if mode == "deinit" {
            weak var probe: VNCSessionModel?
            do {
                let transient = VNCSessionModel()
                probe = transient
                transient.connect(to: SavedConnection(id: UUID(), name: "Test", host: "127.0.0.1", port: port, username: "", lastConnected: nil))
                let deadline = ContinuousClock.now + .seconds(5)
                while transient.state != .handshaking {
                    precondition(ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            precondition(probe == nil, "Running transport retained session model")
            print("PASS deinit")
            return
        }
        connect()
        if mode == "multi-display" {
            func checkCorners(width: Int, height: Int) {
                precondition(model.screenWidth == width && model.screenHeight == height)
                precondition(model.framebuffer.count == width * height * 4)
                let points = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
                let colors: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,255,255], [255,255,255,255]]
                for ((x, y), color) in zip(points, colors) {
                    let offset = (y * width + x) * 4
                    precondition(model.framebuffer[offset..<(offset + 4)] == Data(color), "Large framebuffer corner offset incorrect")
                }
            }
            try await waitUntil("large multi-display ServerInit", seconds: 10) { model.state == .connected }
            checkCorners(width: 12032, height: 3384)
            try signalServer()
            try await waitUntil("large DesktopSize and corner pixels", seconds: 10) {
                model.state == .connected && model.screenWidth == 10000 && model.screenHeight == 4000
            }
            checkCorners(width: 10000, height: 4000)
        } else if mode == "oversized-init" || mode == "oversized-resize" {
            if mode == "oversized-resize" {
                try await waitUntil("valid frame before oversized resize") { model.state == .connected }
                try signalServer()
            }
            try await waitUntil("oversized framebuffer rejected", allowFailure: true) {
                if case .failed = model.state { return true }; return false
            }
            guard case .failed(let message) = model.state else { fatalError("Oversized screen accepted") }
            precondition(message.contains("화면 크기"), "Wrong failure for oversized screen: \(message)")
            precondition(model.framebuffer.isEmpty && model.screenWidth == 0 && model.screenHeight == 0)
        } else if mode == "apple-cursor" {
            try await waitUntil("Apple cursor STORE and frame") { model.state == .connected }
            precondition(model.remoteCursor?.rgba == Data([30,20,10,128]))
            let shape = model.remoteCursor
            let revision = model.framebufferRevision
            try signalServer()
            try await waitUntil("Apple SELECT and aligned next message") { model.receivedClipboard == "cursor-ok" }
            precondition(model.remoteCursor == shape && model.framebufferRevision == revision)
        } else if mode == "cursor" {
            try await waitUntil("cursor before first frame") { model.remoteCursor != nil }
            precondition(model.state == .initializing && model.framebuffer.isEmpty)
            precondition(model.remoteCursor?.hotspotX == 1)
            precondition(model.remoteCursor?.rgba == Data([255,0,0,255,0,255,0,255]))
            try signalServer()
            try await waitUntil("hidden cursor and frame") { model.state == .connected }
            precondition(model.remoteCursor?.isHidden == true)
            let revision = model.framebufferRevision
            try Data().write(to: marker.appendingPathExtension("frame"))
            try await waitUntil("cursor-only update after frame") { model.remoteCursor?.width == 1 }
            precondition(model.framebufferRevision == revision)
            precondition(model.framebuffer == Data([255,0,0,255]))
        } else if mode == "rgb565" {
            try await waitUntil("reduced-color frame") { model.state == .connected }
            let expected: [UInt8] = [140, 142, 41, 255]
            precondition(model.framebuffer == Data(expected))
            try signalServer()
            try await waitUntil("reduced-color Raw fallback") { model.framebuffer == Data([255,255,255,255]) }
        } else if mode == "zrle" {
            try await waitUntil("ZRLE first pixels") { model.state == .connected }
            precondition(model.framebuffer == Data([0x56, 0x34, 0x12, 255]))
            try signalServer()
            try await waitUntil("persistent ZRLE second rectangle") { model.framebuffer == Data([0x54, 0x76, 0x98, 255]) }
        } else if mode.hasPrefix("zrle-") {
            try await waitUntil("invalid or stalled ZRLE rejection", seconds: mode == "zrle-timeout" ? 24 : 5, allowFailure: true) {
                if case .failed = model.state { return true }; return false
            }
            precondition(model.framebuffer.isEmpty)
        } else if ["remote-close", "remote-reset", "remote-payload-close"].contains(mode) {
            if mode == "remote-payload-close" {
                try await waitUntil("partial first frame") { model.state == .initializing && model.screenWidth == 1 }
            } else {
                try await waitUntil("frame before server closes") { model.state == .connected }
            }
            try signalServer()
            try await waitUntil("remote termination", allowFailure: true) { model.state == .ended }
            precondition(model.state.title == "Mac과의 연결이 종료되었습니다")
            precondition(model.framebuffer.isEmpty && model.screenWidth == 0 && model.screenHeight == 0)
            precondition(model.receivedClipboard == nil && model.clipboardError == nil)
            precondition(model.errorDetails != nil)
            model.sendKey(keysym: 65, pressed: true)
            model.sendPointer(x: 0, y: 0, buttonMask: 1)
            connect()
            precondition(model.errorDetails == nil)
            try await waitUntil("retry frame") { model.state == .connected }
            precondition(model.framebuffer == Data([255, 0, 0, 255]))
            model.sendKey(keysym: 66, pressed: true)
            try await waitUntil("fresh input after retry") { model.receivedClipboard == "retry-ok" }
        } else if mode == "slow-raw" {
            try await waitUntil("large delayed Raw frame", seconds: 27) { model.state == .connected }
            precondition(model.framebuffer == Data(Array(repeating: [UInt8(255), 0, 0, 255], count: 1024 * 1024).joined()))
        } else if mode == "first-frame" {
            try await waitUntil("initialized screen") { model.screenWidth == 1 }
            precondition(model.state == .initializing, "Connected before receiving actual pixels: \(model.state)")
            precondition(model.framebuffer.isEmpty, "Allocated black buffer presented as a frame")
            try signalServer()
            try await waitUntil("first actual pixels") { model.state == .connected }
            precondition(model.framebuffer == Data([255, 0, 0, 255]))
        } else if mode == "resize-release" {
            try await waitUntil("initial frame") { model.state == .connected }
            model.sendKey(keysym: 0xffe3, pressed: true)
            model.sendPointer(x: 0, y: 0, buttonMask: 1)
            try await waitUntil("resized screen") { model.screenWidth == 2 }
            precondition(model.state == .initializing)
            model.sendKey(keysym: 66, pressed: true)
            model.sendPointer(x: 0, y: 0, buttonMask: 1)
            // Equivalent to dismantling RemoteDesktopSurface while waiting for resized pixels.
            model.sendKey(keysym: 0xffe3, pressed: false)
            model.sendPointer(x: 0, y: 0, buttonMask: 0)
            try await waitUntil("frame after release") { model.state == .connected }
            precondition(model.screenWidth == 2 && model.screenHeight == 2)
        } else if mode == "apple-failure" {
            try await waitUntil("prompt Apple authentication rejection", seconds: 2, allowFailure: true) { if case .failed = model.state { return true }; return false }
            guard case .failed(let message) = model.state else { fatalError("Apple rejection waited for a missing reason string: \(model.state)") }
            precondition(message.contains("인증에 실패"), "Apple rejection was not an authentication error: \(message)")
        } else if ["first-frame-timeout", "resize-timeout"].contains(mode) {
            try await waitUntil("initialized screen") { model.screenWidth == 1 }
            try await waitUntil("first-frame deadline", seconds: 22, allowFailure: true) { if case .failed = model.state { return true }; return false }
            guard case .failed = model.state else { fatalError("Server messages kept first-frame initialization alive indefinitely") }
        } else if mode == "terminal-error" {
            try await waitUntil("initialized screen") { model.screenWidth == 1 }
            model.reportError("test failure")
            try signalServer()
            try await Task.sleep(for: .milliseconds(650))
            precondition(model.state == .failed("test failure"), "Late callback overwrote terminal failure")
            precondition(model.framebuffer.isEmpty)
        } else if mode == "clipboard" || mode == "apple" || mode == "vnc33" {
            try await waitUntil("connected") { model.state == .connected }
            if mode == "clipboard" {
                try await waitUntil("clipboard receive") { model.receivedClipboard == "café" }
                model.sendClipboard(text: "한글")
                precondition(model.clipboardError != nil)
                precondition(model.state == .connected)
                model.sendClipboard(text: "café")
                for _ in 0..<50 {
                    model.sendKey(keysym: 65, pressed: true)
                    model.sendKey(keysym: 65, pressed: false)
                }
                try await waitUntil("input sequence acknowledged") { model.receivedClipboard == "input-complete" }
                precondition(model.clipboardError == nil)
            }
        } else if mode == "reconnect" {
            try await waitUntil("initialized first connection") { model.screenWidth == 1 }
            model.disconnect()
            connect()
            try await waitUntil("second handshake") { model.state == .handshaking }
            try await Task.sleep(for: .milliseconds(100))
            precondition(model.state == .handshaking, "Old session overwrote new state: \(model.state)")
        } else if mode == "malformed" {
            try await waitUntil("malformed rejection", allowFailure: true) { if case .failed = model.state { return true }; return false }
            guard case .failed = model.state else { fatalError("Malformed rectangle accepted") }
            precondition(model.framebuffer.isEmpty)
        }
        model.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.state == .disconnected)
        precondition(model.remoteCursor == nil)
        print("PASS \(mode)")
    }
}
