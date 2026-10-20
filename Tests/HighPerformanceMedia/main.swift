import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
func rejects(_ bytes: [UInt8], rtcp: Bool = false) { do { if rtcp { _ = try HighPerformanceSenderReport.parseCompound(Data(bytes)) } else { _ = try HighPerformanceRTPPacket(Data(bytes)) }; fatalError("accepted malformed packet") } catch {} }
let packet = try HighPerformanceRTPPacket(Data([0xB1, 0xE4, 0xFF, 0xFE, 0,0,0,1, 0,0,0,2, 0,0,0,3, 0xBE,0xDE,0,1, 9,8,7,6, 42,43,0,2]))
check(packet.sequenceNumber == 65534 && packet.timestamp == 1 && packet.ssrc == 2 && packet.marker && packet.payloadType == 100, "RTP fields")
check(packet.payload == Data([42,43]), "extension, CSRC and padding excluded")
rejects([]); rejects([0x80,100]); rejects([0x40,100,0,0,0,0,0,0,0,0,0,0]); rejects([0xA0,100,0,0,0,0,0,0,0,0,0,0,0]); rejects([0x90,100,0,0,0,0,0,0,0,0,0,0,0,0,255,255])
func report(_ ssrc: UInt32, _ seconds: UInt32, _ fraction: UInt32, _ timestamp: UInt32) -> HighPerformanceSenderReport { HighPerformanceSenderReport(ssrc: ssrc, ntpSeconds: seconds, ntpFraction: fraction, rtpTimestamp: timestamp) }
let srBytes: [UInt8] = [0x80,200,0,6, 0,0,0,2, 0,0,0,10, 128,0,0,0, 0,0,0,99, 0,0,0,0, 0,0,0,0]
let reports = try HighPerformanceSenderReport.parseCompound(Data(srBytes + [0x80,201,0,1,0,0,0,2]))
check(reports.count == 1 && reports[0].rtpTimestamp == 99 && reports[0].ntpFraction == 0x80000000, "compound SR")
rejects(Array(srBytes.dropLast()), rtcp: true); rejects([0x81,200,0,6] + Array(srBytes.dropFirst(4)), rtcp: true)
var clock = HighPerformanceMediaClock()
check(clock.presentationSeconds(ssrc: 1, timestamp: 1) == nil, "wait for SR")
try clock.observe(report(1, 100, 0, 0xFFFFFF00), clockRate: 90000)
try clock.observe(report(2, 100, 0x80000000, 1000), clockRate: 48000)
check(abs(clock.presentationSeconds(ssrc: 1, timestamp: 0x00015E90)! - 1) < 0.000001, "timestamp wrap")
check(abs(clock.presentationSeconds(ssrc: 2, timestamp: 25000)! - 1) < 0.000001, "audio/video common NTP")
check(clock.presentationSeconds(ssrc: 1, timestamp: 0xFFFFFEA6)! < 0, "reordered timestamp")
do { try clock.observe(report(1, 99, 0, 1), clockRate: 90000); fatalError("accepted stale SR") } catch {}
do { try clock.observe(report(1, 101, 0, 1), clockRate: 0); fatalError("accepted zero clock") } catch {}
clock.reset()
check(clock.presentationSeconds(ssrc: 1, timestamp: 0) == nil, "reconnect clears anchors")
try clock.observe(report(1, UInt32.max, 0, 0), clockRate: 90000)
try clock.observe(report(2, 0, 0, 0), clockRate: 48000)
check(clock.presentationSeconds(ssrc: 2, timestamp: 0) == 1, "NTP era wrap")
print("HighPerformanceMedia: parser bounds, SR, independent clocks, wrap, reorder and reset passed")
for length in 0..<12 { rejects(Array(repeating: 0, count: length)) }
for length in 0..<srBytes.count { rejects(Array(srBytes.prefix(length)), rtcp: true) }
rejects([0x80,100] + Array(repeating: 0, count: 65534))
rejects([0xA0,200,0,7] + Array(srBytes.dropFirst(4)) + [0,0,0,0], rtcp: true)
rejects([0xA0,200,0,7] + Array(srBytes.dropFirst(4)) + [0,0,0,4] + srBytes, rtcp: true)
var bounded = HighPerformanceMediaClock()
for id in UInt32(0)..<16 { try bounded.observe(report(id, 1, 0, 0), clockRate: 48000) }
do { try bounded.observe(report(16, 1, 0, 0), clockRate: 48000); fatalError("unbounded SSRCs") } catch {}
do { try bounded.observe(report(0, 2, 0, 0), clockRate: .nan); fatalError("NaN clock") } catch {}
do { try bounded.observe(report(0, 2, 0, 0), clockRate: 90000); fatalError("clock changed without reset") } catch {}
// Deterministic malformed datagrams exercise every bounded read path without networking.
var random: UInt64 = 42
for length in 0..<512 {
    var bytes = [UInt8]()
    for _ in 0..<length { random = random &* 6364136223846793005 &+ 1; bytes.append(UInt8(truncatingIfNeeded: random >> 32)) }
    _ = try? HighPerformanceRTPPacket(Data(bytes))
    _ = try? HighPerformanceSenderReport.parseCompound(Data(bytes))
}
print("Additional truncation, padding, SSRC bounds and malformed datagram checks passed")
