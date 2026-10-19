import UIKit

// MARK: - Text Input Helpers

/// Minimal UITextPosition subclass for UITextInput conformance.
private class SimpleTextPosition: UITextPosition {
    let index: Int
    init(_ index: Int) { self.index = index }
}

/// Minimal UITextRange subclass for UITextInput conformance.
private class SimpleTextRange: UITextRange {
    private let _start: SimpleTextPosition
    private let _end: SimpleTextPosition

    override var start: UITextPosition { _start }
    override var end: UITextPosition { _end }
    override var isEmpty: Bool { _start.index >= _end.index }

    init(start: Int, end: Int) {
        _start = SimpleTextPosition(start)
        _end = SimpleTextPosition(end)
    }
}

protocol RemoteDesktopUIViewDelegate: AnyObject {
    func remoteDesktopView(_ view: RemoteDesktopUIView, keyDown key: UIKey)
    func remoteDesktopView(_ view: RemoteDesktopUIView, keyUp key: UIKey)
    func remoteDesktopView(_ view: RemoteDesktopUIView, didInsertText text: String)
    func remoteDesktopViewDidDeleteBackward(_ view: RemoteDesktopUIView)
    func remoteDesktopView(_ view: RemoteDesktopUIView, pointerMovedTo desktopPoint: CGPoint)
    func remoteDesktopView(_ view: RemoteDesktopUIView, mouseDown button: Int, at desktopPoint: CGPoint)
    func remoteDesktopView(_ view: RemoteDesktopUIView, mouseUp button: Int, at desktopPoint: CGPoint)
    func remoteDesktopView(_ view: RemoteDesktopUIView, scrollDeltaY: CGFloat)
}

final class RemoteDesktopUIView: UIView {

    weak var delegate: RemoteDesktopUIViewDelegate?

    /// The remote desktop image to render
    var desktopImage: CGImage? {
        didSet { setNeedsDisplay() }
    }

    /// Remote desktop pixel dimensions for coordinate mapping
    var desktopSize: CGSize = .zero

    // Zoom/pan state
    private var zoomScale: CGFloat = 1.0
    private var panOffset: CGPoint = .zero

    // Virtual keyboard state
    private var wantsVirtualKeyboard = false
    private static let emptyInputView = UIView(frame: .zero)

    // IME composition state (UITextInput)
    private var _markedText: String?
    // UITextInput positions and NSRange selections are UTF-16 offsets.
    private var _markedSelection = NSRange(location: 0, length: 0)
    private weak var _inputDelegate: (any UITextInputDelegate)?
    private lazy var _tokenizer: UITextInputStringTokenizer = UITextInputStringTokenizer(textInput: self)

    /// Recognizer for trackpad/mouse scroll events (used by gesture delegate)
    private var indirectScrollRecognizer: UIGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        setupGestureRecognizers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        setupGestureRecognizers()
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Returns an empty view to suppress the virtual keyboard, or nil to show it.
    override var inputView: UIView? {
        wantsVirtualKeyboard ? nil : Self.emptyInputView
    }

    /// Toggle the virtual keyboard visibility.
    func toggleVirtualKeyboard() {
        wantsVirtualKeyboard.toggle()
        if isFirstResponder {
            resignFirstResponder()
            becomeFirstResponder()
        } else {
            becomeFirstResponder()
        }
    }

    // MARK: - Rendering

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let image = desktopImage else { return }

        let displayRect = calculateDisplayRect()

        ctx.saveGState()

        // Apply zoom and pan
        ctx.translateBy(x: panOffset.x, y: panOffset.y)
        ctx.scaleBy(x: zoomScale, y: zoomScale)

        // Draw image
        UIImage(cgImage: image).draw(in: displayRect)

