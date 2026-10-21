# DeskPad

DeskPad is a native SwiftUI VNC client for iPhone and iPad. Save server connections, view remote desktops, and interact with them using touch, a keyboard, or a pointer.

[한국어](README_kr.md)

<p align="left">
  <img src="AppIcon.png" alt="DeskPad app icon" width="120" />
</p>

## Features

- Add, edit, and delete saved connections with a display name, host, port, and optional username
- Store connection metadata in the app and passwords in the iOS Keychain; migrate legacy connection data
- Negotiate RFB 3.3, 3.7, and 3.8 with VNC servers
- Support None, standard VNC password, and Apple Diffie–Hellman authentication where offered by the server
- Decode Raw, CopyRect, DesktopSize, and ZRLE framebuffer updates, with remote cursor support
- Fit the desktop to the screen or view it at actual size; pinch to zoom and pan the viewport
- Send pointer movement, clicks, drags, scrolling, and secondary clicks from touch or a compatible pointer/trackpad
- Send text, keyboard shortcuts, and special keys with the software or hardware keyboard; support IME composition, including Korean
- Send and receive clipboard text using classic RFB Latin-1 (up to 1 MiB)
- Choose full-color or low-latency display quality, and see connection errors with an option to retry

## Security and limitations

DeskPad does not provide TLS or transport encryption for ordinary RFB sessions. Authentication does not encrypt the ongoing session: remote screen contents and input are transmitted without transport encryption. Standard VNC password authentication uses weak DES-based challenge-response, and None security provides no authentication. Apple Diffie–Hellman authentication does not encrypt all subsequent RFB traffic. Use DeskPad only on a trusted private network or through a VPN, and do not expose a VNC server directly to the public internet.

Clipboard support is limited to classic RFB Latin-1 text; extended Unicode clipboard encoding is not negotiated. Keyboard text is subject to RFB keysym and server limitations. Available pointer and gesture behavior depends on the device and input source.

The Apple-specific high-performance media code in `DeskPad/HighPerformance/` is experimental and not a release-ready or generally supported feature. Visible playback, synchronized audio/video, reliable teardown, and display restoration have not been verified. See [the experiment status](docs/HP-EXPERIMENT-STATUS.md); do not rely on this path for normal connections.

## Requirements

- Xcode 27 or later
- iOS/iPadOS 27.0 or later (the current Xcode project deployment target)
- iPhone or iPad

## Getting started

1. Clone this repository.
2. Open `DeskPad.xcodeproj` in Xcode.
3. Select an iPhone or iPad simulator, or a connected device.
4. Build and run the `DeskPad` app.
5. Add a VNC server connection. The default port is `5900`.

For test and build commands, simulator caveats, and standalone protocol harnesses, see [docs/TESTING.md](docs/TESTING.md).

## Project structure

- `DeskPad/App/`: app entry point
- `DeskPad/Connections/`: saved connection metadata, legacy migration, and Keychain credentials
- `DeskPad/Models/`: app data models
- `DeskPad/UI/`: connection list/editor, session UI, remote display, pointer, and keyboard input
- `DeskPad/VNC/`: RFB session and input queue, framebuffer decoding, cursor support, and protocol handling
- `DeskPad/HighPerformance/`: experimental Apple-specific media authentication, transport, decoding, and playback
- `DeskPad/Assets.xcassets/`: app icon and accent color
- `DeskPadTests/`: Xcode tests for remote input, rendering, and IME behavior
- `Tests/`: standalone protocol, storage, and media test harnesses

## Contributing

Issues and pull requests are welcome. For larger changes, please open an issue first to discuss scope and implementation.

## Credits

- [Ned Park](https://africastart.com)

## License

Licensed under the [MIT](LICENSE) license.
