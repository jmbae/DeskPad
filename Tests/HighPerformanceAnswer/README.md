# HP control / media answer fixtures

Run `python3 Tests/HighPerformanceAnswer/run.py`. The runner creates synthetic binary-plist / zlib / protobuf negotiation replies in a temporary directory. No captured session bytes or SRTP keys are checked in.

`AppleHPControlParser.append` consumes **decrypted bytes**, which may be partial messages or multiple messages. It frames status, Bell, plain clipboard, bounded known metadata rectangles, cursor, DesktopSize and rekey. Unknown opcodes and rectangle encodings fail closed. It does not decode framebuffer codecs, compressed clipboard, or unverified alternate answer schemas.

For a rekey event, install the returned 36-byte payload on the existing `AppleHPRecordCipher`, preserving its counters, **before decrypting another wire record**. The parser rejects rekey followed by additional bytes in that same plaintext segment or by remaining rectangles. Feed the cipher one encrypted record at a time; never decrypt a coalesced buffer across a rekey first.

Encoding 1010 has more than one schema. Version-2 / kind-2 replies have an 18-byte header after their u16 length, followed by three length-delimited binary plists (audio, video1, optional video2). Version-1 announcements remain opaque. Confirmed reply fields include stream SSRC, selected video payload type, and video width/height. Keys remain from the original offer; the reply contains no replacement SRTP keys.

Top-level protobuf field 12 is retained as `opaqueField12`, **not AudioSpecificConfig**. Observed bytes `08 04 20 04` do not establish AAC-ELD sample rate, frame size or ASC. These parameters must not be inferred from that field. Audio description scalar semantics are intentionally retained as opaque parsed fields.

The protocol document's little-endian offer flags contradict the existing offer builder's big-endian comment. This reply fixture contains a different status word and provides no evidence to resolve offer flags; changing the offer requires a separately justified integration decision.
