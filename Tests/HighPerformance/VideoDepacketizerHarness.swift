import Foundation
@main struct VideoDepacketizerHarness {
    static func checkNil(_ output: AppleHPVideoDepacketizer.Output?) { precondition(output == nil) }
    static func units(_ output: AppleHPVideoDepacketizer.Output?) -> [Data] {
        guard case .accessUnit(_, let nalUnits) = output else { fatalError("Expected access unit") }; return nalUnits
    }
    static func main() throws {
        var parser = AppleHPVideoDepacketizer()
        precondition(tryUnits(&parser, [0x61, 0x80], 1, 1, true) == [Data([0x61,0x80])])
        checkNil(try parser.append(sequence: 2, timestamp: 2, marker: false, payload: Data([0x7c,0x85,1,2])))
        checkNil(try parser.append(sequence: 3, timestamp: 2, marker: false, payload: Data([0x7c,0x05,3,4])))
        precondition(tryUnits(&parser, [0x7c,0x45,5], 4, 2, true) == [Data([0x65,1,2,3,4,5])])
        precondition(tryUnits(&parser, [0x78,0,2,0x67,1,0,2,0x68,2], 5, 3, true) == [Data([0x67,1]),Data([0x68,2])])
        parser.reset()
        _ = try parser.append(sequence: 65535, timestamp: 4, marker: false, payload: Data([0x7c,0x81,1]))
        precondition(tryUnits(&parser, [0x7c,0x41,2], 0, 4, true) == [Data([0x61,1,2])])
        _ = try parser.append(sequence: 1, timestamp: 5, marker: false, payload: Data([0x7c,0x81,1]))
        checkNil(try parser.append(sequence: 3, timestamp: 5, marker: true, payload: Data([0x7c,0x41,2])))
        precondition(tryUnits(&parser, [0x61,0x80], 4, 6, true).count == 1)
        _ = try parser.append(sequence: 5, timestamp: 7, marker: false, payload: Data([0x7c,0x81,1]))
        precondition(tryUnits(&parser, [0x61,0x80], 6, 8, true) == [Data([0x61,0x80])])
        for payload in [[UInt8](), [0x7c,0x41,1], [0x7c,0xc1,1], [0x78,0,8,0x67,1], [0xe1,1]] {
            parser.reset()
            do { _ = try parser.append(sequence: 1, timestamp: 1, marker: true, payload: Data(payload)); fatalError("Accepted malformed NAL") }
            catch AppleHPVideoDepacketizer.Failure.malformedPayload { }
        }
        let record: [UInt8] = [1,66,0,30,255,225,0,4,0x67,66,0,30,1,0,2,0x68,0xce]
        let size = record.count + 8
        let config = Data([0x92,0,0,0,0,0,0,UInt8(size),97,118,99,67] + record)
        guard case .configuration(let sps, let pps) = try AppleHPVideoDepacketizer.configuration(config) else { fatalError() }
        precondition(sps == [Data([0x67,66,0,30])] && pps == [Data([0x68,0xce])])
        do { _ = try AppleHPVideoDepacketizer.configuration(config.dropLast()); fatalError("Accepted truncated box") }
        catch AppleHPVideoDepacketizer.Failure.malformedPayload { }
        parser.reset(); parser.aggregationFormat = .appleDON
        precondition(tryUnits(&parser, [0x78,0,3,0,2,0x67,1], 1, 1, true) == [Data([0x67,1])])
        print("PASS: single NAL, FU-A, STAP-A, Apple DON option, sequence wrap/loss, timestamp discard, malformed payload, avcC bounds")
    }
    static func tryUnits(_ parser: inout AppleHPVideoDepacketizer, _ bytes: [UInt8], _ sequence: UInt16, _ timestamp: UInt32, _ marker: Bool) -> [Data] {
        do { return units(try parser.append(sequence: sequence, timestamp: timestamp, marker: marker, payload: Data(bytes))) }
        catch { fatalError("Unexpected: \(error)") }
    }
}
