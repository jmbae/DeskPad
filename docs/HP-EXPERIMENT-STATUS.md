# High performance experiment — not release ready

2026-10-20: The live probe authenticated and received SRTP audio/video, but no visible simulator playback was established. Sending virtual display configuration blanked the host display and the user reported that its resolution did not recover after disconnect. The user restored the resolution manually. Framebuffer dimensions do not establish the physical display mode.

The debug probe now rejects before opening a TCP connection. No further live HP tests are permitted by this implementation until display restoration and actual first-frame presentation are implemented and verified. The virtual-display request was removed from the probe. Stable main and TestFlight 1.1(7) do not include this prototype.

Offline integration connects the media receiver to playback and accepts negotiated video payload type 123. It is incomplete: authenticated packet receipt is not evidence of visible playback or synchronized sound. Required work includes host session teardown, saved display-state restoration, render readiness, keyframe feedback/recovery, bounded receive scheduling, full control record parsing/rekey, and server identity verification. Do not merge or distribute this branch as a completed feature.

Validation: simulator Debug build succeeds. Media component tests pass. Live audio/video synchronization and automatic resolution recovery have NOT passed.
