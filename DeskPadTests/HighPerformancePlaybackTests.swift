import Testing
import UIKit
import AVFoundation
import CoreMedia
import AudioToolbox
@testable import DeskPad

/// Offline native renderer proof: no network or remote desktop is involved.
@MainActor struct HighPerformancePlaybackTests {
    @Test func silentAudioDoesNotBlockFirstVideoFrame() async throws {
        let playback = HighPerformancePlayback()
        let factory = HighPerformanceSampleFactory()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        playback.videoLayer.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        window.rootViewController!.view.layer.addSublayer(playback.videoLayer)
        defer { playback.reset(); window.isHidden = true }
        let frame = Data(base64Encoded: "AAAAAWdCwArZBCbARAAAAwAEAAADAPA8SJkgAAAAAWjLg8sgAAABBgX//23cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0yNSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhAnxGKAAI1scAAQ0Y4AAlUScnJ1111111111114=")!
        let sample = try #require(try factory.h264AccessUnit(frame, presentationSeconds: 0))
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
    @Test func syntheticAACELDDecodesToPCM() throws {
        let fixtureFactory=HighPerformanceSampleFactory()
        try fixtureFactory.configureAAC(audioSpecificConfig:Data([0xf8,0xe6,0x40,0]))
        let au=Data(base64Encoded: "XcAAATNOYhDAT5z4+nX1TgtG0W6e5RES+rZQnG4FQ8lbZZ2UJldQsL+8TS1DdVdM0xLdhXx6csZd98uSui1ab+qJ7pvAF9QAABbp7lERLw==")!
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
        AudioConverterDispose(converter!)
    }
}
