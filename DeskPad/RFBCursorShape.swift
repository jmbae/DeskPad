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