        ctx.restoreGState()
    }

    // MARK: - Coordinate Mapping

    /// Convert a point in view coordinates to remote desktop coordinates
    func viewPointToDesktopPoint(_ viewPoint: CGPoint) -> CGPoint {
        guard desktopSize.width > 0 && desktopSize.height > 0 else { return .zero }

        let displayRect = calculateDisplayRect()

        let adjustedPoint = CGPoint(
            x: (viewPoint.x - panOffset.x) / zoomScale - displayRect.origin.x,
            y: (viewPoint.y - panOffset.y) / zoomScale - displayRect.origin.y
        )

        let desktopX = adjustedPoint.x / displayRect.width * desktopSize.width
        let desktopY = adjustedPoint.y / displayRect.height * desktopSize.height

        return CGPoint(
            x: max(0, min(desktopX, desktopSize.width - 1)),
            y: max(0, min(desktopY, desktopSize.height - 1))
        )
    }

    private func calculateDisplayRect() -> CGRect {
        guard desktopSize.width > 0 && desktopSize.height > 0 else {
            return bounds
        }

        let viewAspect = bounds.width / bounds.height
        let desktopAspect = desktopSize.width / desktopSize.height

        if desktopAspect > viewAspect {
            // Fit to width
            let h = bounds.width / desktopAspect
            return CGRect(x: 0, y: (bounds.height - h) / 2,
                          width: bounds.width, height: h)
        } else {
            // Fit to height
            let w = bounds.height * desktopAspect
            return CGRect(x: (bounds.width - w) / 2, y: 0,
                          width: w, height: bounds.height)
        }
    }

    // MARK: - Gesture Recognizers

    private func setupGestureRecognizers() {
        // Hover (mouse/trackpad movement)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        addGestureRecognizer(hover)

        // Single tap = left click
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        // Two-finger tap = right click
        let rightClick = UITapGestureRecognizer(target: self, action: #selector(handleRightClick))
        rightClick.numberOfTouchesRequired = 2
        addGestureRecognizer(rightClick)

        // Pinch to zoom
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        addGestureRecognizer(pinch)

        // Two-finger touch scroll (direct touch only)
        let touchScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        touchScroll.minimumNumberOfTouches = 2
        touchScroll.maximumNumberOfTouches = 2
        addGestureRecognizer(touchScroll)

        // Trackpad/mouse scroll (indirect scroll events)
        let indirectScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        indirectScroll.allowedScrollTypesMask = [.continuous, .discrete]
        indirectScroll.delegate = self
        self.indirectScrollRecognizer = indirectScroll
        addGestureRecognizer(indirectScroll)

        // Single finger drag for pointer movement (touch)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        // Ensure taps are recognized as clicks before drag can begin.
        // Without this, slight finger movement during a tap triggers the pan
        // gesture, which sends a drag sequence instead of a clean click.
        drag.require(toFail: tap)
        addGestureRecognizer(drag)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        delegate?.remoteDesktopView(self, pointerMovedTo: desktopPoint)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        
        // Ensure we are first responder to keep receiving keyboard events
        if !isFirstResponder {
            becomeFirstResponder()
        }
        
        // Move cursor to tap position first so the server registers the location,
        // then send the click. This is important for macOS login screen and other
        // UI elements that require cursor presence before responding to clicks.
        delegate?.remoteDesktopView(self, pointerMovedTo: desktopPoint)
        delegate?.remoteDesktopView(self, mouseDown: 0, at: desktopPoint)
        delegate?.remoteDesktopView(self, mouseUp: 0, at: desktopPoint)
    }

    @objc private func handleRightClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)
        delegate?.remoteDesktopView(self, mouseDown: 2, at: desktopPoint)
        delegate?.remoteDesktopView(self, mouseUp: 2, at: desktopPoint)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .changed {
            zoomScale *= recognizer.scale
            zoomScale = max(0.5, min(zoomScale, 5.0))
            recognizer.scale = 1.0
            setNeedsDisplay()
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        delegate?.remoteDesktopView(self, scrollDeltaY: translation.y)
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        let desktopPoint = viewPointToDesktopPoint(viewPoint)

        switch recognizer.state {
        case .began:
            delegate?.remoteDesktopView(self, mouseDown: 0, at: desktopPoint)
        case .changed:
            delegate?.remoteDesktopView(self, pointerMovedTo: desktopPoint)
        case .ended, .cancelled:
            delegate?.remoteDesktopView(self, mouseUp: 0, at: desktopPoint)
        default:
            break
        }
    }

    // MARK: - Keyboard Input

    /// Determine whether a key press should be handled directly as a VNC key event
    /// rather than routed through the iOS text input system.
    /// Modifier keys, special keys, and keyboard shortcuts (Ctrl/Alt/Cmd+key)
    /// are handled directly. Printable characters without command modifiers are
    /// routed through the text input system so that IME composition (Korean, etc.) works.
    private func shouldDirectlyHandle(_ key: UIKey) -> Bool {
        if KeySymMapping.isNonPrintableKey(key.keyCode) { return true }
        let shortcutModifiers: UIKeyModifierFlags = [.control, .alternate, .command]
        return !key.modifierFlags.intersection(shortcutModifiers).isEmpty
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandledPresses.insert(press)
                continue
            }
            if shouldDirectlyHandle(key) {
                // Commit any in-progress IME composition (e.g. Korean syllable)
                // before sending the key directly to VNC, so composed text is
                // not lost when Space, Return, arrows, etc. are pressed.
                if _markedText != nil {
                    unmarkText()
                }
                delegate?.remoteDesktopView(self, keyDown: key)
            } else {
                unhandledPresses.insert(press)
            }
        }
        if !unhandledPresses.isEmpty {
            super.pressesBegan(unhandledPresses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandledPresses.insert(press)
                continue
            }
            if shouldDirectlyHandle(key) {
                delegate?.remoteDesktopView(self, keyUp: key)
            } else {
                unhandledPresses.insert(press)
            }
        }
        if !unhandledPresses.isEmpty {
            super.pressesEnded(unhandledPresses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandledPresses.insert(press)
                continue
            }
            if shouldDirectlyHandle(key) {
                delegate?.remoteDesktopView(self, keyUp: key)
            } else {
                unhandledPresses.insert(press)
            }
        }
        if !unhandledPresses.isEmpty {
            super.pressesCancelled(unhandledPresses, with: event)
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension RemoteDesktopUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Prevent the indirect scroll recognizer from responding to direct touches.
        // Scroll events (trackpad/mouse) bypass this method and are still handled.
        if gestureRecognizer === indirectScrollRecognizer {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow indirect scroll to coexist with other recognizers (e.g. hover)
        if gestureRecognizer === indirectScrollRecognizer {
            return true
        }
        return false
    }
}

