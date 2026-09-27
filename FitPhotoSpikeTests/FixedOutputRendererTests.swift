import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FitPhotoSpike

/// Synthetic corner and edge colors detect cropping, incorrect orientation,
/// nonuniform scaling and alpha handling in the shared fixed-size path.
final class FixedOutputRendererTests: XCTestCase {
    private var directory: URL!
    private let renderer = ImageRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let red = CIColor(red: 1, green: 0, blue: 0)
    private let green = CIColor(red: 0, green: 1, blue: 0)
    private let blue = CIColor(red: 0, green: 0, blue: 1)
    private let yellow = CIColor(red: 1, green: 1, blue: 0)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitPhotosFixedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        context.clearCaches()
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testPortraitLandscapeSquareAndTallOutputsHaveExactPixelsAndKeepFullImage() throws {
        for ratio in OutputRatio.allCases {
            for (width, height) in [(60, 100), (160, 100), (100, 100), (30, 240)] {
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                let fixture = quadrants(bounds)
                let input = try write(fixture, type: .png)
                let sourceBytes = try Data(contentsOf: input)
                let output = freshURL()
                let result = try renderer.render(inputURL: input, outputURL: output, ratio: ratio)
                XCTAssertEqual(result.width, ratio.width)
                XCTAssertEqual(result.height, ratio.height)
                XCTAssertEqual(try Data(contentsOf: input), sourceBytes)
                let properties = try ImageTestFixture.properties(at: output)
                XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, ratio.width)
                XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, ratio.height)
                XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetType(source)! as String, UTType.jpeg.identifier)
                let image = try XCTUnwrap(CIImage(contentsOf: output))
                let geometry = try CanvasGeometry(sourceWidth: width, sourceHeight: height, ratio: ratio)
                for (point, color) in zip(corners(in: geometry.imageRect), [red, green, blue, yellow]) {
                    assertPixel(image, at: point, equals: color)
                }
                if geometry.imageRect.minX > 1 {
                    assertPixel(image, at: CGPoint(x: geometry.imageRect.minX / 2,
                                                  y: geometry.imageRect.midY), equals: .white)
                } else if geometry.imageRect.minY > 1 {
                    assertPixel(image, at: CGPoint(x: geometry.imageRect.midX,
                                                  y: geometry.imageRect.minY / 2), equals: .white)
                }
            }
        }
    }

    func testEveryOuterEdgeSurvivesFixedSizeDownsamplingForEveryRatio() throws {
        let bounds = CGRect(x: 0, y: 0, width: 2160, height: 1080)
        var fixture = CIImage(color: .black).cropped(to: bounds)
        for (rect, color) in [
            (CGRect(x: 0, y: 1040, width: 2160, height: 40), red),
            (CGRect(x: 0, y: 0, width: 2160, height: 40), blue),
            (CGRect(x: 0, y: 40, width: 40, height: 1000), green),
            (CGRect(x: 2120, y: 40, width: 40, height: 1000), yellow)
        ] {
            fixture = CIImage(color: color).cropped(to: rect).composited(over: fixture)
        }
        let input = try write(fixture, type: .png)
        for ratio in OutputRatio.allCases {
            let output = freshURL()
            _ = try renderer.render(inputURL: input, outputURL: output, ratio: ratio)
            let image = try XCTUnwrap(CIImage(contentsOf: output))
            let rect = try CanvasGeometry(sourceWidth: 2160, sourceHeight: 1080, ratio: ratio).imageRect
            assertPixel(image, at: CGPoint(x: rect.midX, y: rect.maxY - 10), equals: red)
            assertPixel(image, at: CGPoint(x: rect.midX, y: rect.minY + 10), equals: blue)
            assertPixel(image, at: CGPoint(x: rect.minX + 10, y: rect.midY), equals: green)
            assertPixel(image, at: CGPoint(x: rect.maxX - 10, y: rect.midY), equals: yellow)
        }
    }

    func testAllEightEXIFOrientationsUseTheSharedUprightRenderingPath() throws {
        let expected: [[CIColor]] = [
            [red, green, blue, yellow], [green, red, yellow, blue],
            [yellow, blue, green, red], [blue, yellow, red, green],
            [red, blue, green, yellow], [blue, red, yellow, green],
            [yellow, green, blue, red], [green, yellow, red, blue]
        ]
        for orientation in 1...8 {
            let input = try write(quadrants(CGRect(x: 0, y: 0, width: 160, height: 100)),
                                  type: .jpeg, orientation: orientation)
            let output = freshURL()
            let result = try renderer.render(inputURL: input, outputURL: output, ratio: .nineSixteen)
            let width = orientation >= 5 ? 100 : 160
            let height = orientation >= 5 ? 160 : 100
            XCTAssertEqual(result.sourceWidth, width)
            XCTAssertEqual(result.sourceHeight, height)
            let rect = try CanvasGeometry(sourceWidth: width, sourceHeight: height, ratio: .nineSixteen).imageRect
            let image = try XCTUnwrap(CIImage(contentsOf: output))
            for (point, color) in zip(corners(in: rect), expected[orientation - 1]) {
                assertPixel(image, at: point, equals: color)
            }
        }
    }

    func testTransparentPNGIsFlattenedOverWhiteForEveryRatio() throws {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 100)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
        let opaque = CIImage(color: red).cropped(to: CGRect(x: 40, y: 25, width: 80, height: 50))
            .composited(over: clear)
        let input = try write(opaque, type: .png)
        for ratio in OutputRatio.allCases {
            let output = freshURL()
            _ = try renderer.render(inputURL: input, outputURL: output, ratio: ratio)
            let image = try XCTUnwrap(CIImage(contentsOf: output))
            let rect = try CanvasGeometry(sourceWidth: 160, sourceHeight: 100, ratio: ratio).imageRect
            assertPixel(image, at: CGPoint(x: rect.midX, y: rect.midY), equals: red)
            assertPixel(image, at: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.midY), equals: .white)
            let properties = try ImageTestFixture.properties(at: output)
            XCTAssertFalse((properties[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue ?? false)
        }
    }

    private func quadrants(_ bounds: CGRect) -> CIImage {
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2
        let regions = [(CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), red),
                       (CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), green),
                       (CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), blue),
                       (CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), yellow)]
        return regions.reduce(CIImage.empty()) { image, region in
            CIImage(color: region.1).cropped(to: region.0).composited(over: image)
        }.cropped(to: bounds)
    }

    private func write(_ image: CIImage, type: UTType, orientation: Int = 1) throws -> URL {
        let input = freshURL().appendingPathExtension(type.preferredFilenameExtension ?? "image")
        let cgImage = try XCTUnwrap(context.createCGImage(image, from: image.extent,
                                                         format: .RGBA8, colorSpace: colorSpace))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            input as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: orientation,
                                                       kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return input
    }

    private func freshURL() -> URL {
        directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpeg")
    }

    private func corners(in rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX + rect.width * 0.1, y: rect.maxY - rect.height * 0.1),
         CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.maxY - rect.height * 0.1),
         CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.1),
         CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY + rect.height * 0.1)]
    }

    private func assertPixel(_ image: CIImage, at point: CGPoint, equals color: CIColor,
                             file: StaticString = #filePath, line: UInt = #line) {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1),
                           format: .RGBA8, colorSpace: colorSpace)
        }
        for (actual, expected) in zip(pixel.prefix(3), [color.red, color.green, color.blue]) {
            XCTAssertEqual(Double(actual), Double(expected) * 255, accuracy: 30, file: file, line: line)
        }
        XCTAssertEqual(pixel[3], 255, file: file, line: line)
    }
}
