# High performance connection — integration and live acceptance pending

The previous prototype received authenticated SRTP but did not present a visible
frame. Its virtual-display request blanked the host and the user restored the
resolution manually. That request is not part of the new mirror bootstrap. The
old `--deskpad-hp-probe` still rejects before TCP. Release builds do not enable HP.

## Current isolated branch

`codex/hp-completion` includes the latest stable main, preserving Korean input,
scroll settings, remote cursor handling and large framebuffer behavior.
The DEBUG-only `--deskpad-hp-mirror` uses no SetDisplayConfiguration or alternate
user session command. It verifies/pins the RSA key before sending credentials,
uses a bounded UDP queue, validates server media answers, handles control record
fragmentation/rekey, sends rate-limited SRTCP PLI, and aborts TCP on teardown.
The initial connection is marked connected only after a decoded frame is actually
presented. A startup deadline and authenticated-media inactivity timeout bound
failed sessions. Decoder failures terminate the connection rather than leaving
an apparently connected black screen. Video codec dimensions do not replace the
remote desktop's input coordinate space.

Two independently reproduced playback blockers are fixed: waiting for audio
before video startup, and rejecting an initial non-IDR H.264 intra picture.
All VCL slices must be validated as intra; arbitrary type-1 packets are not
accepted as keyframes. Late audio retains its independent sender-report clock.
The native synchronizer no longer waits for an empty audio renderer.

## Verified on 2026-10-20

- Four iPad simulator media tests: actual displayed H.264 frame with idle audio,
  actual non-IDR intra-frame display, synthetic AAC-ELD PCM decode, and the wire
  profile's two four-byte silence samples decoding to 480 silent PCM frames.
- 28 existing input XCTest cases passed on the same integration build.
- Offline media clocks, packet bounds, SRTP/SRTCP vectors, record encryption and
  rekey, native decoder, pipeline, bounded receive queue, control/answer parser,
  mirror handshake, lifecycle and server-trust harnesses passed.
- Independent review of credential verification, display-changing messages,
  failure propagation and initial encryption boundary; identified issues fixed.

## Remaining release acceptance

Live testing after unlock now authenticates against the saved remote Mac and
negotiates 6016×3384 HEVC (payload type 100). Authenticated audio and video RTP
and both sender reports arrive. H.264 at this canvas produced no video packets;
a separate local synthetic encoder probe also failed at 6016×3384 for H.264,
while HEVC succeeded. This is supporting evidence, not a remote encoder log.

The first live remote desktop was visibly presented at 22:46 KST after fixing
HEVC framing (this server omits DON) and replacing the 64-packet inbox with a
queue bounded by both 8192 packets and 12 MiB. Automatic framing selection now
requires a fully validated VPS/SPS/PPS aggregation packet. Remaining UDP loss
requires periodic startup keyframe requests; no packet loss is concealed. Six native simulator tests pass including displayed HEVC 4:2:0 and
4:4:4, but do not establish real-host playback. Non-silent remote audio,
perceptual A/V sync, sustained playback, input and reconnect remain unverified.
No display configuration command is sent. Local display measurements are not
proof of the remote physical display state.

The observed answer does not provide a validated AAC AudioSpecificConfig; its
protobuf field 12 is opaque, not assumed to be ASC. Actual supported audio
negotiation must be verified before enabling this as a release feature. Multiple
video SSRCs/HEVC compositing and unsupported control encodings fail closed.
There is no validated protocol for restoring an altered physical display mode;
therefore virtual-display/curtain configuration remains excluded, not described
as repaired. Stable main/TestFlight remain unchanged until live acceptance passes.
