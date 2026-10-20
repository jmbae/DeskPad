import Foundation

/// RFC 4585 PSFB Picture Loss Indication, authenticated by SRTCP before send.
enum AppleHPFeedback {
    static func pictureLoss(sender: UInt32, media: UInt32) -> Data {
        var bytes = Data([0x81, 206, 0, 2])
        for value in [sender, media] {
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        return bytes
    }
}
