import Foundation
import zlib

// Quality changes are negotiated only when opening a new connection.
nonisolated enum VNCColorQuality: String, CaseIterable, Sendable {
    case fullColor, balanced, lowLatency

    var pixelFormat: RFBPixelFormat {
        switch self {
        case .fullColor: .rgb888
        case .balanced: .rgb565
        case .lowLatency: .rgb332
        }
    }
}

// The three true-color formats advertised by this client. Pixel words are
// little endian; channel maxima in SetPixelFormat are always network endian.
nonisolated enum RFBPixelFormat: String, Sendable {
    case rgb888, rgb565, rgb332

    var bytesPerPixel: Int {
        switch self { case .rgb888: 4; case .rgb565: 2; case .rgb332: 1 }
    }
    var bytesPerCPixel: Int { self == .rgb888 ? 3 : bytesPerPixel }
    var wireBytes: Data {
        switch self {
        case .rgb888: Data([32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0])
        case .rgb565: Data([16,16,0,1,0,31,0,63,0,31,11,5,0,0,0,0])
        case .rgb332: Data([8,8,0,1,0,7,0,7,0,3,5,2,0,0,0,0])
        }
    }

    func rgb(_ value: UInt32) -> (UInt8, UInt8, UInt8) {
        switch self {
        case .rgb888:
            return (UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255))
        case .rgb565:
            return (UInt8((((value >> 11) & 31) * 255 + 15) / 31),
                    UInt8((((value >> 5) & 63) * 255 + 31) / 63),
                    UInt8(((value & 31) * 255 + 15) / 31))
        case .rgb332:
            return (UInt8((((value >> 5) & 7) * 255 + 3) / 7),
                    UInt8((((value >> 2) & 7) * 255 + 3) / 7),
                    UInt8(((value & 3) * 255 + 1) / 3))
        }
    }
}

