import Foundation
import CoreMedia
@MainActor final class Sink: HighPerformanceMediaOutput {
    var startTimes:[Double]=[]; var audio:[Double]=[];var video:[Double]=[]
    func start(at seconds:Double,playoutDelay:Double)throws { startTimes.append(seconds) }
    func enqueueAudio(_ sample:CMSampleBuffer)throws { audio.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) }
    func enqueueVideo(_ sample:CMSampleBuffer)throws { video.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) }
    func reset() { audio=[];video=[];startTimes=[] }
}
@main struct Harness {
 @MainActor static func main() throws {
    let sink=Sink();let pipeline=try HighPerformanceMediaPipeline(output:sink)
    let frame=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
    let b=Array(frame);var units:[Data]=[];var starts:[(Int,Int)]=[];var i=0
    while i+2<b.count { if b[i]==0 && b[i+1]==0 && b[i+2]==1 { starts.append((i,3));i+=3 } else if i+3<b.count && b[i]==0 && b[i+1]==0 && b[i+2]==0 && b[i+3]==1 { starts.append((i,4));i+=4 } else { i+=1 } }
    for (n,s) in starts.enumerated(){ units.append(Data(b[(s.0+s.1)..<(n+1<starts.count ? starts[n+1].0:b.count)])) }
    func packet(_ payload:Data,seq:UInt16,ssrc:UInt32,ts:UInt32,pt:UInt8,marker:Bool=true)throws ->HighPerformanceRTPPacket {
        var bytes:[UInt8]=[0x80,pt|(marker ? 128:0),UInt8(seq>>8),UInt8(truncatingIfNeeded:seq)]
        for v in [ts,ssrc] { bytes += [UInt8(truncatingIfNeeded:v>>24),UInt8(truncatingIfNeeded:v>>16),UInt8(truncatingIfNeeded:v>>8),UInt8(truncatingIfNeeded:v)] };return try HighPerformanceRTPPacket(Data(bytes)+payload)
    }
    for (n,nal) in units.enumerated(){ try pipeline.consumeVideo(packet(nal,seq:UInt16(n),ssrc:1,ts:90000,pt:100,marker:n==units.count-1)) }
    for n in 0..<30 { try pipeline.consumeAudioAccessUnit(packet(Data([1,2,3]),seq:UInt16(n),ssrc:2,ts:UInt32(n*480),pt:101)) }
    precondition(sink.startTimes.isEmpty && pipeline.pendingAudioCount<=20 && pipeline.pendingVideoCount<=2)
    try pipeline.observe([HighPerformanceSenderReport(ssrc:1,ntpSeconds:100,ntpFraction:0,rtpTimestamp:90000)],clockRate:90000)
    precondition(sink.startTimes.isEmpty,"started without audio SR")
    try pipeline.observe([HighPerformanceSenderReport(ssrc:2,ntpSeconds:100,ntpFraction:0,rtpTimestamp:4800)],clockRate:48000)
    precondition(sink.startTimes.count==1 && sink.audio.count<=20 && sink.video.count==1,"did not start common timeline")
    precondition(abs(sink.startTimes[0])<0.000001 && abs(sink.video[0])<0.000001 && abs(sink.audio[0])<0.000001)
    var requests=0; pipeline.onNeedsKeyframe = { requests += 1 }
    try pipeline.consumeVideo(packet(Data([0x61,0x80]),seq:500,ssrc:1,ts:95000,pt:100))
    precondition(requests==1,"loss did not request IDR")
    for ssrc in UInt32(3)...5 { try pipeline.consumeVideo(packet(Data([0x09,0x10]),seq:1,ssrc:ssrc,ts:0,pt:100)) }
    do { try pipeline.consumeVideo(packet(Data([0x09,0x10]),seq:1,ssrc:6,ts:0,pt:100)); fatalError("unbounded video SSRCs") } catch {}
    do { try pipeline.consumeAudioAccessUnit(packet(Data([1]),seq:1,ssrc:1,ts:0,pt:101)); fatalError("shared audio/video SSRC") } catch {}
    pipeline.reset();precondition(!pipeline.isPlaying && pipeline.pendingAudioCount==0 && pipeline.pendingVideoCount==0)
    print("Pipeline: waits for independent SRs, bounded preroll, commonPTS startup and reset passed")
 }
}
