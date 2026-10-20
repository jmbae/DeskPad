# DeskPad

DeskPad is a native VNC client for iPhone and iPad, built with SwiftUI. It lets you save VNC server connections, connect to a remote desktop, and interact with it using touch or a keyboard.

<p align="left">
  <img src="AppIcon.png" alt="DeskPad app icon" width="120" />
</p>

## Features

- Add, edit, and delete saved VNC connections, with a configurable server name, host, port, and optional username
- Store connection details in the app and passwords in the iOS Keychain
- Connect to VNC servers using RFB 3.3–3.8 negotiation
- Support None, standard VNC password, and Apple Diffie–Hellman authentication security types
- Render Raw, CopyRect, and DesktopSize framebuffer updates
- Send pointer movement, clicks, and drags from the remote desktop view
- Send text and common special-key input using the software or hardware keyboard
- Show connection progress and failures, with an option to retry

## Security and limitations

DeskPad does not provide TLS encryption. Authentication does not encrypt the ongoing VNC session: remote screen contents and input are transmitted without transport encryption. Standard VNC password authentication also uses weak DES-based challenge-response. Use DeskPad only on a trusted private network or through a VPN, and do not expose a VNC server directly to the public internet.

The current client supports only the listed authentication types and framebuffer encodings. Advanced gestures such as zooming, panning, scrolling, and secondary-click input, as well as clipboard synchronization and TLS, are not currently supported.

## Requirements

- Xcode 27 or later
- iOS/iPadOS 27.0 or later
- iPhone or iPad

## Getting started

1. Clone this repository.
2. Open `DeskPad.xcodeproj` in Xcode.
3. Select an iPhone or iPad simulator, or a connected device.
4. Build and run the `DeskPad` app.
5. Add a VNC server connection. The default port is `5900`.

## Project structure

- `DeskPad/App/`: app entry point
- `DeskPad/Connections/`: saved connection metadata and Keychain credentials
- `DeskPad/Models/`: app data models
- `DeskPad/UI/`: connection list, connection editor, and remote desktop UI
- `DeskPad/VNC/`: VNC session, RFB protocol, framebuffer decoding, and input handling
- `DeskPad/HighPerformance/`: high-performance media transport, security, and playback
- `DeskPad/Assets.xcassets`: app icon and accent color

## Contributing

Issues and pull requests are welcome. For larger changes, please open an issue first to discuss scope and implementation.

## Credits

- [Ned Park](https://africastart.com)

## License

Licensed under the [MIT](LICENSE) license.
