import Foundation
import Security
import zlib

/// Wire offer for the experimental single-picture H.264 / AAC-ELD profile.
/// No connection, display change, or media playback occurs in this builder.
nonisolated struct AppleHPMediaOffer {
    struct StreamKeys {
        let viewerToServer: Data
        let serverToViewer: Data
    }
    enum Failure: Error { case randomFailed, compressionFailed, oversizedOffer }
    let message: Data
    let videoKeys: StreamKeys
    let audioKeys: StreamKeys
    let videoSSRC: UInt32
    let audioSSRC: UInt32

    static func make() throws -> Self {
        let video = try makeKeys(), audio = try makeKeys()
        let videoSSRC = try randomSSRC(), audioSSRC = try randomSSRC()
        let videoOffer = try plist(video: true, ssrc: videoSSRC)
        let audioOffer = try plist(video: false, ssrc: audioSSRC)
        let bodySize = 216 + audioOffer.count + videoOffer.count
        guard bodySize <= Int(UInt16.max) else { throw Failure.oversizedOffer }
        var header = Data(repeating: 0, count: 36)
        header[0] = 0x1c
        put16(UInt16(bodySize), into: &header, at: 2)
        put16(3, into: &header, at: 4)
        // 60 fps first stream + separate cursor. No second video offer.
        // This scalar is big endian on the wire, including the agent IPC hop.
        header[9] = 5
        put16(UInt16(audioOffer.count), into: &header, at: 10)
        put16(UInt16(videoOffer.count), into: &header, at: 12)
        var session = UUID().uuid
        let uuidBytes = withUnsafeBytes(of: &session) { Data($0) }
        header.replaceSubrange(20..<36, with: uuidBytes)
        let message = header + audio.viewerToServer + audio.serverToViewer + audioOffer
            + video.viewerToServer + video.serverToViewer + videoOffer
        guard message.count == bodySize + 4 else { throw Failure.oversizedOffer }
        return Self(message: message, videoKeys: video, audioKeys: audio, videoSSRC: videoSSRC, audioSSRC: audioSSRC)
    }

    private static func plist(video: Bool, ssrc: UInt32) throws -> Data {
        var endpoint = Proto()
        endpoint.number(1, 0); endpoint.number(2, 1)
        endpoint.string(3, "DeskPad"); endpoint.string(4, "1.1")
        endpoint.string(5, ProcessInfo.processInfo.operatingSystemVersionString)
        let dictionary: [String: Any] = [
            "avcMediaStreamNegotiatorMode": video ? 7 : 8,
            "avcMediaStreamOptionRemoteEndpointInfo": endpoint.data,
            "avcMediaStreamOptionCallID": UUID().uuidString,
            "avcMediaStreamNegotiatorMediaBlob": try compressed(mediaDescription(video: video, ssrc: ssrc))
        ]
        let result = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        guard result.count < 16_384 else { throw Failure.oversizedOffer }
        return result
    }

    private static func mediaDescription(video: Bool, ssrc: UInt32) -> Data {
        var description = Proto()
        description.number(1, UInt64(ssrc)); description.number(2, 0)
        if video {
            var codec = Proto()
            // Apple bank identifier 123 requests H.264 output despite the
            // historical parameter naming. LTR feedback is not advertised.
            codec.number(1, 123)
            for variant in [1, 2, 1, 2] {
                var resolution = Proto()
                resolution.number(1, 1); resolution.number(2, UInt64(variant))
                resolution.number(3, 50115); resolution.number(4, 0)
                codec.bytes(2, resolution.data)
            }
            codec.string(3, "FLS;MS:-1;LF:-1;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;")
            codec.number(4, 1)
            description.bytes(3, codec.data)
            description.number(6, 1); description.number(7, 0)
            description.number(8, 63); description.number(9, 1); description.number(12, 1)
        } else {
            // AAC-ELD system-audio tier selector, not a target output bitrate.
            description.number(3, 0); description.number(4, 24191)
            description.number(5, 0); description.number(6, 0)
        }
        var message = Proto()
        message.number(1, 1); message.number(2, 1)
        message.bytes(video ? 5 : 3, description.data)
        message.string(6, "DeskPad 1.1")
        message.number(8, 0)
        // Negotiator's audio capability/tier records are required in both offers.
        let tiers: [(UInt64, UInt64, UInt64?)] = [
            (0, 40_000_000, 12288), (0, 6_000_000, 131072), (4074, 0, 16384),
            (16, 4100, nil), (0, 75_000_000, 524288), (0, 20_000_000, 98304),
            (4, 6500, nil), (0, 60_000_000, 262144), (1, 299, nil), (0, 100_000_000, 1048576)
        ]
        for (kind, rate, capacity) in tiers {
            var tier = Proto(); tier.number(1, kind); tier.number(2, rate)
            if let capacity { tier.number(3, capacity) }
            message.bytes(9, tier.data)
        }
        message.number(13, UInt64(Date().timeIntervalSince1970 * 1_000_000_000))
        message.number(14, 2); message.number(16, 0); message.number(18, 1)
        return message.data
    }

    private static func compressed(_ input: Data) throws -> Data {
        var count = compressBound(uLong(input.count))
        var result = Data(count: Int(count))
        let status = result.withUnsafeMutableBytes { output in
            input.withUnsafeBytes { source in
                compress2(output.bindMemory(to: Bytef.self).baseAddress, &count,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw Failure.compressionFailed }
        result.count = Int(count)
        return result
    }
    private static func makeKeys() throws -> StreamKeys {
        try StreamKeys(viewerToServer: random(46), serverToViewer: random(46))
    }
    private static func randomSSRC() throws -> UInt32 {
        var value: UInt32 = 0
        repeat { value = try random(4).reduce(0) { ($0 << 8) | UInt32($1) } } while value == 0
        return value
    }
    private static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.randomFailed }
        return data
    }
    private static func put16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255)
    }
    private struct Proto {
        var data = Data()
        mutating func varint(_ value: UInt64) {
            var remaining = value
            repeat {
                let byte = UInt8(remaining & 127); remaining >>= 7
                data.append(byte | (remaining == 0 ? 0 : 128))
            } while remaining != 0
        }
        mutating func number(_ field: UInt64, _ value: UInt64) { varint(field << 3); varint(value) }
        mutating func bytes(_ field: UInt64, _ value: Data) {
            varint((field << 3) | 2); varint(UInt64(value.count)); data.append(value)
        }
        mutating func string(_ field: UInt64, _ value: String) { bytes(field, Data(value.utf8)) }
    }
}