// RFC 6143 §7.7.6 / rfbproto ZRLE: one zlib stream per connection.
// CPIXEL uses B,G,R for RGB888 and little-endian 2/1-byte words for RGB565/332.
// This instance belongs exclusively to the transport actor.
nonisolated final class RFBZRLEDecoder {
    enum DecodeError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let detail) = self { return "잘못된 ZRLE 화면 데이터: \(detail)" }
            return nil
        }
    }

    private let pixelFormat: RFBPixelFormat
    private let stream: UnsafeMutablePointer<z_stream>
    private var initialized = false

    init(pixelFormat: RFBPixelFormat = .rgb888) {
        self.pixelFormat = pixelFormat
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
    }

    deinit {
        if initialized { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    static func maximumCompressedLength(width: Int, height: Int, pixelFormat: RFBPixelFormat = .rgb888) throws -> Int {
        let inflated = try maximumInflatedLength(width: width, height: height, pixelFormat: pixelFormat)
        // Deflate overhead allowance, while rejecting huge lengths for tiny
        // rectangles before receiving or allocating their payloads.
        return min(128 * 1024 * 1024, inflated + inflated / 1000 + 64 * 1024)
    }

    private static func maximumInflatedLength(width: Int, height: Int, pixelFormat: RFBPixelFormat) throws -> Int {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000 else {
            throw DecodeError.invalid("사각형 크기가 허용 범위를 벗어났습니다.")
        }
        let tileCount = ((width + 63) / 64) * ((height + 63) / 64)
        return width * height * (pixelFormat.bytesPerCPixel + 1) + tileCount * (1 + 127 * pixelFormat.bytesPerCPixel)
    }

    func decode(_ compressed: Data, width: Int, height: Int,
                deadline: ContinuousClock.Instant = .now + .seconds(20)) throws -> Data {
        let maximumCompressed = try Self.maximumCompressedLength(width: width, height: height, pixelFormat: pixelFormat)
        guard !compressed.isEmpty, compressed.count <= maximumCompressed else {
            throw DecodeError.invalid("사각형 또는 압축 길이가 허용 범위를 벗어났습니다.")
        }
        try checkDeadline(deadline)
        if !initialized {
            guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw DecodeError.invalid("압축 해제기를 초기화하지 못했습니다.")
            }
            initialized = true
        }
        // Worst legal tile: CPIXEL plus one byte per pixel (plain RLE length-one runs),
        // plus header and largest possible palette. Bound before inflating.
        let maximumInflated = try Self.maximumInflatedLength(width: width, height: height, pixelFormat: pixelFormat)
        let inflated = try inflateRectangle(compressed, limit: maximumInflated, deadline: deadline)
        var output = Data(count: width * height * 4)
        try inflated.withUnsafeBytes { inputBytes in
            let input = inputBytes.bindMemory(to: UInt8.self)
            var cursor = 0
            func byte() throws -> UInt8 {
                guard cursor < input.count else { throw DecodeError.invalid("타일 데이터가 잘렸습니다.") }
                defer { cursor += 1 }
                return input[cursor]
            }
            func pixel() throws -> (UInt8, UInt8, UInt8) {
                switch pixelFormat {
                case .rgb888:
                    let b = try byte(), g = try byte(), r = try byte()
                    return (r, g, b)
                case .rgb565:
                    let low = UInt32(try byte()), high = UInt32(try byte())
                    return pixelFormat.rgb(low | high << 8)
                case .rgb332:
                    return pixelFormat.rgb(UInt32(try byte()))
                }
            }
            func runLength(remaining: Int) throws -> Int {
                var length = 1
                while true {
                    let part = Int(try byte())
                    guard part <= remaining - length else { throw DecodeError.invalid("런 길이가 타일 경계를 넘었습니다.") }
                    length += part
                    if part != 255 { return length }
                }
            }
            try output.withUnsafeMutableBytes { outputBytes in
                let destination = outputBytes.bindMemory(to: UInt8.self)
                for tileY in stride(from: 0, to: height, by: 64) {
                    for tileX in stride(from: 0, to: width, by: 64) {
                        try checkDeadline(deadline)
                        let tileWidth = min(64, width - tileX), tileHeight = min(64, height - tileY)
                        let tilePixels = tileWidth * tileHeight
                        let mode = Int(try byte())
                        var index = 0
                        func write(_ color: (UInt8, UInt8, UInt8), count: Int = 1) {
                            for _ in 0..<count {
                                let offset = ((tileY + index / tileWidth) * width + tileX + index % tileWidth) * 4
                                destination[offset] = color.0
                                destination[offset + 1] = color.1
                                destination[offset + 2] = color.2
                                destination[offset + 3] = 255
                                index += 1
                            }
                        }
                        switch mode {
                        case 0:
                            for _ in 0..<tilePixels { write(try pixel()) }
                        case 1:
                            write(try pixel(), count: tilePixels)
                        case 2...16:
                            var palette: [(UInt8, UInt8, UInt8)] = []
                            for _ in 0..<mode { palette.append(try pixel()) }
                            let bits = mode == 2 ? 1 : mode <= 4 ? 2 : 4
                            let mask = (1 << bits) - 1
                            for _ in 0..<tileHeight {
                                var packed = 0
                                for column in 0..<tileWidth {
                                    let shift = 8 - bits - (column * bits % 8)
                                    if column * bits % 8 == 0 { packed = Int(try byte()) }
                                    let paletteIndex = (packed >> shift) & mask
                                    guard paletteIndex < palette.count else { throw DecodeError.invalid("팔레트 인덱스가 범위를 넘었습니다.") }
                                    write(palette[paletteIndex])
                                }
                            }
                        case 128:
                            while index < tilePixels {
                                let color = try pixel()
                                write(color, count: try runLength(remaining: tilePixels - index))
                            }
                        case 130...255:
                            var palette: [(UInt8, UInt8, UInt8)] = []
                            for _ in 0..<(mode - 128) { palette.append(try pixel()) }
                            while index < tilePixels {
                                let encodedIndex = Int(try byte())
                                let paletteIndex = encodedIndex & 127
                                guard paletteIndex < palette.count else { throw DecodeError.invalid("팔레트 인덱스가 범위를 넘었습니다.") }
                                let count = encodedIndex & 128 == 0 ? 1 : try runLength(remaining: tilePixels - index)
                                write(palette[paletteIndex], count: count)
                            }
                        default:
                            throw DecodeError.invalid("지원하지 않는 타일 형식 \(mode).")
                        }
                    }
                }
            }
            guard cursor == input.count else { throw DecodeError.invalid("사각형 뒤에 불필요한 데이터가 있습니다.") }
        }
        try checkDeadline(deadline)
        return output
    }

    private func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard .now < deadline else { throw DecodeError.invalid("압축 해제 시간이 초과되었습니다.") }
    }

    private func inflateRectangle(_ compressed: Data, limit: Int, deadline: ContinuousClock.Instant) throws -> Data {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try compressed.withUnsafeBytes { rawInput in
            let input = rawInput.bindMemory(to: UInt8.self)
            stream.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress!)
            stream.pointee.avail_in = uInt(input.count)
            defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
            while true {
                try checkDeadline(deadline)
                let previousInput = stream.pointee.avail_in
                let status = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.pointee.next_out = buffer.baseAddress!
                    stream.pointee.avail_out = uInt(buffer.count)
                    return inflate(stream, Z_SYNC_FLUSH)
                }
                let produced = chunk.count - Int(stream.pointee.avail_out)
                guard produced <= limit - result.count else { throw DecodeError.invalid("압축 해제 크기가 허용 범위를 넘었습니다.") }
                chunk.withUnsafeBufferPointer { result.append($0.baseAddress!, count: produced) }
                // ZRLE is a persistent, sync-flushed stream, not a sequence of
                // independent complete zlib files. Never silently reset it.
                guard status == Z_OK || status == Z_BUF_ERROR else {
                    throw DecodeError.invalid("압축 스트림 오류 \(status).")
                }
                if stream.pointee.avail_in == 0 && stream.pointee.avail_out > 0 { break }
                guard produced > 0 || stream.pointee.avail_in < previousInput else {
                    throw DecodeError.invalid("압축 스트림이 진행되지 않습니다.")
                }
            }
        }
        return result
    }
}

