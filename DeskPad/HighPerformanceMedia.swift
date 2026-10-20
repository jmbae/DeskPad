import Foundation

enum HighPerformanceMediaError: Error {
    case malformedPacket, invalidClock, staleSenderReport, tooManyStreams
}

/// Parses authenticated, decrypted RTP only. SRTP authentication/replay checks must precede this.
struct HighPerformanceRTPPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data

    init(_ datagram: Data) throws {
        guard datagram.count >= 12, datagram.count <= 65535 else { throw HighPerformanceMediaError.malformedPacket }
        let b = Array(datagram)
        guard b[0] >> 6 == 2 else { throw HighPerformanceMediaError.malformedPacket }
        var start = 12 + Int(b[0] & 15) * 4
        guard start <= b.count else { throw HighPerformanceMediaError.malformedPacket }
        if b[0] & 0x10 != 0 {
            guard start + 4 <= b.count else { throw HighPerformanceMediaError.malformedPacket }
            start += 4 + Int(mediaU16(b, start + 2)) * 4
            guard start <= b.count else { throw HighPerformanceMediaError.malformedPacket }
        }
        var end = b.count
        if b[0] & 0x20 != 0 {
            let padding = Int(b[b.count - 1])
            guard padding > 0, padding <= end - start else { throw HighPerformanceMediaError.malformedPacket }
            end -= padding
        }
        marker = b[1] & 0x80 != 0
        payloadType = b[1] & 0x7F
        sequenceNumber = mediaU16(b, 2)
        timestamp = mediaU32(b, 4)
        ssrc = mediaU32(b, 8)
        payload = Data(b[start..<end])
    }
}

struct HighPerformanceSenderReport {
    let ssrc: UInt32
    let ntpSeconds: UInt32
    let ntpFraction: UInt32
    let rtpTimestamp: UInt32

    /// Accepts plaintext compound RTCP after SRTCP verification and trailer removal.
    /// Unknown packet types are length-checked and skipped, never interpreted as RTP.
    static func parseCompound(_ datagram: Data) throws -> [Self] {
        guard !datagram.isEmpty, datagram.count <= 65535 else { throw HighPerformanceMediaError.malformedPacket }
        let b = Array(datagram)
        var offset = 0
        var result: [Self] = []
        while offset < b.count {
            guard offset + 4 <= b.count, b[offset] >> 6 == 2 else { throw HighPerformanceMediaError.malformedPacket }
            let length = (Int(mediaU16(b, offset + 2)) + 1) * 4
            guard length <= b.count - offset else { throw HighPerformanceMediaError.malformedPacket }
            var contentLength = length
            if b[offset] & 0x20 != 0 {
                let padding = Int(b[offset + length - 1])
                guard offset + length == b.count, padding > 0, padding <= length - 4 else { throw HighPerformanceMediaError.malformedPacket }
                contentLength -= padding
            }
            if b[offset + 1] == 200 {
                guard contentLength >= 28 + Int(b[offset] & 31) * 24 else { throw HighPerformanceMediaError.malformedPacket }
                result.append(Self(ssrc: mediaU32(b, offset + 4), ntpSeconds: mediaU32(b, offset + 8),
                                   ntpFraction: mediaU32(b, offset + 12), rtpTimestamp: mediaU32(b, offset + 16)))
            }
            offset += length
        }
        return result
    }
}

/// Maps independent audio/video RTP clock domains onto a common sender timeline.
/// No synchronization is inferred before a stream supplies an RTCP Sender Report.
/// Confine to one receive queue/actor. Reset on reconnect, SSRC reuse or media re-offer.
struct HighPerformanceMediaClock {
    private struct Anchor { let report: HighPerformanceSenderReport; let rate: Double; let seconds: Double }
    private var epoch: HighPerformanceSenderReport?
    private var anchors: [UInt32: Anchor] = [:]

    mutating func reset() { epoch = nil; anchors.removeAll(keepingCapacity: true) }

    mutating func observe(_ report: HighPerformanceSenderReport, clockRate: Double) throws {
        guard clockRate.isFinite, clockRate > 0, clockRate <= 1_000_000_000 else { throw HighPerformanceMediaError.invalidClock }
        guard anchors[report.ssrc] != nil || anchors.count < 16 else { throw HighPerformanceMediaError.tooManyStreams }
        if let previous = anchors[report.ssrc] {
            guard ntpDifference(report, previous.report) > 0 else { throw HighPerformanceMediaError.staleSenderReport }
            guard previous.rate == clockRate else { throw HighPerformanceMediaError.invalidClock }
        }
        let origin = epoch ?? report
        anchors[report.ssrc] = Anchor(report: report, rate: clockRate, seconds: ntpDifference(report, origin))
        epoch = origin
    }

    /// Sender-relative seconds, suitable for assigning both audio and video sample PTS.
    /// A renderer must separately anchor this timeline to its local monotonic clock and
    /// playout delay. RTP offsets must stay within half the 32-bit timestamp space;
    /// periodic Sender Reports keep that bound valid. Reordered packets remain earlier.
    func presentationSeconds(ssrc: UInt32, timestamp: UInt32) -> Double? {
        guard let anchor = anchors[ssrc] else { return nil }
        let ticks = Int32(bitPattern: timestamp &- anchor.report.rtpTimestamp)
        return anchor.seconds + Double(ticks) / anchor.rate
    }

    private func ntpDifference(_ lhs: HighPerformanceSenderReport, _ rhs: HighPerformanceSenderReport) -> Double {
        // Integer subtraction before conversion avoids precision loss at modern NTP dates.
        Double(Int32(bitPattern: lhs.ntpSeconds &- rhs.ntpSeconds))
            + (Double(lhs.ntpFraction) - Double(rhs.ntpFraction)) / 4_294_967_296
    }
}

private func mediaU16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
private func mediaU32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}