// MARK: - UITextInput (Keyboard & IME)

extension RemoteDesktopUIView: UITextInput {

    // MARK: UIKeyInput

    var hasText: Bool { true }

    private var localTextLength: Int { (_markedText ?? "").utf16.count }

    private func updateComposition(_ text: String?, selection: NSRange) {
        _inputDelegate?.textWillChange(self)
        _inputDelegate?.selectionWillChange(self)
        _markedText = text
        let length = localTextLength
        let location = min(max(0, selection.location), length)
        _markedSelection = NSRange(location: location, length: min(max(0, selection.length), length - location))
        _inputDelegate?.selectionDidChange(self)
        _inputDelegate?.textDidChange(self)
    }

    func insertText(_ text: String) {
        updateComposition(nil, selection: NSRange(location: 0, length: 0))
        delegate?.remoteDesktopView(self, didInsertText: text)
    }

    func deleteBackward() {
        guard let marked = _markedText else {
            delegate?.remoteDesktopViewDidDeleteBackward(self)
            return
        }
        var deletion = _markedSelection
        if deletion.length == 0 {
            guard deletion.location > 0 else { return }
            deletion = (marked as NSString).rangeOfComposedCharacterSequence(at: deletion.location - 1)
        }
        let text = (marked as NSString).replacingCharacters(in: deletion, with: "")
        updateComposition(text, selection: NSRange(location: deletion.location, length: 0))
    }

