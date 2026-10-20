import XCTest
import UIKit
@testable import DeskPad

@MainActor final class LargeDesktopRenderingTests: XCTestCase {
    func testWideAndTallDesktopPreserveOrientationAndTileBoundaries() throws {
        for size in [CGSize(width: 18048, height: 192), CGSize(width: 192, height: 18048)] {
            let width = Int(size.width), height = Int(size.height)
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let zone = (width > height ? x : y) / 8192
                    let bright: UInt8 = (width > height ? y : x) < 96 ? 255 : 96
                    let offset = (y * width + x) * 4
                    bytes[offset] = zone == 0 ? bright : 0
                    bytes[offset + 1] = zone == 1 ? bright : 0
                    bytes[offset + 2] = zone == 2 ? bright : 0
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let bounds = CGRect(origin: .zero, size: CGSize(width: size.width / 24, height: size.height / 24))
            let view = RemoteDesktopUIView(frame: bounds)
            view.desktopSize = size; view.desktopImage = image
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
            for actualSize in [false, true] {
                if actualSize { view.actualSize() } else { view.resetViewport() }
                let actual = renderer.image { context in context.cgContext.interpolationQuality = .none; view.draw(bounds) }
                let reference = renderer.image { context in
                    context.cgContext.interpolationQuality = .none
                    if actualSize {
                        context.cgContext.translateBy(x: bounds.midX * (1 - 24), y: bounds.midY * (1 - 24))
                        context.cgContext.scaleBy(x: 24, y: 24)
                    }
                    UIImage(cgImage: image).draw(in: bounds)
                }
                let actualBytes = try XCTUnwrap(actual.cgImage?.dataProvider?.data)
                let referenceBytes = try XCTUnwrap(reference.cgImage?.dataProvider?.data)
                XCTAssertEqual(actualBytes as Data, referenceBytes as Data, "Orientation or tile boundary differs for \(size), actual size: \(actualSize)")
            }
        }
    }
}
