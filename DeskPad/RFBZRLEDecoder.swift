import Foundation
import zlib

// RFC 6143 §7.7.6 / rfbproto ZRLE: one zlib stream per connection.
// The client negotiates 32-bit little-endian RGB888, so CPIXEL is B,G,R.
// This instance belongs exclusively to the transport actor.
nonisolated final class RFBZRLEDecoder {
    enum DecodeError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let detail) = self { return "잘못된 ZRLE 화면 데이터: \(detail)" }
            return nil
        }
    }

    private let stream: UnsafeMutablePointer<z_stream>
    private var initialized = false

    init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
    }

    deinit {
        if initialized { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    static func maximumCompressedLength(width: Int, height: Int) throws -> Int {
        let inflated = try maximumInflatedLength(width: width, height: height)
        // Deflate overhead allowance, while rejecting huge lengths for tiny
        // rectangles before receiving or allocating their payloads.
        return min(128 * 1024 * 1024, inflated + inflated / 1000 + 64 * 1024)
    }

    private static func maximumInflatedLength(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000 else {
            throw DecodeError.invalid("사각형 크기가 허용 범위를 벗어났습니다.")
        }
        let tileCount = ((width + 63) / 64) * ((height + 63) / 64)
        return width * height * 4 + tileCount * 382
    }

    func decode(_ compressed: Data, width: Int, height: Int,
                deadline: ContinuousClock.Instant = .now + .seconds(20)) throws -> Data {
        let maximumCompressed = try Self.maximumCompressedLength(width: width, height: height)
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
        // Worst legal tile: four bytes per pixel (plain RLE length-one runs),
        // plus header and largest possible palette. Bound before inflating.
        let maximumInflated = try Self.maximumInflatedLength(width: width, height: height)
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
                let b = try byte(), g = try byte(), r = try byte()
                return (r, g, b)
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
                     x: Int, y: Int, width: Int, height: Int, sourceIsRGBA: Bool = false) {
        guard width > 0, height > 0 else { return }
        source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                let input = sourceBytes.bindMemory(to: UInt8.self)
                let output = destinationBytes.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    let sourceStart = row * width * 4
                    let destinationStart = ((y + row) * destinationWidth + x) * 4
                    if sourceIsRGBA {
                        output.baseAddress!.advanced(by: destinationStart).update(from: input.baseAddress!.advanced(by: sourceStart), count: width * 4)
                    } else {
                        for column in 0..<width {
                            let i = sourceStart + column * 4, o = destinationStart + column * 4
                            output[o] = input[i + 2]
                            output[o + 1] = input[i + 1]
                            output[o + 2] = input[i]
                            output[o + 3] = 255
                        }
                    }
                }
            }
        }
    }
}
