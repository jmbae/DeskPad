import Foundation
import zlib

/// Version-2 media response carried by encoding 1010. This schema is grounded
/// in the observed reply; it must not be confused with version-1 announcements.
/// No keys are present here: use the original offer's directional SRTP keys.
struct AppleHPMediaAnswer {
    enum Failure: Error { case malformed, unsupportedVersion, oversized, invalidCompression }
    struct Stream {
        let ssrc: UInt32
        let codecPayloadType: UInt8?
        let width: Int?
        let height: Int?
        let opaqueField12: Data?
        /// Opaque negotiated fields retained without inventing clock-rate semantics.
        let descriptionFields: [UInt64: [AppleHPProtoValue]]
    }
    let status: UInt32
    let audio: Stream
    let video: Stream
    let secondVideo: Stream?

    /// Includes the two-byte payload-size prefix, but not the rectangle header.
    init(_ payload: Data) throws {
        let b = [UInt8](payload)
        guard b.count >= 20, b.count <= 65537, Int(hpU16(b, 0)) + 2 == b.count else { throw Failure.malformed }
        guard hpU16(b, 2) == 2, hpU16(b, 4) == 2 else { throw Failure.unsupportedVersion }
        status = hpU32(b, 6)
        let sizes = [Int(hpU16(b, 10)), Int(hpU16(b, 12)), Int(hpU16(b, 14))]
        guard sizes[0] > 0, sizes[1] > 0, sizes.allSatisfy({ $0 <= 32768 }),
              20 + sizes.reduce(0, +) == b.count else { throw Failure.malformed }
        audio = try Self.stream(Data(b[20..<(20 + sizes[0])]), video: false)
        let videoStart = 20 + sizes[0]
        video = try Self.stream(Data(b[videoStart..<(videoStart + sizes[1])]), video: true)
        secondVideo = sizes[2] == 0 ? nil : try Self.stream(Data(b[(videoStart + sizes[1])...]), video: true)
    }

    private static func stream(_ bytes: Data, video: Bool) throws -> Stream {
        guard bytes.starts(with: Data("bplist00".utf8)),
              let plist = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              plist.count <= 32, let compressed = plist["avcMediaStreamNegotiatorMediaBlob"] as? Data else { throw Failure.malformed }
        let fields = try AppleHPProtoValue.parse(inflate(compressed))
        let description = try AppleHPProtoValue.parse(AppleHPProtoValue.oneBytes(fields, video ? 5 : 3))
        let ssrc = try AppleHPProtoValue.oneNumber(description, 1)
        guard ssrc > 0, ssrc <= UInt32.max else { throw Failure.malformed }
        var codec: UInt8?, width: Int?, height: Int?
        if video {
            let codecFields = try AppleHPProtoValue.parse(AppleHPProtoValue.oneBytes(description, 3))
            let payloadType = try AppleHPProtoValue.oneNumber(codecFields, 1)
            let w = try AppleHPProtoValue.oneNumber(description, 4), h = try AppleHPProtoValue.oneNumber(description, 5)
            guard payloadType < 128, w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 64_000_000 else { throw Failure.malformed }
            codec = UInt8(payloadType); width = Int(w); height = Int(h)
        }
        let config = fields[12] == nil ? nil : try AppleHPProtoValue.oneBytes(fields, 12)
        guard config == nil || (2...64).contains(config!.count) else { throw Failure.malformed }
        return Stream(ssrc: UInt32(ssrc), codecPayloadType: codec, width: width, height: height,
                      opaqueField12: config, descriptionFields: description)
    }

    private static func inflate(_ input: Data) throws -> Data {
        guard !input.isEmpty, input.count <= 32768 else { throw Failure.oversized }
        var output = Data(count: 65536), count = uLongf(65536), sourceCount = uLong(input.count)
        let status = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { src in
            uncompress2(out.bindMemory(to: Bytef.self).baseAddress, &count,
                        src.bindMemory(to: Bytef.self).baseAddress, &sourceCount)
        } }
        guard status == Z_OK, sourceCount == input.count else { throw Failure.invalidCompression }
        output.count = Int(count)
        return output
    }
}

enum AppleHPProtoValue {
    case number(UInt64), bytes(Data), fixed(Data)
    static func parse(_ data: Data) throws -> [UInt64: [Self]] {
        guard data.count <= 65536 else { throw AppleHPMediaAnswer.Failure.oversized }
        let b = [UInt8](data); var offset = 0, count = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < b.count else { throw AppleHPMediaAnswer.Failure.malformed }
                let byte = b[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { throw AppleHPMediaAnswer.Failure.malformed }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw AppleHPMediaAnswer.Failure.malformed
        }
        var fields: [UInt64: [Self]] = [:]
        while offset < b.count {
            count += 1
            guard count <= 1024 else { throw AppleHPMediaAnswer.Failure.oversized }
            let tag = try varint(), field = tag >> 3, wire = tag & 7
            guard field > 0, field <= 0x1fffffff else { throw AppleHPMediaAnswer.Failure.malformed }
            let value: Self
            if wire == 0 { value = .number(try varint()) }
            else {
                let length: UInt64
                switch wire { case 1: length = 8; case 5: length = 4; case 2: length = try varint(); default: throw AppleHPMediaAnswer.Failure.malformed }
                guard length <= UInt64(b.count - offset) else { throw AppleHPMediaAnswer.Failure.malformed }
                let bytes = Data(b[offset..<(offset + Int(length))]); offset += Int(length)
                value = wire == 2 ? .bytes(bytes) : .fixed(bytes)
            }
            fields[field, default: []].append(value)
        }
        return fields
    }
    static func oneNumber(_ fields: [UInt64: [Self]], _ key: UInt64) throws -> UInt64 {
        guard let values = fields[key], values.count == 1, case .number(let value) = values[0] else { throw AppleHPMediaAnswer.Failure.malformed }
        return value
    }
    static func oneBytes(_ fields: [UInt64: [Self]], _ key: UInt64) throws -> Data {
        guard let values = fields[key], values.count == 1, case .bytes(let value) = values[0] else { throw AppleHPMediaAnswer.Failure.malformed }
        return value
    }
}
private func hpU16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) << 8 | UInt16(b[p + 1]) }
private func hpU32(_ b: [UInt8], _ p: Int) -> UInt32 { UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3]) }
