# Local verification

The shared DeskPad scheme includes the DeskPadTests unit-test target. Test sources live in the repository-root DeskPadTests directory, outside the application source group.

```sh
xcodebuild test -project DeskPad.xcodeproj -scheme DeskPad \
  -destination 'platform=iOS Simulator,id=<IPAD_SIMULATOR_UDID>' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

The upstream app requires iOS 27. If the local simulator runtime is iOS 26.5, temporarily replace `IPHONEOS_DEPLOYMENT_TARGET = 27.0;` with `IPHONEOS_DEPLOYMENT_TARGET = 26.0;` in a backed-up project.pbxproj before running tests, then restore the original file immediately afterward. Xcode destination discovery can reject the simulator even when a command-line deployment override is supplied. Never commit this temporary compatibility change. Verify the final Release build separately without that override:

```sh
xcodebuild build -project DeskPad.xcodeproj -scheme DeskPad \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

An unsigned device build is not an installable signed IPA or a TestFlight upload. Standalone protocol/session/storage harnesses under Tests exercise their respective layers; run them as documented in each harness. UIKit IME tests exercise public text-input operations and emitted key events. Real iPad keyboard/trackpad behavior and a real Mac Screen Sharing session require separate device acceptance checks.
