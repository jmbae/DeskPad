import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

enum HighPerformancePlaybackError: Error {
    case invalidAccessUnit, missingConfiguration, unsupportedAudio, mediaStatus(OSStatus), backpressure, rendererFailed
}

/// Builds complete, authenticated access units into compressed CMSampleBuffers.
/// No RTP depacketization is performed here. Confine to one queue/actor.
final class HighPerformanceSampleFactory {
    private var sps: Data?
    private var pps: Data?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?

    var audioStreamDescription: AudioStreamBasicDescription? {
        guard let audioFormat else { return nil }
        return CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
    }

    func reset() { sps = nil; pps = nil; videoFormat = nil; audioFormat = nil }

    /// Wraps MPEG-4 AudioSpecificConfig in an ESDS descriptor for CoreAudio's magic cookie API.
    /// Format parameters are obtained from CoreAudio, never inferred from RTP timestamps.
    func configureAAC(audioSpecificConfig asc: Data) throws {
        audioFormat = nil
        guard !asc.isEmpty, asc.count <= 64 else { throw HighPerformancePlaybackError.unsupportedAudio }
        func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] { [tag, UInt8(payload.count)] + payload }
        let decoder = descriptor(4, [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + descriptor(5, Array(asc)))
        let cookie = descriptor(3, [0, 1, 0] + decoder + descriptor(6, [2]))
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatMPEG4AAC_ELD
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        let status = cookie.withUnsafeBytes { AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count), $0.baseAddress, &size, &asbd) }
        guard status == noErr, asbd.mSampleRate > 0, asbd.mSampleRate <= 192000,
              asbd.mChannelsPerFrame > 0, asbd.mChannelsPerFrame <= 2,
              asbd.mFramesPerPacket > 0,
              [kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR].contains(asbd.mFormatID) else {
            throw HighPerformancePlaybackError.unsupportedAudio
        }
        // Fail before enqueueing if this OS cannot create the decoder or accept its cookie.
        var pcm = AudioStreamBasicDescription(mSampleRate: asbd.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * asbd.mChannelsPerFrame,
            mFramesPerPacket: 1, mBytesPerFrame: 4 * asbd.mChannelsPerFrame, mChannelsPerFrame: asbd.mChannelsPerFrame,
            mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        try requireStatus(AudioConverterNew(&asbd, &pcm, &converter))
        guard let converter else { throw HighPerformancePlaybackError.unsupportedAudio }
        defer { AudioConverterDispose(converter) }
        try cookie.withUnsafeBytes { try requireStatus(AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)) }
        var format: CMAudioFormatDescription?
        try cookie.withUnsafeBytes { try requireStatus(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: $0.baseAddress,
            extensions: nil, formatDescriptionOut: &format)) }
        audioFormat = format
    }

    func aacAccessUnit(_ data: Data, presentationSeconds: Double) throws -> CMSampleBuffer {
        guard !data.isEmpty, data.count <= 65535, presentationSeconds.isFinite else { throw HighPerformancePlaybackError.invalidAccessUnit }
        guard let audioFormat else { throw HighPerformancePlaybackError.missingConfiguration }
        let block = try makeBlock(data)
        var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
        var sample: CMSampleBuffer?
        try requireStatus(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: audioFormat, sampleCount: 1, presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 1_000_000),
            packetDescriptions: &description, sampleBufferOut: &sample))
        guard let sample else { throw HighPerformancePlaybackError.invalidAccessUnit }
        return sample
    }

    /// Returns nil for a configuration-only access unit; VCL requires valid SPS/PPS.
    /// Accepts Annex-B H.264 only. HEVC must use a separately negotiated decoder path.
    func h264AccessUnit(_ data: Data, presentationSeconds: Double) throws -> CMSampleBuffer? {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024, presentationSeconds.isFinite else { throw HighPerformancePlaybackError.invalidAccessUnit }
        let b = Array(data)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < b.count && b[i + 2] == 0 && b[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        guard let first = starts.first, b[..<first.0].allSatisfy({ $0 == 0 }), starts.count <= 4096 else { throw HighPerformancePlaybackError.invalidAccessUnit }
        var avcc = Data()
        var hasSlice = false
        var changed = false
        for (n, start) in starts.enumerated() {
            let begin = start.0 + start.1
            var end = n + 1 < starts.count ? starts[n + 1].0 : b.count
            while end > begin && b[end - 1] == 0 { end -= 1 }
            guard end > begin, b[begin] & 0x80 == 0 else { throw HighPerformancePlaybackError.invalidAccessUnit }
            let nal = Data(b[begin..<end]), type = b[begin] & 31
            if type == 7 { if sps != nal { sps = nal; changed = true } }
            else if type == 8 { if pps != nal { pps = nal; changed = true } }
            else {
                if (1...5).contains(type) { hasSlice = true }
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }; avcc.append(nal)
            }
        }
        if changed { videoFormat = nil }
        if videoFormat == nil, let sps, let pps {
            try sps.withUnsafeBytes { s in try pps.withUnsafeBytes { p in
                var pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [sps.count, pps.count]
                try requireStatus(CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &videoFormat))
            } }
        }
        guard hasSlice else { return nil }
        guard let videoFormat else { throw HighPerformancePlaybackError.missingConfiguration }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        try requireStatus(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: try makeBlock(avcc),
            formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
        return sample
    }
}

