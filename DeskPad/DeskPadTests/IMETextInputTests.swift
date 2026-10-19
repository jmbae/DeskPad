import Testing
import UIKit
@testable import DeskPad

@MainActor
struct IMETextInputTests {
    private func range(_ view: RemoteDesktopUIView, _ location: Int, _ length: Int) -> UITextRange {
        let start = view.position(from: view.beginningOfDocument, offset: location)!
        return view.textRange(from: start, to: view.position(from: start, offset: length)!)!
    }

    @Test func markedSelectionUsesUTF16Offsets() {
        let view = RemoteDesktopUIView(frame: .zero)
        view.setMarkedText("한😀글", selectedRange: NSRange(location: 1, length: 2))
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 4)
        #expect(view.offset(from: view.beginningOfDocument, to: view.selectedTextRange!.start) == 1)
        #expect(view.text(in: view.selectedTextRange!) == "😀")
    }

    @Test func markedReplacementRemainsLocalUntilCommit() {
        let view = RemoteDesktopUIView(frame: .zero)
        let recorder = InputRecorder()
        view.delegate = recorder
        view.setMarkedText("한굴", selectedRange: NSRange(location: 2, length: 0))
        view.replace(range(view, 1, 1), withText: "글")
        #expect(view.markedTextRange.flatMap { view.text(in: $0) } == "한글")
        #expect(recorder.insertions.isEmpty)
        view.unmarkText()
        view.unmarkText()
        #expect(recorder.insertions == ["한글"])
    }

    @Test func selectionSetterSupportsLocalDeletion() {
        let view = RemoteDesktopUIView(frame: .zero)
        let recorder = InputRecorder()
        view.delegate = recorder
        view.setMarkedText("가나다", selectedRange: NSRange(location: 3, length: 0))
        view.selectedTextRange = range(view, 1, 1)
        view.deleteBackward()
        #expect(view.markedTextRange.flatMap { view.text(in: $0) } == "가다")
        #expect(recorder.deletions == 0)
        view.unmarkText()
        #expect(recorder.insertions == ["가다"])
    }

    @Test func backwardDeletionRemovesOneComposedCharacter() {
        let view = RemoteDesktopUIView(frame: .zero)
        view.setMarkedText("한👨‍👩‍👧‍👦", selectedRange: NSRange(location: 12, length: 0))
        view.deleteBackward()
        #expect(view.markedTextRange.flatMap { view.text(in: $0) } == "한")
    }

    @Test func decomposedHangulUsesUTF16Positions() {
        let view = RemoteDesktopUIView(frame: .zero)
        view.setMarkedText("한", selectedRange: NSRange(location: 3, length: 0))
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 3)
        #expect(view.markedTextRange.flatMap { view.text(in: $0) } == "한")
    }

    @Test func positionsCannotEscapeLocalDocument() {
        let view = RemoteDesktopUIView(frame: .zero)
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        #expect(view.position(from: view.endOfDocument, offset: 1) == nil)
        #expect(view.position(from: view.beginningOfDocument, offset: -1) == nil)
    }

    @Test func finalInsertCommitsOnlyOnce() {
        let view = RemoteDesktopUIView(frame: .zero)
        let recorder = InputRecorder()
        view.delegate = recorder
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        view.insertText("한글")
        view.unmarkText()
        #expect(recorder.insertions == ["한글"])
        #expect(view.markedTextRange == nil)
    }

    @Test func cancellingCompositionDoesNotSendRemoteText() {
        let view = RemoteDesktopUIView(frame: .zero)
        let recorder = InputRecorder()
        view.delegate = recorder
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        view.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        view.unmarkText()
        #expect(recorder.insertions.isEmpty)
        view.deleteBackward()
        #expect(recorder.deletions == 1)
    }
}

@MainActor
private final class InputRecorder: RemoteDesktopUIViewDelegate {
    var insertions: [String] = []
    var deletions = 0
    func remoteDesktopView(_ view: RemoteDesktopUIView, didInsertText text: String) { insertions.append(text) }
    func remoteDesktopViewDidDeleteBackward(_ view: RemoteDesktopUIView) { deletions += 1 }
    func remoteDesktopView(_ view: RemoteDesktopUIView, keyDown key: UIKey) {}
    func remoteDesktopView(_ view: RemoteDesktopUIView, keyUp key: UIKey) {}
    func remoteDesktopView(_ view: RemoteDesktopUIView, pointerMovedTo desktopPoint: CGPoint) {}
    func remoteDesktopView(_ view: RemoteDesktopUIView, mouseDown button: Int, at desktopPoint: CGPoint) {}
    func remoteDesktopView(_ view: RemoteDesktopUIView, mouseUp button: Int, at desktopPoint: CGPoint) {}
    func remoteDesktopView(_ view: RemoteDesktopUIView, scrollDeltaY: CGFloat) {}
}
