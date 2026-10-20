import Foundation

// RFB Cursor (-239) and XCursor (-240). The rectangle origin is a hotspot,
// not a framebuffer coordinate. nil in the model means no server shape yet;
// a zero-sized shape explicitly hides the cursor.
nonisolated struct RFBCursorShape: Equatable, Sendable {
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let rgba: Data
    var isHidden: Bool { width == 0 || height == 0 }

    enum DecodeError: Error { case invalidDimensions, invalidHotspot, invalidEncoding, invalidLength }

    static func payloadLength(width: Int, height: Int, hotspotX: Int, hotspotY: Int,
                              encoding: Int32, pixelFormat: RFBPixelFormat) throws -> Int {
        guard encoding == -239 || encoding == -240 else { throw DecodeError.invalidEncoding }
        // Cursor images are tiny; bound untrusted sizes before allocation/read.
        guard width >= 0, height >= 0, width <= 512, height <= 512 else { throw DecodeError.invalidDimensions }
        guard width > 0 && height > 0 else { return 0 }
        guard hotspotX >= 0, hotspotY >= 0, hotspotX < width, hotspotY < height else { throw DecodeError.invalidHotspot }
        let maskLength = ((width + 7) / 8) * height
        return encoding == -239 ? width * height * pixelFormat.bytesPerPixel + maskLength : 6 + maskLength * 2
    }

    static func decode(_ payload: Data, width: Int, height: Int, hotspotX: Int, hotspotY: Int,
                       encoding: Int32, pixelFormat: RFBPixelFormat) throws -> Self {
        let expected = try payloadLength(width: width, height: height, hotspotX: hotspotX,
                                         hotspotY: hotspotY, encoding: encoding, pixelFormat: pixelFormat)
        guard payload.count == expected else { throw DecodeError.invalidLength }
        guard width > 0 && height > 0 else {
            return Self(width: 0, height: 0, hotspotX: 0, hotspotY: 0, rgba: Data())
        }
        let bytes = [UInt8](payload)
        let stride = (width + 7) / 8
        let maskStart = encoding == -239 ? width * height * pixelFormat.bytesPerPixel : 6 + stride * height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let bit = UInt8(0x80 >> (x % 8))
                let packedIndex = y * stride + x / 8
                guard bytes[maskStart + packedIndex] & bit != 0 else { continue }
                let index = (y * width + x) * 4
                let rgb: (UInt8, UInt8, UInt8)
                if encoding == -239 {
                    let source = (y * width + x) * pixelFormat.bytesPerPixel
                    var word: UInt32 = 0
                    for byte in 0..<pixelFormat.bytesPerPixel { word |= UInt32(bytes[source + byte]) << (byte * 8) }
                    rgb = pixelFormat.rgb(word)
                } else {
                    let color = bytes[6 + packedIndex] & bit != 0 ? 0 : 3
                    rgb = (bytes[color], bytes[color + 1], bytes[color + 2])
                }
                rgba[index] = rgb.0; rgba[index + 1] = rgb.1; rgba[index + 2] = rgb.2; rgba[index + 3] = 255
            }
        }
        return Self(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, rgba: Data(rgba))
    }
}

// Apple's CursorImage (0x450) uses session-local opaque cache identifiers.
// Wire format documented from native captures by iShareScreen:
// https://github.com/renegadelink/iShareScreen/blob/main/docs/apple_vnc_rfc.md#83-cursorimage-0x450
import zlib

nonisolated final class RFBAppleCursorCache {
    private var shapes: [UInt32: RFBCursorShape] = [:]
    private var order: [UInt32] = []
    private var storedBytes = 0

    static func maximumCompressedLength(width: Int, height: Int, hotspotX: Int, hotspotY: Int) throws -> Int {
        _ = try RFBCursorShape.payloadLength(width: width, height: height, hotspotX: hotspotX,
            hotspotY: hotspotY, encoding: -239, pixelFormat: .rgb888)
        guard width > 0, height > 0 else { throw RFBCursorShape.DecodeError.invalidDimensions }
        return width * height * 5 + 4096
    }

    func decode(cacheID: UInt32, compressed: Data, width: Int, height: Int,
                hotspotX: Int, hotspotY: Int) throws -> RFBCursorShape? {
        // SELECT has no pixels; its rectangle geometry is zero, not hidden.
        if compressed.isEmpty {
            guard let shape = shapes[cacheID] else { return nil }
            order.removeAll { $0 == cacheID }
            order.append(cacheID)
            return shape
        }
        let maximum = try Self.maximumCompressedLength(width: width, height: height,
            hotspotX: hotspotX, hotspotY: hotspotY)
        guard compressed.count <= maximum else { throw RFBCursorShape.DecodeError.invalidLength }
        let expected = width * height * 5
        var raw = [UInt8](repeating: 0, count: expected + 1)
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBCursorShape.DecodeError.invalidLength
        }
        defer { inflateEnd(&stream) }
        let status = compressed.withUnsafeBytes { input in
            raw.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = output.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(expected + 1)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard (status == Z_OK || status == Z_STREAM_END), stream.avail_in == 0,
              stream.total_out == expected else { throw RFBCursorShape.DecodeError.invalidLength }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let alpha = raw[width * height * 4 + pixel]
            if alpha > 0 {
                rgba[offset] = raw[offset + 2]; rgba[offset + 1] = raw[offset + 1]
                rgba[offset + 2] = raw[offset]; rgba[offset + 3] = alpha
            }
        }
        let shape = RFBCursorShape(width: width, height: height, hotspotX: hotspotX,
                                  hotspotY: hotspotY, rgba: Data(rgba))
        if let old = shapes.removeValue(forKey: cacheID) { storedBytes -= old.rgba.count }
        order.removeAll { $0 == cacheID }
        while !order.isEmpty && (order.count >= 64 || storedBytes + shape.rgba.count > 16 * 1024 * 1024) {
            let oldest = order.removeFirst()
            if let old = shapes.removeValue(forKey: oldest) { storedBytes -= old.rgba.count }
        }
        shapes[cacheID] = shape
        order.append(cacheID)
        storedBytes += shape.rgba.count
        return shape
    }
}
