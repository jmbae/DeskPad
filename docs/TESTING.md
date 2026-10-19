# Local verification

The shared DeskPad scheme includes the DeskPadTests unit-test target. Test sources live in the repository-root DeskPadTests directory, outside the application source group.

```sh
xcodebuild test -project DeskPad.xcodeproj -scheme DeskPad \
  -destination 'platform=iOS Simulator,id=<IPAD_SIMULATOR_UDID>' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

The upstream app requires iOS 27. If the local simulator runtime is iOS 26.5, add `IPHONEOS_DEPLOYMENT_TARGET=26.0` for local compatibility testing only. This does not change the committed deployment target. Verify the final Release build separately without that override:

```sh
xcodebuild build -project DeskPad.xcodeproj -scheme DeskPad \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

An unsigned device build is not an installable signed IPA or a TestFlight upload. Real iPad keyboard/trackpad behavior and a real Mac Screen Sharing session require separate device acceptance checks.
