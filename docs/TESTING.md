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

## Simulator acceptance with saved credentials

The unsigned simulator test command above is suitable for the isolated test suite, but it does not establish that the installed app can use its saved Keychain credentials. During live acceptance, an unsigned simulator app failed Keychain access with OSStatus `-34018`. Rebuilding with ad-hoc signing enabled resolved that error and allowed the existing saved connection to migrate and connect.

For live simulator acceptance, build and install the signed simulator product. With the locally installed iOS 26.5 runtime:

```sh
xcodebuild build -project DeskPad.xcodeproj -scheme DeskPad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/LiveSimulator \
  IPHONEOS_DEPLOYMENT_TARGET=26.0 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcrun simctl install <IPAD_SIMULATOR_UDID> \
  build/LiveSimulator/Build/Products/Debug-iphonesimulator/DeskPad.app
xcrun simctl launch <IPAD_SIMULATOR_UDID> com.africastart.DeskPad
```

This deployment override applies only to the simulator build. Keep the project's original deployment setting for the final device build. Ad-hoc simulator signing does not produce a signed device distribution package.

See [live QA on 2026-10-20](LIVE-QA-2026-10-20.md) for actual Mac acceptance results and remaining checks.
