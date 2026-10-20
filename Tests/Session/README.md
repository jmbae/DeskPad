Run from the repository root on macOS with Xcode command line tools installed:

```sh
python3 Tests/Session/run.py
```

The runner compiles the actual session model and transport with `swiftc`, opens loopback TCP listeners, and exercises RFB 3.8 exchanges. It needs no app test target, simulator, external VNC service, or Python packages. The first-frame deadline case takes about 21 seconds each; the full suite takes about 100 seconds. Use `--quick` to omit the slow Raw case and three deadline cases.

A delayed 4 MiB Raw payload takes over 20 seconds and must still connect with exact pixels. Raw reads use a fixed 20-second allowance plus one second per MiB, capped at 120 seconds; only validated nonempty Raw headers can replace the initial 20-second first-frame deadline. Continuous payload trickle does not renew the budget.

Coverage includes empty updates before first pixels, exact pixel conversion, reconnect while a read is pending, model deallocation during an active read, rejected framebuffer bounds, terminal errors followed by late network activity, an independent first-frame deadline despite continuous bells, empty updates, zero-area Raw rectangles, or repeated DesktopSize messages, Latin-1 clipboard receive/send and Unicode refusal, RFB 3.5 fallback to 3.3 with verified DES authentication and SecurityResult consumption, and 50 ordered key-down/key-up pairs. A resize regression holds Control and a pointer button, waits for DesktopSize, verifies new presses are refused while release events reach the server, and receives the next Raw frame. Bounded state predicates and explicit first-frame/input acknowledgments avoid depending on machine-speed sleeps. Apple authentication is checked against an RFC 2409 group with a known server exponent: Python derives the shared secret from the transmitted client public key, and system OpenSSL decrypts and checks the credentials. A rejected Apple authentication result without a reason string must fail promptly. The server harness propagates unexpected EOF and requires every assertion to complete. This validates the production Montgomery implementation and fixed-width secret encoding without exposing production private keys.

The clipboard deliberately uses classic RFB Latin-1 and reports a nonfatal `clipboardError` for unsupported text. Extended Unicode clipboard and cursor pseudo-encodings are not negotiated. The tests do not claim encrypted transport or server identity verification; classic RFB and Apple screen-sharing authentication retain their protocol properties.

Server termination cases cover clean EOF while connected, a TCP reset, and EOF midway through the initial Raw payload. Each requires a distinct ended state with cleared frame/dimensions/clipboard, rejects input after termination, reconnects on a new TCP connection, and verifies fresh input reaches that connection. Locally triggered response/first-frame deadlines retain the failed state; they are not presented as server termination. No automatic reconnect is attempted. These loopback tests do not identify why a real server stopped sharing or detect a silent network blackhole.

## Compressed frames and pixel conversion

`python3 Tests/Session/run-zrle.py` builds the production decoder with optimization; add `--debug` for an unoptimized benchmark. Python's independent zlib compressor supplies all ZRLE tile modes, row padding, 65×65 edge tiles, persistent-stream rectangles, invalid palettes/runs, oversized/truncated data, a compression bomb, and expired/in-progress decode budgets. Synthetic 6016×3384 solid and incompressible frames verify the complete RGBA output (SHA-256 for noise) and measure decoding. The Raw benchmark compares every output byte with the previous conversion and checks an inset rectangle's unaffected neighbors.

The TCP suite now verifies preferred ZRLE negotiation, persistent rectangles, malformed ZRLE bounds/length/palette/bomb rejection, and a fixed stalled-payload timeout. Raw remains advertised and all original Raw tests run. ZRLE uses a single persistent zlib stream per connection, 64×64 tiles, and three-byte BGR CPIXELs for the client's negotiated pixel format. The [RFB protocol specification](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#zrle-encoding) and [RFC 6143](https://datatracker.ietf.org/doc/html/rfc6143) define the format. Real Mac support is established by observing encoding 16 on that server, not assumed from the standard.

Compressed receive length is bounded by rectangle size and a 128 MiB absolute limit. Inflated bytes are bounded by the worst legal tile payload, and decode checks the same fixed receive deadline during inflate and tile processing. No progress or repeated message renews a payload budget. DEBUG logs include only sizes, rectangle counts, and receive/decode/update timings.

## Input latency and ordering

Run `Tests/Session/run-input-queue.sh` for deterministic suspended-transport tests.
A 4,000-movement burst must retain only the latest pending motion between button
edges, keys, clipboard commands and wheel events. The harness also checks that
cancellation removes pending input, an old suspended sender cannot drain a new
session, and a suspended send does not retain the queue owner.
