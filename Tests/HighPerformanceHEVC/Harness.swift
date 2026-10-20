import Foundation
import CoreMedia
@MainActor final class HEVCSink: HighPerformanceMediaOutput {
    var presentationSeconds: Double = 0
    var starts = 0; var video = 0
    func start(at senderSeconds: Double, playoutDelay: Double) throws { starts += 1 }
    func enqueueVideo(_ sample: CMSampleBuffer) throws { precondition(CMFormatDescriptionGetMediaSubType(CMSampleBufferGetFormatDescription(sample)!) == kCMVideoCodecType_HEVC); video += 1 }
    func enqueueAudio(_ sample: CMSampleBuffer) throws {}
    func reset() { starts = 0; video = 0 }
}
@main struct Harness {
 @MainActor static func main() throws {
    func check(_ value: Bool) { precondition(value) }
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    var starts: [(Int,Int)] = []; var p = 0
    while p+3 < bytes.count {
        if Array(bytes[p..<(p+4)]) == [0,0,0,1] { starts.append((p,4)); p += 4 }
        else if Array(bytes[p..<(p+3)]) == [0,0,1] { starts.append((p,3)); p += 3 }
        else { p += 1 }
    }
    let units = starts.enumerated().map { n,s in Data(bytes[(s.0+s.1)..<(n+1 < starts.count ? starts[n+1].0 : bytes.count)]) }
    var dep = AppleHPHEVCDepacketizer(packetization: .appleDON)
    var assembled: [Data]?
    for (n,u) in units.enumerated() {
        let wire = Data(u.prefix(2)) + Data([0,9]) + Data(u.dropFirst(2))
        assembled = try dep.append(sequence: UInt16(n), timestamp: 1, marker: n == units.count-1, payload: wire)
    }
    precondition(assembled == units, "single-NAL DON stripping")
    var ap = Data([96,1,0,9])
    for u in units { ap.append(contentsOf: [UInt8(u.count>>8), UInt8(u.count&255)]); ap.append(u) }
    var apDep = AppleHPHEVCDepacketizer(packetization: .appleDON)
    check(try apDep.append(sequence: 0, timestamp: 1, marker: true, payload: ap) == units)
    let nal = units.last!, b = [UInt8](nal), middle = b.count/2
    let type = (b[0]>>1)&63
    let first = Data([(b[0]&0x81)|98,b[1],128|type,0,9]) + Data(b[2..<middle])
    let last = Data([(b[0]&0x81)|98,b[1],64|type,0,9]) + Data(b[middle...])
    var fu = AppleHPHEVCDepacketizer(packetization: .appleDON)
    check(try fu.append(sequence: 65535, timestamp: 2, marker: false, payload: first) == nil)
    check(try fu.append(sequence: 0, timestamp: 2, marker: true, payload: last) == [nal])
    var lost = AppleHPHEVCDepacketizer(packetization: .appleDON)
    _ = try lost.append(sequence: 1, timestamp: 2, marker: false, payload: first)
    check(try lost.append(sequence: 3, timestamp: 2, marker: true, payload: last) == nil)
    var truncated = AppleHPHEVCDepacketizer(packetization: .appleDON)
    do { _ = try truncated.append(sequence: 0, timestamp: 0, marker: true, payload: Data([96,1,0,0,255,255,0])); fatalError("bad AP accepted") } catch {}
    var mismatch = AppleHPHEVCDepacketizer(packetization: .appleDON)
    _ = try mismatch.append(sequence: 0, timestamp: 0, marker: false, payload: first)
    var changed = last; changed[4] = 10
    do { _ = try mismatch.append(sequence: 1, timestamp: 0, marker: true, payload: changed); fatalError("changed DON accepted") } catch {}
    let sink = HEVCSink()
    var paramsApple = Data([96,1,0,9])
    for u in units where (32...34).contains(Int((u.first! >> 1) & 63)) {
        paramsApple.append(contentsOf: [UInt8(u.count>>8), UInt8(u.count&255)]); paramsApple.append(u)
    }
    let paramsRFC = Data(paramsApple.prefix(2)) + Data(paramsApple.dropFirst(4))
    for (wire, expected) in [(paramsApple, AppleHPHEVCDepacketizer.Packetization.appleDON), (paramsRFC, .rfc7798NoDON)] {
        var auto = AppleHPHEVCDepacketizer()
        _ = try auto.append(sequence: 0, timestamp: 1, marker: true, payload: wire)
        precondition(auto.detectedPacketization == expected)
        let picture = expected == .appleDON ? Data(nal.prefix(2)) + Data([0,9]) + Data(nal.dropFirst(2)) : nal
        check(try auto.append(sequence: 1, timestamp: 2, marker: true, payload: picture) == [nal])
        precondition(auto.detectedPacketization == expected, "mode must persist across timestamps")
    }
    var unresolved = AppleHPHEVCDepacketizer()
    do { _ = try unresolved.append(sequence: 0, timestamp: 0, marker: true, payload: nal); fatalError("guessed framing from slice") } catch {}
    precondition(unresolved.detectedPacketization == nil)
    var incomplete = AppleHPHEVCDepacketizer()
    do { _ = try incomplete.append(sequence: 0, timestamp: 0, marker: true, payload: Data([96,1,0,3,64,1,128])); fatalError("incomplete parameter set selected framing") } catch {}
    precondition(incomplete.detectedPacketization == nil)
    let pipeline = try HighPerformanceMediaPipeline(output: sink, videoPayloadType: 100, videoCodec: .hevc)
    func packet(_ ssrc: UInt32, seq: UInt8 = 0, payload: Data? = nil) throws -> HighPerformanceRTPPacket {
        var data = Data([0x80,228,0,seq,0,0,0,seq])
        data.append(contentsOf: [UInt8(truncatingIfNeeded:ssrc>>24),UInt8(truncatingIfNeeded:ssrc>>16),UInt8(truncatingIfNeeded:ssrc>>8),UInt8(truncatingIfNeeded:ssrc)])
        data.append(payload ?? paramsApple); return try HighPerformanceRTPPacket(data)
    }
    try pipeline.consumeVideo(packet(1));
    try pipeline.consumeVideo(packet(1, seq: 1, payload: Data(nal.prefix(2)) + Data([0,9]) + Data(nal.dropFirst(2)))); precondition(sink.video == 0)
    try pipeline.observe([HighPerformanceSenderReport(ssrc:1,ntpSeconds:10,ntpFraction:0,rtpTimestamp:1)],clockRate:90000)
    precondition(sink.video == 1 && sink.starts == 1)
    do { try pipeline.consumeVideo(packet(2)); fatalError("multi-SSRC silently accepted") } catch {}
    pipeline.reset(); precondition(!pipeline.isPlaying)
    print("HEVC single/AP/FU, wrap/loss/malformed/DON, native format and single-SSRC pipeline passed")
 }
}
