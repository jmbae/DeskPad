import Foundation

@main
struct HPRecordHarness {
    static let zero = Data(repeating: 0, count: 16)
    // AES-128 known answer: encrypting zero with a zero key (ECB).
    static let wrapped = hex("66e94bd4ef8a2c3b884cfa59ca342b2e")
    static var rekey: Data { Data([0, 0, 0, 7]) + wrapped + wrapped }
    static func hex(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
    static func ready(send: UInt32 = 0, receive: UInt32 = 0) throws -> AppleHPRecordCipher {
        let cipher = try AppleHPRecordCipher(wrapKey: zero, sendSequence: send, receiveSequence: receive)
        try cipher.installRekey(payload: rekey)
        return cipher
    }
    static func reject(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch {}
    }
    static func main() throws {
        reject { _ = try AppleHPRecordCipher(wrapKey: Data()) }
        let inactive = try AppleHPRecordCipher(wrapKey: zero)
        reject { _ = try inactive.encode(body: Data([1])) }
        precondition(inactive.isFailed)
        reject { try inactive.installRekey(payload: rekey) }

        let sender = try ready(), receiver = try ready()
        precondition(sender.generation == 7)
        let abc = Data("abc".utf8)
        let wire = try sender.encode(body: abc)
        // Independently generated with Python hashlib + openssl AES-CBC.
        precondition(wire == hex("0020783c76a1fba0e42fc300052ae79c25fa2cdb39c7a257a47830212ca14f7050ec"))
        var bodies: [Data] = []
        for byte in wire { bodies += try receiver.receive(bytes: Data([byte])) }
        precondition(bodies == [abc])
        let payloads = [Data(), Data(repeating: 9, count: 11), Data(repeating: 1, count: 100),
                        Data(repeating: 255, count: AppleHPRecordCipher.maximumBodyLength)]
        var batch = Data()
        for payload in payloads { batch += try sender.encode(body: payload) }
        let decoded = try receiver.receive(bytes: batch)
        precondition(decoded == payloads)
        try receiver.finish()
        // Independent counters/IVs for traffic in the opposite direction.
        let reply = try receiver.encode(body: abc)
        precondition(reply == wire)
        let replied = try sender.receive(bytes: reply)
        precondition(replied == [abc])
        // Rekey rotates both streams but preserves record counters.
        try sender.installRekey(payload: rekey)
        try receiver.installRekey(payload: rekey)
        let afterRekey = try sender.encode(body: abc)
        precondition(afterRekey != wire)
        let rekeyBody = try receiver.receive(bytes: afterRekey)
        precondition(rekeyBody == [abc])

        for index in [2, 17, wire.count - 1] {
            let victim = try ready()
            var tampered = wire
            tampered[index] ^= 1
            reject { _ = try victim.receive(bytes: tampered) }
            precondition(victim.isFailed)
            reject { _ = try victim.receive(bytes: wire) }
        }
        let badLength = try ready()
        reject { _ = try badLength.receive(bytes: hex("002025eef2159dc8146599a5fdeb82401f08649c0a9036a297cb849cebbb006ac9e9")) }
        let randomPadding = try ready()
        let randomBody = try randomPadding.receive(bytes: hex("0020842c7e08f14df3258a464235b2e79912745cdd19b60c70a17af6e7df57bd65be"))
        precondition(randomBody == [abc], "Filler is arbitrary, not PKCS#7")
        let wrongSequence = try ready(receive: 1)
        reject { _ = try wrongSequence.receive(bytes: wire) }
        let replay = try ready()
        _ = try replay.receive(bytes: wire)
        reject { _ = try replay.receive(bytes: wire) }
        for header in [Data([0,0]), Data([0,16]), Data([0,33]), Data([255,255])] {
            let victim = try ready()
            reject { _ = try victim.receive(bytes: header) }
        }
        for count in [1, 2, wire.count - 1] {
            let partial = try ready()
            _ = try partial.receive(bytes: Data(wire.prefix(count)))
            reject { try partial.finish() }
        }
        let partial = try ready()
        _ = try partial.receive(bytes: Data([0]))
        reject { try partial.installRekey(payload: rekey) }
        let invalidRekey = try ready()
        reject { try invalidRekey.installRekey(payload: Data(repeating: 0, count: 35)) }
        let huge = try ready()
        reject { _ = try huge.encode(body: Data(repeating: 0, count: AppleHPRecordCipher.maximumBodyLength + 1)) }
        let finalSender = try ready(send: .max), finalReceiver = try ready(receive: .max)
        let last = try finalSender.encode(body: abc)
        _ = try finalReceiver.receive(bytes: last)
        reject { _ = try finalSender.encode(body: abc) }
        reject { _ = try finalReceiver.receive(bytes: last) }
        print("HP records passed: known-answer, duplex continuous CBC, fragmentation, coalescing, bounds, rekey, integrity, replay, EOF, counter exhaustion")
    }
}
