import Foundation
@main struct CursorHarness {
    static func main() throws {
        for format in [RFBPixelFormat.rgb888, .rgb565, .rgb332, .rgb332Padded] {
            let pixel: [UInt8] = switch format {
            case .rgb888: [0, 0, 255, 0]
            case .rgb565: [0, 248]
            case .rgb332: [224]
            case .rgb332Padded: [224, 0, 0, 0]
            }
            // Width nine forces row padding; the last bit of row one and first
            // bit of row two must not bleed into the other row.
            let payload = Data(Array(repeating: pixel, count: 18).flatMap { $0 } + [0,128,128,0])
            let shape = try RFBCursorShape.decode(payload, width: 9, height: 2, hotspotX: 8, hotspotY: 1, encoding: -239, pixelFormat: format)
            precondition(shape.hotspotX == 8 && shape.hotspotY == 1)
            precondition(shape.rgba[8*4..<10*4] == Data([255,0,0,255,255,0,0,255]))
            precondition(shape.rgba.prefix(8*4).allSatisfy { $0 == 0 })
            precondition(shape.rgba.suffix(8*4).allSatisfy { $0 == 0 })
        }
        let x = try RFBCursorShape.decode(Data([255,0,0,0,255,0,0x80,0xc0]), width: 3, height: 1, hotspotX: 0, hotspotY: 0, encoding: -240, pixelFormat: .rgb565)
        precondition(x.rgba == Data([255,0,0,255,0,255,0,255,0,0,0,0]))
        for encoding: Int32 in [-239, -240] {
            let hidden = try RFBCursorShape.decode(Data(), width: 0, height: 1, hotspotX: 65535, hotspotY: 65535, encoding: encoding, pixelFormat: .rgb888)
            precondition(hidden.isHidden && hidden.rgba.isEmpty)
        }
        func rejects(_ body: () throws -> Void) { do { try body(); fatalError("Accepted invalid cursor") } catch {} }
        rejects { _ = try RFBCursorShape.payloadLength(width: 513, height: 1, hotspotX: 0, hotspotY: 0, encoding: -239, pixelFormat: .rgb888) }
        rejects { _ = try RFBCursorShape.payloadLength(width: 1, height: 1, hotspotX: 1, hotspotY: 0, encoding: -239, pixelFormat: .rgb888) }
        rejects { _ = try RFBCursorShape.decode(Data([0]), width: 1, height: 1, hotspotX: 0, hotspotY: 0, encoding: -239, pixelFormat: .rgb888) }
        rejects { _ = try RFBCursorShape.decode(Data(), width: 0, height: 0, hotspotX: 0, hotspotY: 0, encoding: 0, pixelFormat: .rgb888) }
        let cache = RFBAppleCursorCache()
        let compressed = Data([120, 156, 226, 18, 145, 99, 104, 0, 0, 0, 0, 255, 255])
        let stored = try cache.decode(cacheID: 1000, compressed: compressed, width: 1, height: 1, hotspotX: 0, hotspotY: 0)
        precondition(stored?.rgba == Data([30,20,10,128]))
        let selected = try cache.decode(cacheID: 1000, compressed: Data(), width: 0, height: 0, hotspotX: 0, hotspotY: 0)
        precondition(selected == stored)
        let unknown = try cache.decode(cacheID: 2000, compressed: Data(), width: 0, height: 0, hotspotX: 0, hotspotY: 0)
        precondition(unknown == nil)
        let newSession = try RFBAppleCursorCache().decode(cacheID: 1000, compressed: Data(), width: 0, height: 0, hotspotX: 0, hotspotY: 0)
        precondition(newSession == nil)
        rejects { _ = try cache.decode(cacheID: 1, compressed: Data([0,0]), width: 1, height: 1, hotspotX: 0, hotspotY: 0) }
        print("PASS cursor decoder: color formats, padded masks, XCursor, hotspots, hidden, invalid lengths/sizes")
    }
}
