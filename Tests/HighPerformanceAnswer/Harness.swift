import Foundation
@main struct Harness {
    static func rejected(_ body: () throws -> Void) { do { try body(); fatalError("accepted malformed input") } catch {} }
    static func main() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var parser = AppleHPControlParser()
        var events: [AppleHPControlParser.Event] = []
        for byte in fixture { events += try parser.append(Data([byte])) }
        guard events.count == 1, case .mediaAnswer(let answer) = events[0] else { fatalError("answer missing") }
        precondition(answer.status == 1 && answer.audio.ssrc > 0)
        precondition(answer.video.codecPayloadType == 123 && answer.video.width == 1280 && answer.video.height == 720)
        precondition(answer.secondVideo == nil && answer.audio.opaqueField12?.count == 4)
        try parser.finish()
        // Multiple messages coalesced; status immediately before a fragmented FBU.
        var mixed = AppleHPControlParser()
        let status = Data([20,0,0,4,0,1,0,12])
        let all = try mixed.append(status + fixture + Data([2]))
        precondition(all.count == 3 && mixed.isAtMessageBoundary)
        var rekey = AppleHPControlParser()
        let keyMessage = Data([0,0,0,1]) + Data(repeating: 0, count: 8) + Data([0,0,4,79]) + Data(repeating: 0, count: 36)
        let changed = try rekey.append(keyMessage)
        guard case .rekey(let payload) = changed.first else { fatalError("rekey missing") }
        precondition(payload.count == 36 && rekey.isAtMessageBoundary)
        rejected { var p = AppleHPControlParser(); _ = try p.append(keyMessage + Data([2])) }
        rejected { var p = AppleHPControlParser(); _ = try p.append(Data([0xff])) }
        rejected { var p = AppleHPControlParser(); _ = try p.append(Data(repeating: 0, count: 1_048_577)) }
        rejected { var p = AppleHPControlParser(); _ = try p.append(Data(fixture.dropLast())); try p.finish() }
        rejected { _ = try AppleHPMediaAnswer(Data(fixture.dropFirst(16).dropLast())) }
        rejected { _ = try AppleHPProtoValue.parse(Data([8] + Array(repeating: UInt8(255), count: 10))) }
        rejected { _ = try AppleHPProtoValue.oneNumber(AppleHPProtoValue.parse(Data([8,1,8,2])), 1) }
        print("PASS HP answer: validated stream metadata, fragmentation/coalescing, strict bounds, rekey barrier, malformed protobuf")
    }
}
