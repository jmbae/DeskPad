import XCTest
@testable import DeskPad

@MainActor
final class RemoteInputTests: XCTestCase {
    func testCompositionDoesNotSendUntilCommitAndEmitsEveryScalar() {
        let view = RemoteDesktopUIView()
        var keys: [UInt32] = []
        view.onKey = { if $1 { keys.append($0) } }
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(keys.isEmpty)
        view.insertText("한😀")
        XCTAssertEqual(keys, [0x0100D55C, 0x0101F600])
        view.unmarkText()
        XCTAssertEqual(keys.count, 2)
    }
    func testBackspaceDuringCompositionIsLocal() {
        let view = RemoteDesktopUIView()
        var keys: [UInt32] = []
        view.onKey = { if $1 { keys.append($0) } }
        view.setMarkedText("😀", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertFalse(view.handlesDirectly(code: .keyboardDeleteOrBackspace, modifiers: []))
        view.deleteBackward()
        view.unmarkText()
        XCTAssertTrue(keys.isEmpty)
        XCTAssertTrue(view.handlesDirectly(code: .keyboardDeleteOrBackspace, modifiers: []))
        view.deleteBackward()
        XCTAssertEqual(keys, [0xff08])
    }
    func testViewportMappingClampsAndResetRestoresFit() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        XCTAssertEqual(view.viewPointToDesktopPoint(CGPoint(x: 100, y: 100)), CGPoint(x: 200, y: 100))
        XCTAssertEqual(view.viewPointToDesktopPoint(CGPoint(x: -100, y: -100)), .zero)
        view.actualSize()
        XCTAssertEqual(view.viewPointToDesktopPoint(CGPoint(x: 0, y: 100)), CGPoint(x: 100, y: 100))
        view.resetViewport()
        XCTAssertEqual(view.viewPointToDesktopPoint(CGPoint(x: 100, y: 100)), CGPoint(x: 200, y: 100))
    }
    func testBlurSendsUpForHeldModifiersAndShortcut() {
        let view = RemoteDesktopUIView()
        var events: [String] = []
        view.onKey = { events.append("\($0):\($1)") }
        XCTAssertTrue(view.handlesDirectly(code: .keyboardC, modifiers: [.command]))
        XCTAssertFalse(view.handlesDirectly(code: .keyboardC, modifiers: []))
        view.keyDown(code: .keyboardLeftGUI, keysym: 0xffeb)
        view.keyDown(code: .keyboardC, keysym: 99)
        _ = view.resignFirstResponder()
        XCTAssertEqual(Set(events.filter { $0.hasSuffix(":false") }), ["65515:false", "99:false"])
        view.releaseAllKeys()
        XCTAssertEqual(events.count, 4)
    }
}