    // MARK: Marked Text (IME Composition)

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        updateComposition(markedText, selection: selectedRange)
    }

    func unmarkText() {
        let text = _markedText
        updateComposition(nil, selection: NSRange(location: 0, length: 0))
        if let text, !text.isEmpty {
            delegate?.remoteDesktopView(self, didInsertText: text)
        }
    }

    var markedTextRange: UITextRange? {
        guard _markedText != nil else { return nil }
        return SimpleTextRange(start: 0, end: localTextLength)
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    // MARK: Selection & Document Positions (UTF-16)

    var selectedTextRange: UITextRange? {
        get { SimpleTextRange(start: _markedSelection.location, end: NSMaxRange(_markedSelection)) }
        set {
            guard let newValue, let range = localRange(newValue) else { return }
            _inputDelegate?.selectionWillChange(self)
            _markedSelection = range
            _inputDelegate?.selectionDidChange(self)
        }
    }

    var beginningOfDocument: UITextPosition { SimpleTextPosition(0) }
    var endOfDocument: UITextPosition { SimpleTextPosition(localTextLength) }

    // MARK: Text & Range Queries

    private func localRange(_ range: UITextRange) -> NSRange? {
        guard let start = range.start as? SimpleTextPosition,
              let end = range.end as? SimpleTextPosition,
              start.index >= 0, end.index >= start.index,
              end.index <= localTextLength else { return nil }
        return NSRange(location: start.index, length: end.index - start.index)
    }

    func text(in range: UITextRange) -> String? {
        guard let range = localRange(range) else { return nil }
        return ((_markedText ?? "") as NSString).substring(with: range)
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = localRange(range) else { return }
        guard let marked = _markedText else {
            if !text.isEmpty { delegate?.remoteDesktopView(self, didInsertText: text) }
            return
        }
        let updated = (marked as NSString).replacingCharacters(in: range, with: text)
        updateComposition(updated, selection: NSRange(location: range.location + text.utf16.count, length: 0))
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? SimpleTextPosition,
              let to = toPosition as? SimpleTextPosition,
              from.index >= 0, from.index <= localTextLength,
              to.index >= 0, to.index <= localTextLength else { return nil }
        return SimpleTextRange(start: min(from.index, to.index), end: max(from.index, to.index))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let pos = position as? SimpleTextPosition else { return nil }
        let (target, overflow) = pos.index.addingReportingOverflow(offset)
        guard !overflow, target >= 0, target <= localTextLength else { return nil }
        return SimpleTextPosition(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard offset != Int.min else { return nil }
        return self.position(from: position, offset: (direction == .left || direction == .up) ? -offset : offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? SimpleTextPosition,
              let b = other as? SimpleTextPosition else { return .orderedSame }
        if a.index < b.index { return .orderedAscending }
        if a.index > b.index { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? SimpleTextPosition,
              let b = toPosition as? SimpleTextPosition else { return 0 }
        return b.index - a.index
    }

    // MARK: Input Delegate & Tokenizer

    var inputDelegate: (any UITextInputDelegate)? {
        get { _inputDelegate }
        set { _inputDelegate = newValue }
    }

    var tokenizer: any UITextInputTokenizer { _tokenizer }

    // MARK: Layout & Geometry (stubs)

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let r = range as? SimpleTextRange else { return nil }
        return (direction == .left || direction == .up) ? r.start : r.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let pos = position as? SimpleTextPosition else { return nil }
        return SimpleTextRange(start: pos.index, end: pos.index)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect { .zero }

    func caretRect(for position: UITextPosition) -> CGRect { .zero }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? { SimpleTextPosition(0) }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.start }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: UITextInputTraits

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }
}
