import Foundation
import CoreMedia
import AudioToolbox
let factory=HighPerformanceSampleFactory()
let video=try factory.h264AccessUnit(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])),presentationSeconds:1.25)
precondition(video != nil && CMSampleBufferGetNumSamples(video!) == 1)
precondition(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(video!)) == 1.25)
let cookie=Data([0xf8,0xe6,0x51,0x32,0xe0,0])
try factory.configureAAC(audioSpecificConfig:cookie)
let audio=try factory.aacAccessUnit(Data([1,2,3]),presentationSeconds:1.25)
precondition(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(audio)) == 1.25)
precondition(abs(CMTimeGetSeconds(CMSampleBufferGetDuration(audio)) - 0.01) < 0.000001)
let format=CMSampleBufferGetFormatDescription(audio)!
let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
precondition(asbd.mSampleRate == 48000 && asbd.mChannelsPerFrame == 2 && asbd.mFramesPerPacket == 480)
do { _=try factory.h264AccessUnit(Data([0,0,1]),presentationSeconds:0); fatalError("empty NAL accepted") } catch {}
do { _=try factory.aacAccessUnit(Data(),presentationSeconds:0); fatalError("empty audio accepted") } catch {}
do { _=try factory.aacAccessUnit(Data([0]),presentationSeconds:.nan); fatalError("NaN PTS accepted") } catch {}
print("Playback format/sample builder tests passed")
// Decode generated fixtures offline: no speaker output or network access.
import VideoToolbox
final class VideoResult { var image: CVImageBuffer?; var status: OSStatus = -1 }
let result=VideoResult()
var callback=VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref,_,status,_,image,_,_ in
    let result=Unmanaged<VideoResult>.fromOpaque(ref!).takeUnretainedValue();result.status=status;result.image=image
}, decompressionOutputRefCon:Unmanaged.passUnretained(result).toOpaque())
var session:VTDecompressionSession?
precondition(VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,formatDescription:CMSampleBufferGetFormatDescription(video!)!,decoderSpecification:nil,imageBufferAttributes:nil,outputCallback:&callback,decompressionSessionOut:&session) == 0)
precondition(VTDecompressionSessionDecodeFrame(session!,sampleBuffer:video!,flags:[],frameRefcon:nil,infoFlagsOut:nil) == 0)
VTDecompressionSessionWaitForAsynchronousFrames(session!)
precondition(result.status == 0 && result.image != nil && CVPixelBufferGetWidth(result.image!) == 64)
VTDecompressionSessionInvalidate(session!)
let fixtureFactory=HighPerformanceSampleFactory()
try fixtureFactory.configureAAC(audioSpecificConfig:Data([0xf8,0xe6,0x40,0]))
let au=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
let audioSample=try fixtureFactory.aacAccessUnit(au,presentationSeconds:0)
let audioDescription=CMSampleBufferGetFormatDescription(audioSample)!
var input=CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)!.pointee
var output=AudioStreamBasicDescription(mSampleRate:input.mSampleRate,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
var converter:AudioConverterRef?
precondition(AudioConverterNew(&input,&output,&converter)==0)
var cookieSize=0
let cookiePointer=CMAudioFormatDescriptionGetMagicCookie(audioDescription,sizeOut:&cookieSize)!
precondition(AudioConverterSetProperty(converter!,kAudioConverterDecompressionMagicCookie,UInt32(cookieSize),cookiePointer)==0)
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
precondition(audioStatus==0 && packets>0,"AAC ELD fixture failed to decode")
AudioConverterDispose(converter!)
print("Native VideoToolbox H264 pixel decode and AudioToolbox AAC-ELD PCM decode passed")
