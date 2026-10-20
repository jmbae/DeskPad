# Single-display media coordinator

Run `Tests/HighPerformancePipeline/run.sh`. Tests use a recording output sink: no speaker playback, network or display mutation.

The main-actor coordinator owns packet-to-access-unit-to-native-sample state and feeds any `HighPerformanceMediaOutput`, including `HighPerformancePlayback`. Network callers must authenticate/decrypt with SRTP/SRTCP first, reorder video packets, strip the negotiated AAC payload wrapper and pass clock rates established by negotiation. No raw-socket or unauthenticated input is accepted by this API contract.

Both audio and video need RTCP Sender Reports before startup. It keeps at most two complete video frames and 200 ms of audio, both by packet count and RTP duration. If the audio/video preroll does not overlap, it waits or requests an IDR through `onNeedsKeyframe`; it never substitutes packet arrival times. Video loss/overflow drops dependent frames until a keyframe. Output backpressure is surfaced to the caller. A first keyframe and its dependent frames are not discarded individually in order to fake low latency.

This is a negotiated **single-display H.264 + 48 kHz / 480-frame AAC-ELD** path. Four independent video depacketizers are bounded, but only the first video SSRC is rendered. It does not composite multi-SSRC tiled HEVC. Reconnect must reset the coordinator and replace transport receivers with fresh negotiated keys. The native output's `videoLayer` must be attached to the app UI by the caller.

Tests establish common sender-time alignment, withheld playback until both SRs arrive, preroll/SSRC bounds, loss recovery signaling and reset; they do not establish live Apple interoperability or perceptual synchronization.

`videoPayloadType` is negotiated input (default 100); pass 123 when the session negotiates that H.264 payload type. Other video PTs are rejected rather than auto-detected. Values outside the 7-bit RTP range and the configured audio PT 101 are rejected. This change does not establish that any arbitrary PT carries H.264.
