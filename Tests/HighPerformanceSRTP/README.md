# Authenticated media receive tests

Run `Tests/HighPerformanceSRTP/run.sh` (Swift + CommonCrypto). Fixture regeneration optionally uses `python3 Tests/HighPerformanceSRTP/vectors.py` and Python `cryptography`; normal checks use committed synthetic fixtures and require no Python package.

KDF expected values come from RFC 6188 section 7.2: https://www.rfc-editor.org/rfc/rfc6188#section-7.2. Packet generation is an independent Python/OpenSSL implementation of RFC 3711: https://www.rfc-editor.org/rfc/rfc3711. No third-party implementation code or captured session keys are included.

Supported profile: AES-256-CM, HMAC-SHA1-80, 46-byte master key/salt, kdr=0, no MKI, bounded 16 SSRCs, 64-packet replay windows, default key lifetime cap. SRTP initial ROC is zero: attaching mid-session after rollover requires new media negotiation. RTP and RTCP have independent keys and replay state. Authentication precedes decryption and replay-state mutation. Reconnect/re-offer must negotiate fresh keys; never reset replay state while reusing a key/SSRC pair.

These tests establish synthetic profile correctness, not live Apple interoperability. Receiver components do not open sockets or play media.
