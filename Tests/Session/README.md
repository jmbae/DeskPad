Run from the repository root on macOS with Xcode command line tools installed:

```sh
python3 Tests/Session/run.py
```

The runner compiles the actual session model and transport with `swiftc`, opens loopback TCP listeners, and exercises RFB 3.8 exchanges. It needs no app test target, simulator, external VNC service, or Python packages. The first-frame deadline case takes about 21 seconds each; the full suite takes about 55 seconds. Use `--quick` to omit the two deadline cases.

Coverage includes empty updates before first pixels, exact pixel conversion, reconnect while a read is pending, model deallocation during an active read, rejected framebuffer bounds, terminal errors followed by late network activity, an independent first-frame deadline despite continuous bells or repeated DesktopSize messages, Latin-1 clipboard receive/send and Unicode refusal, RFB 3.5 fallback to 3.3 with verified DES authentication and SecurityResult consumption, and 50 ordered key-down/key-up pairs. Apple authentication is checked against an RFC 2409 group with a known server exponent: Python derives the shared secret from the transmitted client public key, and system OpenSSL decrypts and checks the credentials. A rejected Apple authentication result without a reason string must fail promptly. The server harness propagates unexpected EOF and requires every assertion to complete. This validates the production Montgomery implementation and fixed-width secret encoding without exposing production private keys.

The clipboard deliberately uses classic RFB Latin-1 and reports a nonfatal `clipboardError` for unsupported text. Extended Unicode clipboard and cursor pseudo-encodings are not negotiated. The tests do not claim encrypted transport or server identity verification; classic RFB and Apple screen-sharing authentication retain their protocol properties.
