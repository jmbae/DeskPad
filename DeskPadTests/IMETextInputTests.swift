import Testing
import UIKit
@testable import DeskPad

/// Exercises UIKit's public text-input surface and the events leaving the view.
/// It does not simulate an iPad keyboard, a VNC connection, or a Mac input method.
@MainActor
struct IMETextInputTests {
    @Test func evolvingHangulStaysLocalUntilUnmarkedOnce() throws {
        let (view, remote) = makeInput()
        for (text, caret) in [("ㅎ", 1), ("하", 1), ("한", 1), ("한ㄱ", 2), ("한그", 2), ("한글", 2)] {
            view.setMarkedText(text, selectedRange: NSRange(location: caret, length: 0))
            #expect(markedText(view) == text)
            #expect(remote.events.isEmpty)
        }

        view.unmarkText()
        view.unmarkText()

        #expect(remote.events == expected([.text("한글")]))
        #expect(view.markedTextRange == nil)
        #expect(documentLength(view) == 0)
        #expect(try selection(view) == NSRange(location: 0, length: 0))
    }

    @Test func finalInsertionReplacesPendingCompositionWithoutDuplicateCommit() throws {
        let (view, remote) = makeInput()
        view.setMarkedText("한ㄱ", selectedRange: NSRange(location: 2, length: 0))

        view.insertText("한글")
        view.unmarkText()

        #expect(remote.events == expected([.text("한글")]))
        #expect(view.markedTextRange == nil)
        #expect(documentLength(view) == 0)
        #expect(try selection(view) == NSRange(location: 0, length: 0))
    }

    @Test func replacingEmojiSelectionMovesUTF16CaretAndSupportsFurtherEditing() throws {
        let (view, remote) = makeInput()
        view.setMarkedText("한😀굴", selectedRange: NSRange(location: 1, length: 2))
        #expect(documentLength(view) == 4)
        #expect(try view.text(in: #require(view.selectedTextRange)) == "😀")

        view.replace(try range(view, 1, 2), withText: "👩‍💻")
        #expect(markedText(view) == "한👩‍💻굴")
        #expect(documentLength(view) == 7)
        #expect(try selection(view) == NSRange(location: 6, length: 0))

        view.deleteBackward()
        #expect(markedText(view) == "한굴")
        #expect(try selection(view) == NSRange(location: 1, length: 0))
        view.replace(try range(view, 1, 1), withText: "글")
        #expect(try selection(view) == NSRange(location: 2, length: 0))
        #expect(remote.events.isEmpty)

        view.unmarkText()
        #expect(remote.events == expected([.text("한글")]))
    }

    @Test func deletingSelectedEmojiPreservesSurroundingHangulAndLocalCaret() throws {
        let (view, remote) = makeInput()
        view.setMarkedText("한😀글", selectedRange: NSRange(location: 4, length: 0))
        view.selectedTextRange = try range(view, 1, 2)

        view.deleteBackward()

        #expect(markedText(view) == "한글")
        #expect(try selection(view) == NSRange(location: 1, length: 0))
        #expect(remote.events.isEmpty)
        view.unmarkText()
        #expect(remote.events == expected([.text("한글")]))
    }

    @Test(arguments: [
        ("끝👨‍👩‍👧‍👦", 12),
        ("끝한", 4)
    ])
    func backspaceDeletesOneWholeComposedCharacter(_ text: String, _ caret: Int) throws {
        let (view, remote) = makeInput()
        view.setMarkedText(text, selectedRange: NSRange(location: caret, length: 0))
        #expect(documentLength(view) == caret)
        #expect(markedText(view) == text)

        view.deleteBackward()

        #expect(markedText(view) == "끝")
        #expect(try selection(view) == NSRange(location: 1, length: 0))
        #expect(remote.events.isEmpty)
        view.unmarkText()
        #expect(remote.events == expected([.text("끝")]))
    }

    @Test(arguments: [nil, ""] as [String?])
    func cancellingCompositionDoesNotLeakIntoTheNextWord(_ cancellation: String?) throws {
        let (view, remote) = makeInput()
        view.setMarkedText("취소", selectedRange: NSRange(location: 2, length: 0))

        view.setMarkedText(cancellation, selectedRange: NSRange(location: 0, length: 0))
        view.unmarkText()

        #expect(remote.events.isEmpty)
        #expect(view.markedTextRange == nil)
        #expect(try selection(view) == NSRange(location: 0, length: 0))
        view.setMarkedText("새말", selectedRange: NSRange(location: 2, length: 0))
        view.unmarkText()
        #expect(remote.events == expected([.text("새말")]))
    }

