import Foundation

/// Bounded single-SSRC HEVC receiver. Apple places DONL after every single-NAL
/// header and every FU header, and once in AP (without per-unit DOND).
struct AppleHPHEVCDepacketizer {
    enum Packetization { case rfc7798NoDON, appleDON }
    enum Failure: Error { case malformed, limitExceeded }
    var packetization: Packetization = .appleDON
    private var timestamp: UInt32?
    private var expected: UInt16?
    private var units: [Data] = []
    private var fragment = Data()
    private var fragmentHeader: [UInt8]?
    private var fragmentDON: UInt16?
    private var bytes = 0
    private var packets = 0
    private var damaged = false
    private var completed = false

    mutating func append(sequence: UInt16, timestamp incoming: UInt32, marker: Bool, payload: Data) throws -> [Data]? {
        if timestamp != incoming {
            timestamp = incoming; expected = nil; units = []; fragment = Data()
            fragmentHeader = nil; fragmentDON = nil; bytes = 0; packets = 0; damaged = false; completed = false
        }
        guard !completed else { return nil }
        if let expected, expected != sequence { damaged = true }
        expected = sequence &+ 1; packets += 1
        guard packets <= 8192 else { damaged = true; throw Failure.limitExceeded }
        guard !damaged else { return nil }
        do {
            let b = [UInt8](payload)
            guard (3...65535).contains(b.count), b[0] & 128 == 0, b[1] & 7 != 0 else { throw Failure.malformed }
            let type = (b[0] >> 1) & 63
            let donBytes = packetization == .appleDON ? 2 : 0
            switch type {
            case 0...47:
                guard fragmentHeader == nil, b.count > 2 + donBytes else { throw Failure.malformed }
                try add(Data(b.prefix(2)) + Data(b.dropFirst(2 + donBytes)))
            case 48:
                guard fragmentHeader == nil else { throw Failure.malformed }
                var p = 2 + donBytes
                var count = 0
                while p < b.count {
                    guard p + 2 <= b.count else { throw Failure.malformed }
                    let n = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                    guard n >= 3, n <= b.count - p else { throw Failure.malformed }
                    try add(Data(b[p..<(p + n)])); p += n; count += 1
                }
                guard count >= 2 else { throw Failure.malformed }
            case 49:
                guard b.count > 3 + donBytes else { throw Failure.malformed }
                let start = b[2] & 128 != 0, end = b[2] & 64 != 0, inner = b[2] & 63
                guard inner < 48, !(start && end) else { throw Failure.malformed }
                let header = [(b[0] & 0x81) | (inner << 1), b[1]]
                let don: UInt16? = donBytes == 2 ? UInt16(b[3]) << 8 | UInt16(b[4]) : nil
                if start {
                    guard fragmentHeader == nil else { throw Failure.malformed }
                    fragmentHeader = header; fragmentDON = don; fragment = Data(header)
                } else {
                    guard fragmentHeader == header, fragmentDON == don else { throw Failure.malformed }
                }
                guard bytes + fragment.count + b.count - 3 - donBytes <= 8 * 1024 * 1024 else { throw Failure.limitExceeded }
                fragment.append(contentsOf: b.dropFirst(3 + donBytes))
                if end { try add(fragment); fragment = Data(); fragmentHeader = nil; fragmentDON = nil }
            default: throw Failure.malformed
            }
            guard marker else { return nil }
            guard fragmentHeader == nil, !units.isEmpty else { throw Failure.malformed }
            completed = true
            return units
        } catch { damaged = true; units = []; fragment = Data(); throw error }
    }
    private mutating func add(_ nal: Data) throws {
        let b = [UInt8](nal.prefix(2))
        guard nal.count >= 3, b[0] & 128 == 0, b[1] & 7 != 0, (b[0] >> 1) & 63 < 48 else { throw Failure.malformed }
        guard units.count < 256, bytes + nal.count <= 8 * 1024 * 1024 else { throw Failure.limitExceeded }
        bytes += nal.count; units.append(nal)
    }
}