// Both paths produce RGBA without Foundation Data indexing per channel.
nonisolated enum RFBPixelCopy {
    static func copy(_ source: Data, into destination: inout Data, destinationWidth: Int,
                     x: Int, y: Int, width: Int, height: Int, sourceIsRGBA: Bool = false,
                     pixelFormat: RFBPixelFormat = .rgb888) {
        guard width > 0, height > 0 else { return }
        source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                let input = sourceBytes.bindMemory(to: UInt8.self)
                let output = destinationBytes.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    let sourcePixelBytes = sourceIsRGBA ? 4 : pixelFormat.bytesPerPixel
                    let sourceStart = row * width * sourcePixelBytes
                    let destinationStart = ((y + row) * destinationWidth + x) * 4
                    if sourceIsRGBA {
                        output.baseAddress!.advanced(by: destinationStart).update(from: input.baseAddress!.advanced(by: sourceStart), count: width * 4)
                    } else {
                        for column in 0..<width {
                            let i = sourceStart + column * sourcePixelBytes, o = destinationStart + column * 4
                            if pixelFormat == .rgb888 {
                                output[o] = input[i + 2]
                                output[o + 1] = input[i + 1]
                                output[o + 2] = input[i]
                            } else {
                                let value = UInt32(input[i]) | (pixelFormat == .rgb565 ? UInt32(input[i + 1]) << 8 : 0)
                                let color = pixelFormat.rgb(value)
                                output[o] = color.0; output[o + 1] = color.1; output[o + 2] = color.2
                            }
                            output[o + 3] = 255
                        }
                    }
                }
            }
        }
    }
}
