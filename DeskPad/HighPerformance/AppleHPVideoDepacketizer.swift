import Foundation

/// One instance per authenticated SSRC. Feed packets in sequence order after
/// the transport's bounded reorder window; missing packets discard the whole AU.
struct AppleHPVideoDepacketizer {
    enum AggregationFormat { case rfc6184, appleDON }
    enum Failure: Error { case malformedPayload, limitExceeded }
    enum Output {
        case configuration(sps: [Data], pps: [Data])
        case accessUnit(timestamp: UInt32, nalUnits: [Data])
    }
    var aggregationFormat: AggregationFormat = .rfc6184
    private var timestamp: UInt32?
    private var expectedSequence: UInt16?
    private var damaged = false
    private var completed = false
    private var nalUnits: [Data] = []
    private var fragment = Data()
    private var fragmentHeader: UInt8?
    private var byteCount = 0
    private var packetCount = 0
    private let maximumBytes = 8 * 1024 * 1024

    mutating func reset() {
        timestamp = nil; expectedSequence = nil; clearFrame()
    }
    private mutating func clearFrame() {
        damaged = false; completed = false; nalUnits.removeAll(keepingCapacity: true)
        fragment.removeAll(keepingCapacity: true); fragmentHeader = nil
        byteCount = 0; packetCount = 0
    }

    mutating func append(sequence: UInt16, timestamp incoming: UInt32, marker: Bool, payload: Data) throws -> Output? {
        if timestamp != incoming {
            clearFrame(); timestamp = incoming; expectedSequence = nil
        }
        guard !completed else { return nil }
        if let expectedSequence, sequence != expectedSequence { damaged = true }
        expectedSequence = sequence &+ 1
        packetCount += 1
        if packetCount > 8192 { damaged = true; throw Failure.limitExceeded }
        guard !damaged else { if marker { completed = true }; return nil }
        do {
            guard !payload.isEmpty, payload.count <= 65_535 else { throw Failure.malformedPayload }
            if payload.first == 0x92 {
                // Configuration belongs to its own RTP access unit, not a slice.
                guard nalUnits.isEmpty, fragment.isEmpty else { throw Failure.malformedPayload }
                let result = try Self.configuration(payload)
                if marker { completed = true }
                return result
            }
            try consume(payload)
            guard marker else { return nil }
            completed = true
            guard fragmentHeader == nil, !nalUnits.isEmpty else { throw Failure.malformedPayload }
            return .accessUnit(timestamp: incoming, nalUnits: nalUnits)
        } catch {
            damaged = true
            nalUnits.removeAll(keepingCapacity: true); fragment.removeAll(keepingCapacity: true)
            fragmentHeader = nil
            throw error
        }
    }

    private mutating func add(_ nal: Data) throws {
        guard nal.count >= 2, let header = nal.first, header & 0x80 == 0,
              (1...23).contains(header & 31) else { throw Failure.malformedPayload }
        guard nalUnits.count < 256, byteCount + nal.count <= maximumBytes else { throw Failure.limitExceeded }
        byteCount += nal.count; nalUnits.append(nal)
    }
    private mutating func consume(_ payload: Data) throws {
        let bytes = [UInt8](payload), first = bytes[0], type = bytes[0] & 31
        guard first & 128 == 0 else { throw Failure.malformedPayload }
        switch type {
        case 1...23:
            guard fragmentHeader == nil else { throw Failure.malformedPayload }
            try add(payload)
        case 24:
            guard fragmentHeader == nil else { throw Failure.malformedPayload }
            var cursor = aggregationFormat == .appleDON ? 3 : 1
            guard cursor < bytes.count else { throw Failure.malformedPayload }
            while cursor < bytes.count {
                guard cursor + 2 <= bytes.count else { throw Failure.malformedPayload }
                let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]); cursor += 2
                guard length > 0, length <= bytes.count - cursor else { throw Failure.malformedPayload }
                try add(Data(bytes[cursor..<(cursor + length)])); cursor += length
            }
        case 28:
            guard bytes.count > 2 else { throw Failure.malformedPayload }
            let start = bytes[1] & 128 != 0, end = bytes[1] & 64 != 0
            let innerType = bytes[1] & 31, header = (first & 0x60) | innerType
            guard bytes[1] & 32 == 0, (1...23).contains(innerType), !(start && end) else { throw Failure.malformedPayload }
            if start {
                guard fragmentHeader == nil else { throw Failure.malformedPayload }
                fragmentHeader = header; fragment = Data([header])
            } else {
                guard fragmentHeader == header else { throw Failure.malformedPayload }
            }
            guard byteCount + fragment.count + bytes.count - 2 <= maximumBytes else { throw Failure.limitExceeded }
            fragment.append(contentsOf: bytes.dropFirst(2))
            if end { try add(fragment); fragment = Data(); fragmentHeader = nil }
        default:
            throw Failure.malformedPayload
        }
    }

    /// Apple 0x92 decoder-config wrapper contains an ISO BMFF avcC box.
    /// Its declared box extent bounds every read; never search inside NALs.
    static func configuration(_ payload: Data) throws -> Output {
        let bytes = [UInt8](payload)
        guard bytes.first == 0x92, bytes.count <= 65_535 else { throw Failure.malformedPayload }
        var record: ArraySlice<UInt8>?
        if bytes.count >= 12 {
            for offset in 4..<(bytes.count - 7) where Array(bytes[offset..<(offset + 4)]) == [97,118,99,67] {
                let length = bytes[(offset - 4)..<offset].reduce(0) { ($0 << 8) | Int($1) }
                guard length >= 15, length <= bytes.count - offset + 4 else { continue }
                record = bytes[(offset + 4)..<(offset - 4 + length)]; break
            }
        }
        guard let record else { throw Failure.malformedPayload }
        let data = Array(record)
        guard data.count >= 7, data[0] == 1, data[4] & 0xfc == 0xfc, data[5] & 0xe0 == 0xe0 else { throw Failure.malformedPayload }
        var position = 6
        func parameterSets(_ count: Int, type: UInt8) throws -> [Data] {
            guard count > 0 else { throw Failure.malformedPayload }
            var result: [Data] = []
            for _ in 0..<count {
                guard position + 2 <= data.count else { throw Failure.malformedPayload }
                let length = Int(data[position]) << 8 | Int(data[position + 1]); position += 2
                guard length >= 2, length <= data.count - position, data[position] & 31 == type,
                      data[position] & 128 == 0 else { throw Failure.malformedPayload }
                result.append(Data(data[position..<(position + length)])); position += length
            }
            return result
        }
        let sps = try parameterSets(Int(data[5] & 31), type: 7)
        guard position < data.count else { throw Failure.malformedPayload }
        let count = Int(data[position]); position += 1
        let pps = try parameterSets(count, type: 8)
        return .configuration(sps: sps, pps: pps)
    }
}
