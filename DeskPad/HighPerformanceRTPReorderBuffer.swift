import Foundation

/// Authenticated video only, one instance per SSRC. Uses monotonic arrival time
/// solely for bounded repair deadlines, never as an A/V presentation timestamp.
struct HighPerformanceRTPReorderBuffer {
    struct Output {
        var packets: [HighPerformanceRTPPacket] = []
        var missing: [UInt16] = []
    }
    private var expected: UInt16?
    private var pending: [UInt16: HighPerformanceRTPPacket] = [:]
    private var pendingBytes = 0
    private var gapStarted: Double?
    private var lastRequest: Double?
    private var requests = 0
    var hasPending: Bool { !pending.isEmpty }
    var bufferedPacketCount: Int { pending.count }
    var bufferedByteCount: Int { pendingBytes }

    mutating func insert(_ packet: HighPerformanceRTPPacket, now: Double) -> Output {
        guard now.isFinite else { return Output() }
        if expected == nil { expected = packet.sequenceNumber }
        let distance = Int16(bitPattern: packet.sequenceNumber &- expected!)
        guard distance >= 0, pending[packet.sequenceNumber] == nil else { return Output() }
        var output = Output()
        if distance > 1024 || pending.count >= 512 || pendingBytes + packet.payload.count > 2 * 1024 * 1024 {
            // A bounded repair cannot span this burst. Release existing packets
            // with visible sequence gaps, allowing the decoder to request an IDR.
            releaseAll(into: &output)
            if let expected, Int16(bitPattern: packet.sequenceNumber &- expected) < 0 { return output }
            expected = packet.sequenceNumber
        }
        pending[packet.sequenceNumber] = packet
        pendingBytes += packet.payload.count
        releaseContiguous(into: &output)
        repair(now: now, into: &output)
        return output
    }

    mutating func flush(now: Double) -> Output {
        var output = Output()
        guard now.isFinite else { return output }
        releaseContiguous(into: &output)
        repair(now: now, into: &output)
        return output
    }

    private mutating func releaseContiguous(into output: inout Output) {
        while let expected, let packet = pending.removeValue(forKey: expected) {
            pendingBytes -= packet.payload.count
            output.packets.append(packet)
            self.expected = expected &+ 1
        }
        if pending.isEmpty { clearGap() }
    }
    private mutating func releaseAll(into output: inout Output) {
        guard let expected else { return }
        let ordered = pending.keys.sorted { $0 &- expected < $1 &- expected }
        for sequence in ordered {
            output.packets.append(pending[sequence]!)
            self.expected = sequence &+ 1
        }
        pending.removeAll(keepingCapacity: true); pendingBytes = 0; clearGap()
    }
    private mutating func clearGap() { gapStarted = nil; lastRequest = nil; requests = 0 }
    private mutating func repair(now: Double, into output: inout Output) {
        guard !pending.isEmpty, let expected else { return }
        if gapStarted == nil { gapStarted = now }
        if now - gapStarted! >= 0.06 {
            releaseAll(into: &output)
            return
        }
        guard requests < 2, lastRequest == nil || now - lastRequest! >= 0.02 else { return }
        let farthest = pending.keys.map { Int($0 &- expected) }.max() ?? 0
        guard farthest <= 1024 else { return }
        for offset in 0..<farthest {
            let sequence = expected &+ UInt16(offset)
            if pending[sequence] == nil { output.missing.append(sequence) }
        }
        // At most1024 requested sequence numbers, compressed into PID/BLP pairs.
        requests += 1; lastRequest = now
    }
}

/// RFC4585 generic NACK with an empty RR prefix, carried in authenticated SRTCP.
enum HighPerformanceNACK {
    static func compound(sender: UInt32, media: UInt32, sequences: [UInt16]) -> Data? {
        let missing = Set(sequences.prefix(1024)).sorted()
        guard !missing.isEmpty else { return nil }
        var entries: [(UInt16, UInt16)] = []
        var index = 0
        while index < missing.count && entries.count < 64 {
            let first = missing[index]; index += 1
            var mask: UInt16 = 0
            while index < missing.count {
                let distance = Int(missing[index]) - Int(first)
                guard (1...16).contains(distance) else { break }
                mask |= UInt16(1) << (distance - 1); index += 1
            }
            entries.append((first, mask))
        }
        var data = Data([0x80,201,0,1])
        func word(_ value: UInt32) { data.append(contentsOf: [UInt8(truncatingIfNeeded:value>>24),UInt8(truncatingIfNeeded:value>>16),UInt8(truncatingIfNeeded:value>>8),UInt8(truncatingIfNeeded:value)]) }
        word(sender)
        let length = 2 + entries.count
        data.append(contentsOf: [0x81,205,UInt8(length>>8),UInt8(length&255)])
        word(sender); word(media)
        for (first,mask) in entries { data.append(contentsOf: [UInt8(first>>8),UInt8(first&255),UInt8(mask>>8),UInt8(mask&255)]) }
        return data
    }
}
