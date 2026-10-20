import UIKit

/// UIKit can draw a monochrome path or beam, but exposes no bitmap/hotspot API.
/// Keep the native pointer when its positioning can match the server exactly;
/// otherwise render the server bitmap and hide the native pointer in that region.
@MainActor
struct RemoteCursorPresentation {
    let image: CGImage?
    let size: CGSize
    let hotspot: CGPoint
    let nativeShape: UIPointerShape?
    let isHidden: Bool

    init(_ cursor: RFBCursorShape) {
        guard cursor.width > 0, cursor.height > 0,
              cursor.width <= 512, cursor.height <= 512,
              cursor.rgba.count == cursor.width * cursor.height * 4 else {
            image = nil; size = .zero; hotspot = .zero; nativeShape = nil; isHidden = true
            return
        }
        let scale = min(1, 32 / CGFloat(max(cursor.width, cursor.height)))
        size = CGSize(width: CGFloat(cursor.width) * scale, height: CGFloat(cursor.height) * scale)
        hotspot = CGPoint(x: CGFloat(cursor.hotspotX) * scale, y: CGFloat(cursor.hotspotY) * scale)
        let bytes = [UInt8](cursor.rgba)
        var monochrome = true
        var rows: [(min: Int, max: Int)?] = []
        let path = UIBezierPath()
        for y in 0..<cursor.height {
            var first: Int?
            var last = 0
            var run: Int?
            for x in 0...cursor.width {
                let opaque = x < cursor.width && bytes[(y * cursor.width + x) * 4 + 3] != 0
                if opaque {
                    let pixel = (y * cursor.width + x) * 4
                    if bytes[pixel] != bytes[pixel + 1] || bytes[pixel + 1] != bytes[pixel + 2] { monochrome = false }
                    if first == nil { first = x }
                    last = x
                    if run == nil { run = x }
                } else if let start = run {
                    path.append(UIBezierPath(rect: CGRect(x: CGFloat(start) * scale, y: CGFloat(y) * scale,
                                                         width: CGFloat(x - start) * scale, height: scale)))
                    run = nil
                }
            }
            rows.append(first.map { ($0, last) })
        }
        isHidden = path.isEmpty
        image = CGDataProvider(data: cursor.rgba as CFData).flatMap {
            CGImage(width: cursor.width, height: cursor.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: cursor.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: $0,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        if isHidden {
            nativeShape = nil
        } else if monochrome && Self.isCenteredBeam(rows: rows, hotspotX: cursor.hotspotX, hotspotY: cursor.hotspotY) {
            nativeShape = .verticalBeam(length: path.bounds.height)
        } else if monochrome && path.bounds.minX == hotspot.x && path.bounds.minY == hotspot.y {
            // For a standalone UIPointerShape(path:), UIKit places the path's
            // bounding origin at the mouse position. Negative path translation
            // cannot encode an arbitrary hotspot, so do not use it for those.
            nativeShape = .path(path)
        } else {
            nativeShape = nil
        }
    }

    private static func isCenteredBeam(rows: [(min: Int, max: Int)?], hotspotX: Int, hotspotY: Int) -> Bool {
        guard let top = rows.firstIndex(where: { $0 != nil }),
              let bottom = rows.lastIndex(where: { $0 != nil }), bottom - top >= 8,
              abs(hotspotY * 2 - (top + bottom)) <= 1,
              let first = rows[top], let last = rows[bottom],
              first == last, first.max - first.min >= 2,
              abs(hotspotX * 2 - (first.min + first.max)) <= 1 else { return false }
        // Restrict recognition to a symmetric cap/stem/cap mask. Diagonal resize
        // arrows and other narrow shapes retain their exact bitmap instead.
        let capDepth = max(1, (bottom - top + 1) / 5)
        for y in top...bottom {
            guard let row = rows[y], abs(row.min + row.max - 2 * hotspotX) <= 1 else { return false }
            if y >= top + capDepth && y <= bottom - capDepth && row.max - row.min > 2 { return false }
            if row.min < first.min || row.max > first.max { return false }
        }
        return true
    }
}
