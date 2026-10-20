# Native synchronized compressed playback

`Tests/HighPerformancePlayback/run.sh` builds and runs offline native decoder tests and typechecks for the iOS 26 simulator. No speaker playback or network calls occur.

The factory converts complete H.264 Annex-B access units into AVCC CMSampleBuffers and AAC-ELD access units into compressed audio CMSampleBuffers. MPEG-4 AudioSpecificConfig is wrapped in ESDS descriptors: CoreAudio rejects the raw ASC as a magic cookie. CoreAudio determines actual sample rate, channel count and frame duration; it accepts the experimental Apple ASC `f8e65132e000` as 48 kHz stereo AAC-ELD with 480 frames/packet. Unsupported cookies fail closed.

`HighPerformancePlayback` attaches native audio and video renderers to one AVSampleBufferRenderSynchronizer. The caller must supply timestamps from authenticated Sender Reports, enqueue initial samples and explicitly start the common clock. Backpressure is returned to the caller; no unbounded queue is allocated. Reconnect requires resetting the factory, clock and playback. This does not depacketize RTP or negotiate a codec; HEVC is unsupported in this H.264 path.

Fixtures are locally generated black 64x64 H.264 and a 440 Hz AAC-ELD access unit:

```
ffmpeg -f lavfi -i 'color=c=black:s=64x64:r=1' -frames:v 1 -c:v libx264 -preset ultrafast -tune zerolatency -f h264 black.h264
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.1' -ac 2 -c:a aac_at -profile:a 38 -b:a 32k tone.m4a
```

The first AAC packet was extracted with ffprobe. Its generated ASC is `f8e64000`; the test decodes this actual packet with AudioToolbox and checks positive PCM output. VideoToolbox decodes the H.264 fixture to a 64-pixel-wide image. These establish native decoder feasibility; they do not prove playback of Apple server audio or perceptual A/V sync. No live screen content or recorded user audio is included.

The iOS simulator `HighPerformancePlaybackTests` also attaches a display layer to
an actual test window, presents a generated red H.264 frame without audio, checks
that decoded pixels are available and the common clock advances, and decodes the
synthetic AAC-ELD fixture to PCM. The embedded red fixture uses libx264 baseline,
64×64, yuv420p. Audio fixture ASC remains `f8e64000`; this does not validate the
Apple wire cookie, RTP audio framing, or perceptual synchronization.

Video starts after its own authenticated Sender Report even if the Mac is silent.
Audio waits for its independent Sender Report, retaining its NTP offset; obsolete
late audio preroll is dropped. Native renderer sufficient-data gating is disabled
because an empty audio renderer must not stall video. `hasDisplayedVideoFrame`
reports an actual displayed pixel buffer and is distinct from scheduled playback.