/// Native audio and video share one playback clock. Call start only after both
/// streams have SR-derived timestamps and initial samples. Call reset on reconnect.
@MainActor final class HighPerformancePlayback {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    var presentationSeconds: Double { CMTimeGetSeconds(synchronizer.currentTime()) }

    /// A decoded pixel buffer actually selected for display, not merely queued RTP.
    var hasDisplayedVideoFrame: Bool {
        if #available(macOS 14.4, iOS 17.4, *) {
            return videoLayer.sampleBufferRenderer.displayedPixelBuffer() != nil
        }
        return false
    }

    init() {
        // Idle audio must not hold the shared clock at zero indefinitely.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(videoLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    func start(at senderSeconds: Double, playoutDelay: Double = 0.08) throws {
        guard senderSeconds.isFinite, playoutDelay.isFinite, (0...1).contains(playoutDelay) else { throw HighPerformancePlaybackError.invalidAccessUnit }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: playoutDelay, preferredTimescale: 1_000_000)
        synchronizer.setRate(1, time: CMTime(seconds: senderSeconds, preferredTimescale: 1_000_000), atHostTime: host)
    }

    func enqueueVideo(_ sample: CMSampleBuffer) throws {
        guard videoLayer.sampleBufferRenderer.status != .failed else { throw HighPerformancePlaybackError.rendererFailed }
        guard videoLayer.sampleBufferRenderer.isReadyForMoreMediaData else { throw HighPerformancePlaybackError.backpressure }
        videoLayer.sampleBufferRenderer.enqueue(sample)
    }

    func enqueueAudio(_ sample: CMSampleBuffer) throws {
        guard audioRenderer.status != .failed else { throw HighPerformancePlaybackError.rendererFailed }
        guard audioRenderer.isReadyForMoreMediaData else { throw HighPerformancePlaybackError.backpressure }
        audioRenderer.enqueue(sample)
    }

    func reset() {
        synchronizer.setRate(0, time: .zero)
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        audioRenderer.flush()
    }
}

private func requireStatus(_ status: OSStatus) throws { if status != noErr { throw HighPerformancePlaybackError.mediaStatus(status) } }
private func makeBlock(_ data: Data) throws -> CMBlockBuffer {
    var block: CMBlockBuffer?
    try requireStatus(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block))
    guard let block else { throw HighPerformancePlaybackError.invalidAccessUnit }
    try data.withUnsafeBytes { try requireStatus(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)) }
    return block
}
