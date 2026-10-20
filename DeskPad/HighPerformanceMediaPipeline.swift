import Foundation
import CoreMedia

@MainActor protocol HighPerformanceMediaOutput: AnyObject {
    func start(at senderSeconds: Double, playoutDelay: Double) throws
    func enqueueVideo(_ sample: CMSampleBuffer) throws
    func enqueueAudio(_ sample: CMSampleBuffer) throws
    func reset()
}
extension HighPerformancePlayback: HighPerformanceMediaOutput {}

/// Single-display H.264 + AAC-ELD coordinator. All inputs must already be authenticated.
/// RTP arrival times are never used as A/V timestamps. A session without Sender Reports
/// remains in bounded preroll instead of playing unsynchronized audio.
@MainActor final class HighPerformanceMediaPipeline {
    enum Failure: Error { case unsupportedStream, tooManyStreams, invalidConfiguration }
    private struct VideoState {
        var depacketizer = AppleHPVideoDepacketizer()
        var expectedSequence: UInt16?
        let factory = HighPerformanceSampleFactory()
    }
    private struct PendingVideo { let ssrc: UInt32; let timestamp: UInt32; let annexB: Data; let keyframe: Bool }
    private struct PendingAudio { let ssrc: UInt32; let timestamp: UInt32; let data: Data }
    private let output: any HighPerformanceMediaOutput
    private let audioFactory = HighPerformanceSampleFactory()
        private let videoPayloadType: UInt8
    private let videoRate: Double
    private let audioRate: Double
    private let audioFrames: UInt32
    private let aggregation: AppleHPVideoDepacketizer.AggregationFormat
    private var clock = HighPerformanceMediaClock()
    private var videos: [UInt32: VideoState] = [:]
    private var selectedVideo: UInt32?
    private var selectedAudio: UInt32?
    private var pendingVideo: [PendingVideo] = []
    private var pendingAudio: [PendingAudio] = []
    private var needsKeyframe = true
    private(set) var isPlaying = false
    var onNeedsKeyframe: (() -> Void)?
    var pendingAudioCount: Int { pendingAudio.count }
    var pendingVideoCount: Int { pendingVideo.count }

    init(output: any HighPerformanceMediaOutput, videoPayloadType: UInt8 = 100, videoClockRate: Double = 90000,
         audioClockRate: Double = 48000, audioFramesPerPacket: UInt32 = 480,
         audioSpecificConfig: Data = Data([0xf8, 0xe6, 0x51, 0x32, 0xe0, 0]),
         aggregationFormat: AppleHPVideoDepacketizer.AggregationFormat = .rfc6184) throws {
        // This experimental profile is explicitly AAC-ELD at 48 kHz / 480-frame AUs.
        guard videoPayloadType <= 127, videoPayloadType != 101, videoClockRate == 90000, audioClockRate == 48000, audioFramesPerPacket == 480 else { throw Failure.invalidConfiguration }
        self.output = output; self.videoPayloadType = videoPayloadType; videoRate = videoClockRate; audioRate = audioClockRate
        audioFrames = audioFramesPerPacket; aggregation = aggregationFormat
        try audioFactory.configureAAC(audioSpecificConfig: audioSpecificConfig)
        guard let format = audioFactory.audioStreamDescription, format.mSampleRate == audioRate,
              format.mFramesPerPacket == audioFrames else { throw Failure.invalidConfiguration }
    }

    /// Pass the negotiated clock rate for these SSRCs, not a rate inferred from arrival.
    func observe(_ reports: [HighPerformanceSenderReport], clockRate: Double) throws {
        guard clockRate == videoRate || clockRate == audioRate else { throw Failure.unsupportedStream }
        for report in reports {
            if report.ssrc == selectedVideo && clockRate != videoRate { throw Failure.unsupportedStream }
            if report.ssrc == selectedAudio && clockRate != audioRate { throw Failure.unsupportedStream }
            do { try clock.observe(report, clockRate: clockRate) }
            catch HighPerformanceMediaError.staleSenderReport { continue }
        }
        try drain()
    }

    /// The caller must reorder a bounded packet window before feeding fragmented video.
    /// This does not composite Apple's multi-SSRC tiled HEVC mode.
    func consumeVideo(_ packet: HighPerformanceRTPPacket) throws {
        guard packet.payloadType == videoPayloadType, packet.ssrc != selectedAudio else { throw Failure.unsupportedStream }
        if videos[packet.ssrc] == nil {
            guard videos.count < 4 else { throw Failure.tooManyStreams }
            var state = VideoState(); state.depacketizer.aggregationFormat = aggregation
            videos[packet.ssrc] = state
        }
        if selectedVideo == nil { selectedVideo = packet.ssrc }
        var state = videos[packet.ssrc]!
        if let expected = state.expectedSequence, expected != packet.sequenceNumber, packet.ssrc == selectedVideo { loseVideoContinuity() }
        state.expectedSequence = packet.sequenceNumber &+ 1
        let result: AppleHPVideoDepacketizer.Output?
        do { result = try state.depacketizer.append(sequence: packet.sequenceNumber, timestamp: packet.timestamp, marker: packet.marker, payload: packet.payload) }
        catch {
            videos[packet.ssrc] = state
            if packet.ssrc == selectedVideo { loseVideoContinuity() }
            throw error
        }
        videos[packet.ssrc] = state
        guard let result else { return }
        switch result {
        case .configuration(let sps, let pps):
            // The factory supports one active SPS/PPS pair. Do not silently pick from
            // a multi-parameter-set configuration and decode against the wrong IDs.
            guard sps.count == 1, pps.count == 1 else { throw Failure.unsupportedStream }
            _ = try state.factory.h264AccessUnit(annexB(sps + pps), presentationSeconds: 0)
        case .accessUnit(let timestamp, let units):
            guard packet.ssrc == selectedVideo else { return }
            let parameters = units.filter { $0.first.map { ($0 & 31) == 7 || ($0 & 31) == 8 } ?? false }
            if !parameters.isEmpty { _ = try state.factory.h264AccessUnit(annexB(parameters), presentationSeconds: 0) }
            let keyframe = units.contains { $0.first.map { $0 & 31 == 5 } ?? false }
            let hasSlice = units.contains { $0.first.map { (1...5).contains($0 & 31) } ?? false }
            if !hasSlice { _ = try state.factory.h264AccessUnit(annexB(units), presentationSeconds: 0); return }
            if needsKeyframe && !keyframe { return }
            needsKeyframe = false
            if pendingVideo.count == 2 {
                loseVideoContinuity()
                guard keyframe else { return }
                needsKeyframe = false
            }
            pendingVideo.append(PendingVideo(ssrc: packet.ssrc, timestamp: timestamp, annexB: annexB(units), keyframe: keyframe))
        }
        try drain()
    }

