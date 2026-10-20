# High-performance media packet and clock checks

Run `Tests/HighPerformanceMedia/run.sh` on a host with Swift installed. This is a pure Foundation executable; it does not connect to a server or change remote display settings.

`HighPerformanceRTPPacket` consumes **authenticated and decrypted** RTP; `HighPerformanceSenderReport.parseCompound` consumes authenticated/decrypted RTCP with the SRTCP trailer already removed. Neither performs SRTP decryption, replay protection, or RTP/RTCP multiplex classification. Callers must apply those before parsing.

`HighPerformanceMediaClock` assigns sender-relative presentation seconds from RTCP Sender Reports. Each SSRC's clock rate must come from negotiation, not be assumed equal across audio and video. Streams without a Sender Report have no presentation time. Periodic reports are required to keep RTP deltas within half the 32-bit timestamp range. Reset on reconnect, renegotiation or SSRC reuse. A decoder/renderer must anchor these times to a local monotonic playout clock and manage jitter/loss separately.

This component is groundwork only: there is no socket receiver, codec decoding, audio playback, or visible synchronized rendering wired into DeskPad yet. Synthetic tests establish packet bounds and clock arithmetic, not live Apple interoperability or perceptual A/V sync.
