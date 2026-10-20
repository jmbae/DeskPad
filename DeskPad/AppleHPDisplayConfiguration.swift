import Foundation

/// Experimental virtual-display request. Sending this can curtain the host;
/// callers must only send it after the user selects the experimental HP mode.
enum AppleHPDisplayConfiguration {
    enum Failure: Error { case invalidGeometry, invalidName }

    /// A single 60 Hz SDR mode with one backing pixel per logical point.
    /// Server display-layout replies remain authoritative for input mapping.
    static func make(width: Int = 1280, height: Int = 720, name: String = "DeskPad Virtual Display") throws -> Data {
        guard (320...3840).contains(width), (240...2160).contains(height), width % 2 == 0, height % 2 == 0 else {
            throw Failure.invalidGeometry
        }
        let nameBytes = Data(name.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 119, !nameBytes.contains(0) else { throw Failure.invalidName }
        let descriptorSize = 156 + 28
        var packet = Data(repeating: 0, count: 12 + descriptorSize)
        func write(_ value: UInt64, bytes: Int, at offset: Int) {
            for index in 0..<bytes {
                packet[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (bytes - index - 1)))
            }
        }
        packet[0] = 0x1d
        write(UInt64(packet.count - 4), bytes: 2, at: 2)
        write(1, bytes: 2, at: 4) // protocol version
        write(1, bytes: 2, at: 6) // one virtual display
        let descriptor = 12
        write(UInt64(descriptorSize), bytes: 2, at: descriptor)
        packet.replaceSubrange((descriptor + 2)..<(descriptor + 2 + nameBytes.count), with: nameBytes)
        write(1, bytes: 4, at: descriptor + 0x7a) // dynamic geometry
        write(4, bytes: 4, at: descriptor + 0x7e) // virtual display
        // Nominal 96 dpi dimensions for this synthetic panel, not host hardware.
        write(UInt64(Float(Double(width) * 25.4 / 96).bitPattern), bytes: 4, at: descriptor + 0x82)
        write(UInt64(Float(Double(height) * 25.4 / 96).bitPattern), bytes: 4, at: descriptor + 0x86)
        write(3840, bytes: 4, at: descriptor + 0x8a)
        write(2160, bytes: 4, at: descriptor + 0x8e)
        // Current/preferred mode indices and rotations are all zero.
        write(1, bytes: 2, at: descriptor + 0x9a)
        let mode = descriptor + 0x9c
        for offset in [0, 8] { write(UInt64(width), bytes: 4, at: mode + offset) }
        for offset in [4, 12] { write(UInt64(height), bytes: 4, at: mode + offset) }
        write(Double(60).bitPattern, bytes: 8, at: mode + 16)
        return packet
    }
}
