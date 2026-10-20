import Foundation

@main struct Integration {
 static func main() throws {
    let master = Data((0..<46).map { UInt8($0) })
    let sender = try HighPerformanceSRTPSender(masterKeyBlob: master, ssrc: 7, initialSequence: 65534)
    var receiver = try HighPerformanceSRTPReceiver(masterKeyBlob: master)
    var encrypted: [Data] = []
    for n in 0...270 { encrypted.append(try sender.protect(payload: Data([0x26,1,UInt8(truncatingIfNeeded:n)]),payloadType:100,timestamp:UInt32(n*3000),marker:true)) }
    var reorder = HighPerformanceRTPReorderBuffer()
    let first = reorder.insert(try receiver.receive(encrypted[0]),now:0)
    precondition(first.packets.map(\.sequenceNumber) == [65534])
    let hole = reorder.insert(try receiver.receive(encrypted[269]),now:0.001)
    precondition(hole.packets.isEmpty && hole.missing.count == 268)
    let nack = HighPerformanceNACK.compound(sender:8,media:7,sequences:hole.missing)!
    let feedbackSender = try HighPerformanceSRTCPSender(masterKeyBlob:master,ssrc:8)
    var feedbackReceiver = try HighPerformanceSRTCPReceiver(masterKeyBlob:master)
    let protectedNACK = try feedbackSender.protect(nack)
    let authenticatedNACK = try feedbackReceiver.receive(protectedNACK)
    precondition(authenticatedNACK == nack, "NACK authentication changed feedback")
    var delivered:[UInt16] = []
    for n in 1...268 {
        delivered += reorder.insert(try receiver.receive(encrypted[n]),now:0.025).packets.map(\.sequenceNumber)
    }
    precondition(delivered == (1...269).map { UInt16(truncatingIfNeeded:65534+$0) }, "authenticated repair crossed ROC out of order")
    precondition(!reorder.hasPending)
    do { _ = try receiver.receive(encrypted[1]); fatalError("replay reached jitter buffer") } catch HighPerformanceSRTPError.replay {}
    var forged = encrypted[270]; forged[forged.count-1] ^= 1
    do { _ = try receiver.receive(forged); fatalError("forged retransmit accepted") } catch HighPerformanceSRTPError.authenticationFailed {}
    let next = reorder.insert(try receiver.receive(encrypted[270]),now:0.03)
    precondition(next.packets.count == 1, "forged packet advanced replay/reorder state")
    print("Authenticated RTP268-packet repair acrossROC, protectedNACK roundtrip, replay+forgery isolation passed")
 }
}
