# Testing DeskPad input

## Public behavior, not implementation

`IMETextInputTests` drives the real `RemoteDesktopUIView` through `UITextInput`.
A recording delegate captures a single ordered stream of committed strings and
backspaces. It does not replace the view, read private composition fields, or
reimplement the production algorithm. Expected strings and UTF-16 positions are
independent literals.

The nine behavioral tests cover:

- Successive Hangul composition updates remain local; repeated unmarking commits once.
- Final `insertText` replaces the pending composition without another commit.
- Replacing a selected emoji, continuing edits, and committing preserves UTF-16 caret positions.
- Deleting a selected emoji preserves the surrounding Hangul.
- Backspace removes an entire ZWJ emoji or decomposed Hangul grapheme (two parameter cases).
- Both nil and empty-string cancellation leave the next composition clean (two parameter cases).
- Deleting all local composition does not leak remote backspaces; backspace resumes after unmarking.
- Composition, plain insertion, and deletion preserve the exact remote event order.
- Stale ranges and overflowing positions cannot edit or commit invalid text.

`DeskPadUITests` has one server-free flow: empty connection list → add form →
Save disabled without a host → Save enabled with a host → Cancel → empty list.
It deliberately never saves a connection or attempts a network connection.
Assertion-free example tests, launch-only screenshot tests, and launch timing
measurements without a performance budget have been removed.

## Run

Use an available iPad simulator UDID from `xcrun simctl list devices available`.
The UI flow requires an app installation with no saved connections; use a
dedicated fresh test simulator rather than deleting a user's connection store.
It sets English UI language explicitly and leaves the store unchanged, so it
can be repeated on the same empty test installation.

```sh
xcodebuild test \
  -project DeskPad/DeskPad.xcodeproj \
  -scheme DeskPad \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath /path/to/a/new/DeskPad-tests.xcresult

xcrun xcresulttool get test-results summary \
  --path /path/to/a/new/DeskPad-tests.xcresult --format json
```

For just the local input contract, add
`-only-testing:DeskPadTests/IMETextInputTests`.
The input suite contains nine test methods and eleven parameter-expanded
executions. Xcode's top-level summary counts methods, while its per-device
counts include parameter cases. The UI flow adds one method/execution.

## Evidence and limits

The behavioral refactor initially passed against the existing IME fix. It is
characterization and regression coverage, not a claimed new failing-test-first
feature implementation. No production code was changed for this refactor.

Four independent, temporary mutations were then tested in an isolated worktree
and each produced assertion failures (not compilation errors):

- Transmit every intermediate marked string: nine methods failed.
- Keep composition after unmarking, allowing duplicate commit: four methods failed.
- Delete one UTF-16 unit rather than a composed character: two methods failed.
- Advance the replacement caret by character count instead of UTF-16 count: one method failed.

These targeted mutations establish that the tests detect those regressions;
they are not an exhaustive mutation score. Mutations are not included in the
application or this branch.

Automated results do **not** establish physical iPad keyboard behavior,
hardware shortcuts, VNC transmission, Mac input-method compatibility, or a
TestFlight build. Validate those separately on an iPad connected to a Mac,
including repeated Hangul words, mixed Hangul/emoji edits, cancellation,
backspace, and keyboard shortcuts in the intended Mac applications.
