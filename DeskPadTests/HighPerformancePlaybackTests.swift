import Testing
import UIKit
import AVFoundation
import CoreMedia
import AudioToolbox
@testable import DeskPad

/// Offline native renderer proof: no network or remote desktop is involved.
@MainActor struct HighPerformancePlaybackTests {
    @Test func silentAudioDoesNotBlockFirstVideoFrame() async throws {
        try await verifyPresentation(Data(base64Encoded: "AAAAAWdCwArZBCbARAAAAwAEAAADAPA8SJkgAAAAAWjLg8sgAAABBgX//23cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0yNSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhAnxGKAAI1scAAQ0Y4AAlUScnJ1111111111114=")!)
    }
    @Test func nonIDRIntraPictureDisplaysWithFreshDecoder() async throws {
        try await verifyPresentation(Data(base64Encoded: "AAAAAWdkAAqs5BCbARAAAAMAEAAAAwPA8SJRIAAAAAFo6+PLIsAAAAABZ2QACqzkEJsBEAAAAwAQAAADA8DxIlEgAAAAAWjr48siwAAAAAFnZAAKrOQQmwEQAAADABAAAAMDwPEiUSAAAAABaOvjyyLAAAAAAWdkAAqs5BCbARAAAAMAEAAAAwPA8SJRIAAAAAFo6+PLIsAAAAABQYiKAl/XR2aASVfQTk1z5jmPvHTgjF/r6sbkkgyzO6yRs+KFZQaxsC4QJiB7SAfqd4v0U/oQ17LYA4b36OUg1oLsQeZbwph50iw6Zks5wx3oELo+IZqqegid+l9QLevCDpPZph/DsZuKPGynl6dNYNNqsWAjgfrvSLgLt1ULl4NOHmAP6lAGP+M6RteUg6Mm/CQ+/Vg9IKmGOER4mXyDhOhlFnQlInhdv2FgxSgSL/CtrJv8b+9SQlv2l2v4xNoqemg7S+p6E07OVoVsFP+hU1xK02xUboE/czsu/ELWpnKkIZpmQSIHF7Qp+OCUcKGyGRdpyeHRr/TD8RQGNuWuTGcr/8vnMrLvXM0mQ+WCjm8YhEuYelH9ZzHvLySWp6WF1fB1iYEo+Fc4JqOyAk4KEPLd6h77/hacg6hSVxVdjhgjOO+z69ih2CJlRBZbG5Fh0xScq8OIMTh4Xj4jH+E1aw6aNcYkYYgUdFWpSyht00iECVPfiT0YlVUa7s4YVuMPhZcGDAUsSbKsEQFZ3W/bPZc8gie5q42PbaM9Xu9rQgDQ5fyAAge/tQoeNoHB3gbSSmGupcQBH6deQ/Zq/f5pwRTifxg/ZAGF3aPq/DgFS9NMaVaJK7r0sMOV0ylgzDdXapz2FO22o4Mu1jUHZqOT47S6ZoWFAiUY3f6jC5cnRJojjXN/tLVvCQCyNerWbxjB/uQ5XTVL9aI829a+Oc2G/oVWKA4/KtrcKKMUjcWiJ4fhOPx6B8zDKdcpVhVJDNYC6jIyVFpXR1mLjRjaFAR3Xqzk+f5TdiHxnQQmOyj7+Rvyl+yQdEnLc1zZNZDZkXCn0F0QtR9Zccyb3R6ahde3D8tVColIoBms2bVoLkujLusk00CWuNmEbWT7DR+YgfNPo0h9gRoUk/bq6dgF1UD2lzfZvULtYdQPfHaGiV7LQ2pP5DN3oVq0M/K1qgi9VO8YSLrVg5iTanyg/Cai+Kv6Dm9f6YFJdW798uuPXgMO7kjo4MP2SiYtiN6khZbBQrTH3tCbaeYSJExEOYNQRHNjWoYWeGuqCHEt7I6wXoAOOwgRMyiIHtW27jVDx7AbUVz9MaPsB9m0ZnA7Vr0l+sle8Btw6Wml/o/IJKH/MqYg4zU6wRX9+nwP7kMz+FXvtebZjyRXCG9AY0SukKaFODyTG3VCc8fpsSPkmfMTzXml78omuijlnH5IdoyBctDjhmxCpb+1+MD1DpWR4YdG6MUme+ixZUl8sS2OUQEXnaqAYUm6U8KG7dSQdg+uQJGHgmrQkstES086VHlVzJ50KY58DRcKnhY2xqVjmtlOAdLJFivEo82OsS2JoCJBHOjgOjJvgA==")!)
    }
    @Test func redHEVCDisplays() async throws {
        try await verifyPresentation(Data(base64Encoded: "AAAAAUABDAH//wFgAAADAJAAAAMAAAMAHpWYCQAAAAFCAQEBYAAAAwCQAAADAAADAB6gIIEFllZpJMrwFoCAAAADAIAAAA8EAAAAAUQBwXK0IkAAAAABKAGvCGD57pd/9pWf2gUuKNRpBy4=")!, hevc: true)
    }
    @Test func red444HEVCDisplays() async throws {
        try await verifyPresentation(Data(base64Encoded: "AAAAAUABDAH//wQIAAADAJ4IAAADAAAelZgJAAAAAUIBAQQIAAADAJ4IAAADAAAekAQQILLKzSSZXgLQEAAAAwAQAAADAeCAAAAAAUQBwXKGDEIkAAAAASgBrwhg+e6Xf/aVn9oFLijUaQcu")!, hevc: true)
    }
    @Test func delayedSenderReportPreserves120FrameChain() async throws {
        let playback = HighPerformancePlayback()
        let pipeline = try HighPerformanceMediaPipeline(output: playback, videoPayloadType: 100, videoCodec: .hevc)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        playback.videoLayer.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        window.rootViewController!.view.layer.addSublayer(playback.videoLayer)
        defer { pipeline.reset(); window.isHidden = true }
        let bytes = [UInt8](Data(base64Encoded: "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")!)
        var units: [Data] = []; var begin = 4; var cursor = 4
        while cursor + 3 < bytes.count {
            if Array(bytes[cursor..<(cursor+4)]) == [0,0,0,1] { units.append(Data(bytes[begin..<cursor])); begin = cursor + 4; cursor += 4 }
            else { cursor += 1 }
        }
        units.append(Data(bytes[begin...]))
        var ap = Data([96,1])
        for unit in units where (32...34).contains(Int((unit.first! >> 1) & 63)) {
            ap.append(contentsOf: [UInt8(unit.count>>8),UInt8(unit.count&255)]); ap.append(unit)
        }
        var sequence: UInt16 = 0
        func send(_ payload: Data, timestamp: UInt32) throws {
            var data = Data([0x80,228,UInt8(sequence>>8),UInt8(truncatingIfNeeded:sequence)])
            sequence &+= 1
            for number: UInt32 in [timestamp,1] { data.append(contentsOf: [UInt8(truncatingIfNeeded:number>>24),UInt8(truncatingIfNeeded:number>>16),UInt8(truncatingIfNeeded:number>>8),UInt8(truncatingIfNeeded:number)]) }
            data.append(payload); try pipeline.consumeVideo(HighPerformanceRTPPacket(data))
        }
        try send(ap,timestamp: 999)
        var frame: UInt32 = 0
        for unit in units where (unit.first! >> 1) & 63 < 32 { try send(unit,timestamp: frame*3000); frame += 1 }
        #expect(frame == 120 && pipeline.pendingVideoCount == 120)
        try pipeline.observe([HighPerformanceSenderReport(ssrc:1,ntpSeconds:100,ntpFraction:0,rtpTimestamp:0)],clockRate:90000)
        for _ in 0..<100 {
            if playback.hasDisplayedVideoFrame && playback.presentationSeconds >= 119.0/30.0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(playback.hasDisplayedVideoFrame)
        #expect(playback.presentationSeconds >= 119.0/30.0)
    }
    private func verifyPresentation(_ frame: Data, hevc: Bool = false) async throws {
        let playback = HighPerformancePlayback()
        let factory = HighPerformanceSampleFactory()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        playback.videoLayer.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        window.rootViewController!.view.layer.addSublayer(playback.videoLayer)
        defer { playback.reset(); window.isHidden = true }
        let built: CMSampleBuffer?
        if hevc {
            let bytes = [UInt8](frame)
            var starts: [(Int, Int)] = []; var offset = 0
            while offset + 3 < bytes.count {
                if Array(bytes[offset..<(offset+4)]) == [0,0,0,1] { starts.append((offset,4)); offset += 4 }
                else if Array(bytes[offset..<(offset+3)]) == [0,0,1] { starts.append((offset,3)); offset += 3 }
                else { offset += 1 }
            }
            let units = starts.enumerated().map { n,start in Data(bytes[(start.0+start.1)..<(n+1 < starts.count ? starts[n+1].0 : bytes.count)]) }
            built = try factory.hevcAccessUnit(units, presentationSeconds: 0)
        } else { built = try factory.h264AccessUnit(frame, presentationSeconds: 0) }
        let sample = try #require(built)
        #expect(!playback.hasDisplayedVideoFrame)
        try playback.enqueueVideo(sample)
        try playback.start(at: 0, playoutDelay: 0.02)
        for _ in 0..<100 {
            if playback.hasDisplayedVideoFrame && playback.presentationSeconds > 0.1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(playback.hasDisplayedVideoFrame)
        #expect(playback.presentationSeconds > 0.1)
        let pixels = try #require(playback.videoLayer.sampleBufferRenderer.displayedPixelBuffer())
        #expect(CVPixelBufferGetWidth(pixels) == 64)
        #expect(CVPixelBufferGetHeight(pixels) == 64)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        // Red fixture luma is above video black (16), proving decoded content.
        if CVPixelBufferIsPlanar(pixels), let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
            #expect(base.load(as: UInt8.self) > 32)
        }
    }
    @Test func wireProfileSilenceDecodesToPCM() throws {
        for au in [Data([0,0,0,0]), Data([0,0x68,0x34,0])] {
            try decodeAudio(au, asc: Data([0xf8,0xe6,0x51,0x32,0xe0,0]), silence: true)
        }
    }
    @Test func syntheticAACELDDecodesToPCM() throws {
        try decodeAudio(Data(base64Encoded: "XcAAATNOYhDAT5z4+nX1TgtG0W6e5RES+rZQnG4FQ8lbZZ2UJldQsL+8TS1DdVdM0xLdhXx6csZd98uSui1ab+qJ7pvAF9QAABbp7lERLw==")!, asc: Data([0xf8,0xe6,0x40,0]), silence: false)
    }
    private func decodeAudio(_ au: Data, asc: Data, silence: Bool) throws {
        let fixtureFactory=HighPerformanceSampleFactory()
        try fixtureFactory.configureAAC(audioSpecificConfig:asc)
        let audioSample=try fixtureFactory.aacAccessUnit(au,presentationSeconds:0)
        let audioDescription=CMSampleBufferGetFormatDescription(audioSample)!
        var input=CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)!.pointee
        var output=AudioStreamBasicDescription(mSampleRate:input.mSampleRate,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        var converter:AudioConverterRef?
        #expect(AudioConverterNew(&input,&output,&converter)==0)
        var cookieSize=0
        let cookiePointer=CMAudioFormatDescriptionGetMagicCookie(audioDescription,sizeOut:&cookieSize)!
        #expect(AudioConverterSetProperty(converter!,kAudioConverterDecompressionMagicCookie,UInt32(cookieSize),cookiePointer)==0)
        final class AudioInput {
            let bytes:UnsafeMutableRawPointer
            let count:Int
            let description:UnsafeMutablePointer<AudioStreamPacketDescription>
            var delivered=false
            init(_ data:Data) { count=data.count;bytes = .allocate(byteCount:count,alignment:1);data.copyBytes(to:bytes.assumingMemoryBound(to:UInt8.self),count:count);description = .allocate(capacity:1);description.initialize(to:AudioStreamPacketDescription(mStartOffset:0,mVariableFramesInPacket:0,mDataByteSize:UInt32(count))) }
            deinit { bytes.deallocate();description.deinitialize(count:1);description.deallocate() }
        }
        let audioInput=AudioInput(au)
        var pcm=[Float](repeating:0,count:4096*2)
        var packets:UInt32=4096
        let audioStatus=pcm.withUnsafeMutableBytes { bytes -> OSStatus in
            var buffer=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(bytes.count),mData:bytes.baseAddress))
            return AudioConverterFillComplexBuffer(converter!, { _,count,data,description,context in
                let input=Unmanaged<AudioInput>.fromOpaque(context!).takeUnretainedValue()
                if input.delivered { count.pointee=0;return 0 }
                input.delivered=true;count.pointee=1
                data.pointee=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(input.count),mData:input.bytes))
                description?.pointee=input.description
                return 0
            },Unmanaged.passUnretained(audioInput).toOpaque(),&packets,&buffer,nil)
        }
        #expect(audioStatus==0 && packets>0,"AAC ELD fixture failed to decode")
        if silence { #expect(packets == 480 && pcm.allSatisfy { $0 == 0 }) }
        AudioConverterDispose(converter!)
    }
}
