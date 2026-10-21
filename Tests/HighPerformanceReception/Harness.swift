import Foundation
@main struct Harness {
 static func main() throws {
    func word(_ data: Data, _ offset: Int) -> UInt32 { data.dropFirst(offset).prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    func packet(_ seq: UInt16, _ timestamp: UInt32 = 0) throws -> HighPerformanceRTPPacket {
        try HighPerformanceRTPPacket(Data([0x80,100,UInt8(seq>>8),UInt8(seq&255),UInt8(truncatingIfNeeded:timestamp>>24),UInt8(truncatingIfNeeded:timestamp>>16),UInt8(truncatingIfNeeded:timestamp>>8),UInt8(truncatingIfNeeded:timestamp),0,0,0,2]))
    }
    var report = AppleHPReceptionReport()
    precondition(report.receiverReport(sender:1,media:2,now:0) == Data([0x80,201,0,1,0,0,0,1]))
    report.observe(try packet(65534),now:0)
    report.observe(try packet(0),now:0)
    let lost = report.receiverReport(sender:1,media:2,now:0)
    precondition(lost.count == 32 && Array(lost.prefix(4)) == [0x81,201,0,7])
    precondition(word(lost,12) == 0x55000001 && word(lost,16) == 65536)
    report.observe(try packet(65535),now:0.01)
    report.observe(HighPerformanceSenderReport(ssrc:2,ntpSeconds:0x12345678,ntpFraction:0xabcdef00,rtpTimestamp:0),now:1)
    let repaired = report.receiverReport(sender:1,media:2,now:1.5)
    precondition(word(repaired,12) == 0 && word(repaired,16) == 65536)
    precondition(word(repaired,24) == 0x5678abcd && word(repaired,28) == 32768)
    let sr = AppleHPReceptionReport.senderReport(sender:1,unixTime:1.5)
    precondition(sr.count == 28 && word(sr,8) == 2208988801 && word(sr,12) == 0x80000000)
    precondition(word(sr,20) == 0 && word(sr,24) == 0)
    let parsed = try HighPerformanceSenderReport.parseCompound(sr + repaired)
    precondition(parsed.count == 1 && parsed[0].ssrc == 1)
    var jitter = AppleHPReceptionReport()
    jitter.observe(try packet(1,0),now:0)
    jitter.observe(try packet(2,900),now:0.02)
    precondition(word(jitter.receiverReport(sender:1,media:2,now:0.02),20) == 56)
    print("RR loss fraction, rollover, late repair, LSR/DLSR, jitter and compound SR vectors passed")
 }
}
