import Foundation
@main struct DisplayConfigurationHarness {
    static func main() throws {
        let data = try AppleHPDisplayConfiguration.make()
        precondition(data.count == 196)
        precondition(data.prefix(12) == Data([29,0,0,192,0,1,0,1,0,0,0,0]))
        precondition(data[12..<14] == Data([0,184]))
        precondition(data[134..<142] == Data([0,0,0,1,0,0,0,4]))
        precondition(data[166..<168] == Data([0,1]))
        precondition(data[168..<196] == Data([0,0,5,0,0,0,2,208,0,0,5,0,0,0,2,208,64,78,0,0,0,0,0,0,0,0,0,0]))
        precondition(data[158..<166] == Data(repeating: 0, count: 8))
        for (width,height) in [(0,720),(1281,720),(1280,721),(3842,720),(1280,2162)] {
            do { _ = try AppleHPDisplayConfiguration.make(width: width, height: height); fatalError("Invalid dimensions accepted") }
            catch AppleHPDisplayConfiguration.Failure.invalidGeometry { }
        }
        for name in ["",String(repeating:"x",count:120),"x\0y"] {
            do { _ = try AppleHPDisplayConfiguration.make(name:name); fatalError("Invalid name accepted") }
            catch AppleHPDisplayConfiguration.Failure.invalidName { }
        }
        _ = try AppleHPDisplayConfiguration.make(name: String(repeating: "x", count: 119))
        print("PASS: exact 196-byte virtual-display framing, 1280x720@60 SDR 1x, field bounds")
    }
}
