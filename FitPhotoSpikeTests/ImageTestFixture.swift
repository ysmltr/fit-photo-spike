import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FitPhotoSpike

/// Synthetic images shared by the standalone renderer and batch tests.
enum ImageTestFixture {
    static func pngData(width: Int = 24, height: Int = 16,
                        color: CIColor = CIColor(red: 1, green: 0, blue: 0)) throws -> Data {
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        let cgImage = try XCTUnwrap(context.createCGImage(image, from: image.extent,
                                                         format: .RGBA8, colorSpace: colorSpace))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageRenderingError.destinationFailed
        }
        return data as Data
    }

    static func properties(at url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    static func assertCenterPixel(at url: URL, equals color: CIColor,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(CIImage(contentsOf: url), file: file, line: line)
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let bytes = try XCTUnwrap(buffer.baseAddress, file: file, line: line)
            context.render(image, toBitmap: bytes, rowBytes: 4,
                           bounds: CGRect(x: floor(image.extent.midX), y: floor(image.extent.midY),
                                          width: 1, height: 1),
                           format: .RGBA8, colorSpace: colorSpace)
        }
        for (channel, expected) in zip(pixel.prefix(3), [color.red, color.green, color.blue]) {
            XCTAssertEqual(Double(channel), Double(expected) * 255, accuracy: 30, file: file, line: line)
        }
    }
}