    /// Feed exactly one raw AAC access unit, after removing any Apple/RTP AU wrapper.
    /// This API intentionally does not guess audio payload framing from its contents.
    func consumeAudioAccessUnit(_ packet: HighPerformanceRTPPacket) throws {
        guard packet.payloadType == 101, packet.ssrc != selectedVideo, !packet.payload.isEmpty, packet.payload.count <= 65535 else { throw Failure.unsupportedStream }
        if let selectedAudio, selectedAudio != packet.ssrc { throw Failure.unsupportedStream }
        selectedAudio = packet.ssrc
        pendingAudio.append(PendingAudio(ssrc: packet.ssrc, timestamp: packet.timestamp, data: packet.payload))
        let limit = Int(audioRate * 0.2 / Double(audioFrames))
        if pendingAudio.count > limit { pendingAudio.removeFirst(pendingAudio.count - limit) }
        // Also bound by RTP media duration, not merely packet count, when packets are sparse.
        while let first = pendingAudio.first, let last = pendingAudio.last,
              Int32(bitPattern: last.timestamp &- first.timestamp) > Int32(audioRate * 0.2) - Int32(audioFrames) {
            pendingAudio.removeFirst()
        }
        try drain()
    }

    /// Fresh session only; the SRTP receiver must also be replaced with freshly negotiated keys.
    func reset() {
        output.reset(); clock.reset(); videos.removeAll(); pendingVideo.removeAll(); pendingAudio.removeAll()
        selectedVideo = nil; selectedAudio = nil; needsKeyframe = true; isPlaying = false
        // Keep the successfully negotiated audio format; it carries no session time/key state.
    }

    private func loseVideoContinuity() {
        pendingVideo.removeAll(); needsKeyframe = true; onNeedsKeyframe?()
    }

    private func drain() throws {
        if !isPlaying {
            guard let video = pendingVideo.first, let audio = pendingAudio.first,
                  let videoPTS = clock.presentationSeconds(ssrc: video.ssrc, timestamp: video.timestamp),
                  let audioPTS = clock.presentationSeconds(ssrc: audio.ssrc, timestamp: audio.timestamp),
                  let lastAudio = pendingAudio.last,
                  let audioEnd = clock.presentationSeconds(ssrc: lastAudio.ssrc, timestamp: lastAudio.timestamp) else { return }
            // Preserve the IDR as the first decoded frame. If audio has advanced beyond
            // this short preroll, request a fresh keyframe instead of dropping dependencies.
            guard abs(videoPTS - audioPTS) <= 0.2 else {
                if audioPTS > videoPTS { loseVideoContinuity() }
                return
            }
            guard audioEnd + Double(audioFrames) / audioRate >= videoPTS else { return }
            let start = max(videoPTS, audioPTS)
            // Queue both media types before starting the shared clock. If enqueue fails,
            // clear the renderers so a later retry cannot duplicate partially queued audio.
            do {
                try enqueuePending()
                try output.start(at: start, playoutDelay: 0.08)
                isPlaying = true
            } catch {
                output.reset(); pendingAudio.removeAll(); loseVideoContinuity()
                throw error
            }
        } else { try enqueuePending() }
    }

    private func enqueuePending() throws {
        while let video = pendingVideo.first {
            guard let pts = clock.presentationSeconds(ssrc: video.ssrc, timestamp: video.timestamp), let factory = videos[video.ssrc]?.factory else { break }
            if let sample = try factory.h264AccessUnit(video.annexB, presentationSeconds: pts) {
                do { try output.enqueueVideo(sample) }
                catch { loseVideoContinuity(); throw error }
            }
            pendingVideo.removeFirst()
        }
        while let audio = pendingAudio.first {
            guard let pts = clock.presentationSeconds(ssrc: audio.ssrc, timestamp: audio.timestamp) else { break }
            try output.enqueueAudio(audioFactory.aacAccessUnit(audio.data, presentationSeconds: pts))
            pendingAudio.removeFirst()
        }
    }

    private func annexB(_ units: [Data]) -> Data {
        var data = Data()
        for unit in units { data.append(contentsOf: [0, 0, 0, 1]); data.append(unit) }
        return data
    }
}
