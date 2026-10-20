import XCTest
@testable import DeskPad

@MainActor
final class RemoteInputTests: XCTestCase {
    func testLocalPointerMovesWithoutAFramebufferAndTracksViewport() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 150, y: 125)
        hover.testState = .changed
        view.layer.displayIfNeeded()
        XCTAssertFalse(view.layer.needsDisplay())
        var sent: CGPoint?
        view.onPointer = { point, _ in sent = point }
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        let marker = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "local-input-pointer" })
        XCTAssertNil(view.desktopImage)
        XCTAssertFalse(view.layer.needsDisplay(), "Pointer movement must not repaint the framebuffer")
        XCTAssertFalse(marker.isHidden)
        XCTAssertEqual(sent, CGPoint(x: 300, y: 150))
        XCTAssertEqual(marker.position, hover.testLocation)
        view.actualSize()
        XCTAssertEqual(marker.position, CGPoint(x: 200, y: 150))
        view.resetViewport()
        XCTAssertEqual(marker.position, hover.testLocation)
        view.bounds.size = CGSize(width: 400, height: 400)
        view.layoutSubviews()
        XCTAssertEqual(marker.position, CGPoint(x: 300, y: 250))
        hover.testState = .ended
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        XCTAssertTrue(marker.isHidden)
    }

    func testLocalPointerPanAndLetterboxClampUseRemoteCoordinates() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 50, y: 10)
        hover.testState = .changed
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        let marker = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "local-input-pointer" })
        XCTAssertEqual(marker.position, CGPoint(x: 50, y: 50))
        let pan = StubPan()
        pan.testTranslation = CGPoint(x: 20, y: 30)
        _ = view.perform(NSSelectorFromString("handleViewportPan:"), with: pan)
        XCTAssertEqual(marker.position, CGPoint(x: 70, y: 80))
        view.didMoveToWindow()
        XCTAssertTrue(marker.isHidden)
    }

    func testLocalPointerClickFeedbackAndSessionReset() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 90, y: 100)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        let marker = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "local-input-pointer" } as? CAShapeLayer)
        XCTAssertFalse(marker.isHidden)
        XCTAssertEqual(marker.strokeColor, UIColor.systemYellow.cgColor)
        XCTAssertNotNil(marker.animation(forKey: "click"))
        view.releaseAllKeys()
        XCTAssertTrue(marker.isHidden)
        XCTAssertNil(marker.animation(forKey: "click"))
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        view.desktopImage = nil
        XCTAssertTrue(marker.isHidden)
        pan.testState = .changed
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        view.desktopSize = CGSize(width: 400, height: 200)
        XCTAssertTrue(marker.isHidden)
    }

    func testSparseDragPressesOriginalPointAndMovesBeforeRelease() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        var events: [(CGPoint, UInt8)] = []
        view.onPointer = { events.append(($0, $1)) }
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 110, y: 68)
        pan.testTranslation = CGPoint(x: 10, y: 12.6)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        pan.testLocation = CGPoint(x: 120, y: 80)
        pan.testState = .ended
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        XCTAssertEqual(events.map { $0.1 }, [0, 1, 1, 1, 0])
        XCTAssertEqual(events.first?.0.x ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(events.first?.0.y ?? -1, 55.4, accuracy: 0.001)
        XCTAssertEqual(events.dropFirst().first?.0, events.first?.0)
        XCTAssertEqual(events.suffix(2).map { $0.0 }, [CGPoint(x: 120, y: 80), CGPoint(x: 120, y: 80)])
    }

    func testDragOriginIsMappedThroughViewportAndCancellationReleases() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        view.actualSize()
        var events: [(CGPoint, UInt8)] = []
        view.onPointer = { events.append(($0, $1)) }
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 130, y: 120)
        pan.testTranslation = CGPoint(x: 30, y: 20)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        XCTAssertEqual(events.first?.0, CGPoint(x: 200, y: 100))
        XCTAssertEqual(events.last?.0.x ?? -1, 230, accuracy: 0.001)
        XCTAssertEqual(events.last?.0.y ?? -1, 120, accuracy: 0.001)
        events.removeAll()
        pan.testState = .cancelled
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        XCTAssertEqual(events.map { $0.1 }, [0])
        view.releaseAllKeys()
        XCTAssertEqual(events.count, 1)
    }

    func testDragAfterBlurDoesNotPressAgain() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        var masks: [UInt8] = []
        view.onPointer = { masks.append($1) }
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 100, y: 100)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        _ = view.resignFirstResponder()
        masks.removeAll()
        pan.testState = .changed
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        pan.testState = .ended
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        XCTAssertFalse(masks.contains { $0 != 0 })
    }

    func testSecondaryMouseClickCannotRecognizeDirectTouch() throws {
        let taps = RemoteDesktopUIView().gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        let secondary = try XCTUnwrap(taps.first { $0.buttonMaskRequired == .secondary })
        XCTAssertEqual(secondary.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)])
    }

    func testSingleTapRequiresPrimaryMouseButton() throws {
        let taps = RemoteDesktopUIView().gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        let primary = try XCTUnwrap(taps.first { $0.numberOfTouchesRequired == 1 && $0.buttonMaskRequired != .secondary })
        XCTAssertEqual(primary.buttonMaskRequired, .primary)
        XCTAssertTrue(primary.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)))
    }

    func testTwoFingerRightClickRemainsDirectTouchOnly() throws {
        let taps = RemoteDesktopUIView().gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        let twoFinger = try XCTUnwrap(taps.first { $0.numberOfTouchesRequired == 2 })
        XCTAssertEqual(twoFinger.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
    }

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
    func testShortcutCommitsCompositionBeforePressingControl() {
        let view = RemoteDesktopUIView()
        var events: [String] = []
        view.onKey = { events.append("\($0):\($1)") }
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        view.keyDown(code: .keyboardLeftControl, keysym: 0xffe3)
        XCTAssertEqual(events, ["16831836:true", "16831836:false", "65507:true"])
        XCTAssertNil(view.markedTextRange)
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

@MainActor
private final class StubPan: UIPanGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testLocation = CGPoint.zero
    var testTranslation = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { testLocation }
    override func translation(in view: UIView?) -> CGPoint { testTranslation }
}

@MainActor
private final class StubHover: UIHoverGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testLocation = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { testLocation }
}
