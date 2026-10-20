import Foundation
import CryptoKit

private struct Rectangle: Decodable {
    let width: Int
    let height: Int
    let compressed: Data
    let rgba: Data?
    let solid: [UInt8]?
    let digest: String?
}
private struct Case: Decodable {
    let name: String
    let rectangles: [Rectangle]
    let reject: Bool
    let expired: Bool
    let budgetMilliseconds: Int?
}

@main struct ZRLEHarness {
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for test in cases {
            let decoder = RFBZRLEDecoder()
            var rejected = false
            do {
                for rectangle in test.rectangles {
                    let started = ContinuousClock.now
                    let deadline = started + (test.expired ? .seconds(-1) : test.budgetMilliseconds.map { .milliseconds($0) } ?? .seconds(20))
                    let actual = try decoder.decode(rectangle.compressed, width: rectangle.width, height: rectangle.height, deadline: deadline)
                    let decodeDuration = started.duration(to: .now)
                    if let digest = rectangle.digest {
                        precondition(SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined() == digest)
                        print("BENCH \(test.name) compressed=\(rectangle.compressed.count) raw=\(actual.count) decode=\(decodeDuration)")
                    }
                    if let expected = rectangle.rgba { precondition(actual == expected, "Pixel mismatch: \(test.name)") }
                    if let solid = rectangle.solid {
                        precondition(actual.count == rectangle.width * rectangle.height * 4)
                        actual.withUnsafeBytes { raw in
                            let bytes = raw.bindMemory(to: UInt8.self)
                            for i in stride(from: 0, to: bytes.count, by: 4) {
                                precondition(bytes[i] == solid[0] && bytes[i+1] == solid[1] && bytes[i+2] == solid[2] && bytes[i+3] == 255)
                            }
                        }
                        print("BENCH \(test.name) compressed=\(rectangle.compressed.count) raw=\(actual.count) elapsed=\(started.duration(to: .now))")
                    }
                }
            } catch {
                rejected = true
                precondition(test.reject, "Unexpected decoder rejection \(test.name): \(error)")
            }
            precondition(rejected == test.reject, "Malformed input accepted: \(test.name)")
            print("PASS \(test.name)")
        }
        // Compare every byte with the previous Raw conversion, including a
        // subrectangle offset whose neighboring pixels must remain unchanged.
        let width = 6016, height = 3384
        var raw = Data(count: width * height * 4)
        raw.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i / 4096) }
        }
        var old = Data(count: raw.count)
        var started = ContinuousClock.now
        for row in 0..<height {
            for column in 0..<width {
                let i = (row * width + column) * 4
                old[i] = raw[i+2]; old[i+1] = raw[i+1]; old[i+2] = raw[i]; old[i+3] = 255
            }
        }
        let previousDuration = started.duration(to: .now)
        var current = Data(count: raw.count)
        started = .now
        RFBPixelCopy.copy(raw, into: &current, destinationWidth: width, x: 0, y: 0, width: width, height: height)
        let currentDuration = started.duration(to: .now)
        precondition(old == current)
        print("BENCH 6K Raw previous=\(previousDuration) buffer=\(currentDuration)")
        var inset = Data(repeating: 77, count: 4 * 4 * 4)
        RFBPixelCopy.copy(Data([1,2,3,4,5,6,7,8]), into: &inset, destinationWidth: 4, x: 1, y: 2, width: 2, height: 1)
        var expected = Data(repeating: 77, count: 4 * 4 * 4)
        expected.replaceSubrange(36..<44, with: [3,2,1,255,7,6,5,255])
        precondition(inset == expected)
        print("PASS Raw and inset conversion")
    }
}