    @Test func deletingEntireCompositionDoesNotBackspaceRemoteTextUntilCompositionEnds() throws {
        let (view, remote) = makeInput()
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))

        view.deleteBackward()
        view.deleteBackward()

        #expect(markedText(view) == "")
        #expect(try selection(view) == NSRange(location: 0, length: 0))
        #expect(remote.events.isEmpty)
        view.unmarkText()
        #expect(remote.events.isEmpty)
        view.deleteBackward()
        view.setMarkedText("글", selectedRange: NSRange(location: 1, length: 0))
        view.unmarkText()
        #expect(remote.events == expected([.backspace, .text("글")]))
    }

    @Test func consecutiveCompositionPlainTextAndBackspacePreserveRemoteEventOrder() {
        let (view, remote) = makeInput()
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        view.insertText("한글")
        view.unmarkText()
        view.insertText(" ")
        view.insertText("x")
        view.deleteBackward()
        view.setMarkedText("입력", selectedRange: NSRange(location: 2, length: 0))
        view.unmarkText()
        view.deleteBackward()

        #expect(remote.events == expected([
            .text("한글"), .text(" "), .text("x"), .backspace, .text("입력"), .backspace
        ]))
    }

    @Test func staleRangesAfterCompositionShrinksCannotChangeOrCommitText() throws {
        let (view, remote) = makeInput()
        view.setMarkedText("한😀글", selectedRange: NSRange(location: 4, length: 0))
        let oldSelection = try range(view, 1, 3)
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))

        #expect(view.position(from: view.endOfDocument, offset: 1) == nil)
        #expect(view.position(from: view.beginningOfDocument, offset: -1) == nil)
        #expect(view.position(from: view.endOfDocument, offset: Int.max) == nil)
        #expect(view.position(from: view.beginningOfDocument, in: .left, offset: Int.min) == nil)
        #expect(view.text(in: oldSelection) == nil)
        view.selectedTextRange = oldSelection
        view.replace(oldSelection, withText: "잘못된 입력")

        #expect(markedText(view) == "한")
        #expect(try selection(view) == NSRange(location: 1, length: 0))
        #expect(remote.events.isEmpty)
        view.unmarkText()
        #expect(remote.events == expected([.text("한")]))
    }

    private func makeInput() -> (RemoteDesktopUIView, InputRecorder) {
        let view = RemoteDesktopUIView(frame: .zero)
        let remote = InputRecorder()
        view.onKey = { key, pressed in if pressed { remote.events.append(key) } }
        return (view, remote)
    }

    private func range(_ view: RemoteDesktopUIView, _ location: Int, _ length: Int) throws -> UITextRange {
        let start = try #require(view.position(from: view.beginningOfDocument, offset: location))
        let end = try #require(view.position(from: start, offset: length))
        return try #require(view.textRange(from: start, to: end))
    }

    private func markedText(_ view: RemoteDesktopUIView) -> String? {
        view.markedTextRange.flatMap { view.text(in: $0) }
    }

    private func documentLength(_ view: RemoteDesktopUIView) -> Int {
        view.offset(from: view.beginningOfDocument, to: view.endOfDocument)
    }

    private func selection(_ view: RemoteDesktopUIView) throws -> NSRange {
        let selected = try #require(view.selectedTextRange)
        return NSRange(
            location: view.offset(from: view.beginningOfDocument, to: selected.start),
            length: view.offset(from: selected.start, to: selected.end)
        )
    }
}

@MainActor
private final class InputRecorder {
    enum Event { case text(String), backspace }
    var events: [UInt32] = []
}

private func expected(_ events: [InputRecorder.Event]) -> [UInt32] {
    events.flatMap { event -> [UInt32] in
        switch event {
        case .backspace: return [0xff08]
        case .text(let text): return text.unicodeScalars.map { $0.value <= 255 ? $0.value : 0x01000000 | $0.value }
        }
    }
}
