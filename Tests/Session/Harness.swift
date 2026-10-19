import Foundation

@main struct Harness {
    @MainActor static func main() async throws {
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
        func connect() { model.connect(to: SavedConnection(id: UUID(), name: "Test", host: "127.0.0.1", port: port, username: ["apple", "apple-failure"].contains(mode) ? "alice" : "", lastConnected: nil), password: ["apple", "apple-failure", "vnc33"].contains(mode) ? "secret" : nil) }
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
        if mode == "first-frame" {
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
        print("PASS \(mode)")
    }
}
