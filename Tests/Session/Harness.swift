import Foundation

@main struct Harness {
    @MainActor static func main() async throws {
        let model = VNCSessionModel()
        let port = UInt16(CommandLine.arguments[1])!
        let mode = CommandLine.arguments[2]
        func connect() { model.connect(to: SavedConnection(id: UUID(), name: "Test", host: "127.0.0.1", port: port, username: ["apple", "apple-failure"].contains(mode) ? "alice" : "", lastConnected: nil), password: ["apple", "apple-failure", "vnc33"].contains(mode) ? "secret" : nil) }
        if mode == "deinit" {
            weak var probe: VNCSessionModel?
            do {
                let transient = VNCSessionModel()
                probe = transient
                transient.connect(to: SavedConnection(id: UUID(), name: "Test", host: "127.0.0.1", port: port, username: "", lastConnected: nil))
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(100))
            precondition(probe == nil, "Running transport retained session model")
            print("PASS deinit")
            return
        }
        connect()
        try await Task.sleep(for: .milliseconds(250))
        if mode == "first-frame" {
            precondition(model.state == .initializing, "Connected before receiving actual pixels: \(model.state)")
            precondition(model.framebuffer.isEmpty, "Allocated black buffer presented as a frame")
            try await Task.sleep(for: .milliseconds(600))
            precondition(model.state == .connected)
            precondition(model.framebuffer == Data([255, 0, 0, 255]))
        } else if mode == "apple-failure" {
            guard case .failed(let message) = model.state else { fatalError("Apple rejection waited for a missing reason string: \(model.state)") }
            precondition(message.contains("인증에 실패"), "Apple rejection was not an authentication error: \(message)")
        } else if ["first-frame-timeout", "resize-timeout"].contains(mode) {
            try await Task.sleep(for: .seconds(21))
            guard case .failed = model.state else { fatalError("Server messages kept first-frame initialization alive indefinitely") }
        } else if mode == "terminal-error" {
            model.reportError("test failure")
            try await Task.sleep(for: .milliseconds(650))
            precondition(model.state == .failed("test failure"), "Late callback overwrote terminal failure")
            precondition(model.framebuffer.isEmpty)
        } else if mode == "clipboard" || mode == "apple" || mode == "vnc33" {
            precondition(model.state == .connected)
            if mode == "clipboard" {
                precondition(model.receivedClipboard == "café")
                model.sendClipboard(text: "한글")
                precondition(model.clipboardError != nil)
                precondition(model.state == .connected)
                model.sendClipboard(text: "café")
                for _ in 0..<50 {
                    model.sendKey(keysym: 65, pressed: true)
                    model.sendKey(keysym: 65, pressed: false)
                }
                try await Task.sleep(for: .milliseconds(300))
                precondition(model.clipboardError == nil)
            }
        } else if mode == "reconnect" {
            model.disconnect()
            connect()
            try await Task.sleep(for: .milliseconds(350))
            precondition(model.state == .handshaking, "Old session overwrote new state: \(model.state)")
        } else if mode == "malformed" {
            guard case .failed = model.state else { fatalError("Malformed rectangle accepted") }
            precondition(model.framebuffer.isEmpty)
        }
        model.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.state == .disconnected)
        print("PASS \(mode)")
    }
}
