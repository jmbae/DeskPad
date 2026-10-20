import XCTest
@testable import DeskPad

@MainActor
final class RemoteInputTests: XCTestCase {
    func testRemoteSurfaceUsesNativePointerWithoutAdditionalMarker() {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 150, y: 125)
        hover.testState = .changed
        var sent: CGPoint?
        view.onPointer = { point, _ in sent = point }
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        XCTAssertEqual(sent, CGPoint(x: 300, y: 150))
        XCTAssertTrue(view.interactions.contains { $0 is UIPointerInteraction })
        XCTAssertFalse(view.layer.sublayers?.contains { $0.name == "local-input-pointer" } ?? false)
    }

    func testNativeArrowDoesNotDrawDuplicateAndCursorUpdatesDoNotRepaintDesktop() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        view.layer.displayIfNeeded()
        view.remoteCursor = cursor(width: 3, height: 3, hotspotX: 0, hotspotY: 0, mask: [1,0,0, 1,1,0, 1,1,1])
        XCTAssertFalse(view.layer.needsDisplay())
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 80, y: 90)
        hover.testState = .changed
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        let layer = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "remote-cursor" })
        XCTAssertTrue(layer.isHidden, "Native pointer must be the only pointer during hardware hover")
        XCTAssertNotNil(RemoteCursorPresentation(try XCTUnwrap(view.remoteCursor)).nativeShape)
        XCTAssertFalse(view.layer.needsDisplay())
    }

    func testBitmapFallbackAlignsHotspotAndHidesOnExitAndReset() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 400, height: 200)
        let shape = cursor(width: 3, height: 3, hotspotX: 1, hotspotY: 2, mask: Array(repeating: 1, count: 9))
        view.remoteCursor = shape
        XCTAssertNil(RemoteCursorPresentation(shape).nativeShape)
        let hover = StubHover()
        hover.testLocation = CGPoint(x: 150, y: 125)
        hover.testState = .changed
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        let layer = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "remote-cursor" })
        XCTAssertFalse(layer.isHidden)
        XCTAssertEqual(layer.position, CGPoint(x: 149, y: 123))
        let interaction = try XCTUnwrap(view.interactions.first { $0 is UIPointerInteraction } as? UIPointerInteraction)
        XCTAssertNotNil(view.pointerInteraction(interaction, styleFor: UIPointerRegion(rect: view.bounds)))
        view.actualSize()
        XCTAssertEqual(layer.position, CGPoint(x: 199, y: 148))
        hover.testState = .ended
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        XCTAssertTrue(layer.isHidden)
        hover.testState = .changed
        _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
        view.remoteCursor = nil
        XCTAssertTrue(layer.isHidden)
        XCTAssertNil(view.pointerInteraction(interaction, styleFor: UIPointerRegion(rect: view.bounds)))
    }

    func testCenteredTextBeamUsesNativePointerAndTransparentCursorStaysHidden() {
        var mask = Array(repeating: UInt8(0), count: 5 * 11)
        for x in 0..<5 { mask[x] = 1; mask[50 + x] = 1 }
        for y in 1..<10 { mask[y * 5 + 2] = 1 }
        let beam = cursor(width: 5, height: 11, hotspotX: 2, hotspotY: 5, mask: mask)
        XCTAssertNotNil(RemoteCursorPresentation(beam).nativeShape)
        let offCenter = cursor(width: 5, height: 11, hotspotX: 0, hotspotY: 5, mask: mask)
        XCTAssertNil(RemoteCursorPresentation(offCenter).nativeShape)
        let transparent = cursor(width: 5, height: 11, hotspotX: 0, hotspotY: 0, mask: Array(repeating: 0, count: 55))
        XCTAssertTrue(RemoteCursorPresentation(transparent).isHidden)
        XCTAssertNil(RemoteCursorPresentation(transparent).nativeShape)
    }

    func testTouchShowsActualRemoteCursorWithoutDecorativeRing() throws {
        let view = RemoteDesktopUIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.desktopSize = CGSize(width: 200, height: 200)
        view.remoteCursor = cursor(width: 2, height: 2, hotspotX: 0, hotspotY: 0, mask: [1,0,1,1])
        let pan = StubPan()
        pan.testLocation = CGPoint(x: 90, y: 100)
        pan.testState = .began
        _ = view.perform(NSSelectorFromString("handleDrag:"), with: pan)
        let layer = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "remote-cursor" })
        XCTAssertFalse(layer.isHidden)
        XCTAssertNotNil(layer.contents)
        XCTAssertNil(layer.animationKeys())
        view.releaseAllKeys()
        XCTAssertTrue(layer.isHidden)
    }

    private func cursor(width: Int, height: Int, hotspotX: Int, hotspotY: Int, mask: [UInt8]) -> RFBCursorShape {
        RFBCursorShape(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY,
                       rgba: Data(mask.flatMap { [UInt8(255), 255, 255, $0 == 0 ? 0 : 255] }))
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
