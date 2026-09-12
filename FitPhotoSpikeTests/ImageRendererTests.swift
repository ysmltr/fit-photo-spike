import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FitPhotoSpike

/// Synthetic pixel fixtures make cropping, orientation, alpha and metadata
/// observable without relying on a developer's photo library. Run in Xcode;
/// these Apple-framework tests cannot execute on Windows.
final class ImageRendererTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let renderer = ImageRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private let red = CIColor(red: 1, green: 0, blue: 0)
    private let green = CIColor(red: 0, green: 1, blue: 0)
    private let blue = CIColor(red: 0, green: 0, blue: 1)
    private let yellow = CIColor(red: 1, green: 1, blue: 0)

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitPhotoSpikeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        context.clearCaches()
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testPortraitLandscapeSquareAndVeryTallScreenshotHaveFullContentAndWhitePadding() throws {
        for (width, height) in [(60, 100), (160, 100), (100, 100), (30, 240)] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let input = try writeFixture(CIImage(color: red).cropped(to: bounds), type: .png)
            let output = outputURL()
            let result = try renderer.render(inputURL: input, outputURL: output)
            let geometry = try CanvasGeometry(sourceWidth: width, sourceHeight: height)
            XCTAssertEqual(result.width * 5, result.height * 4)
            XCTAssertEqual(result.sourceWidth, width)
            XCTAssertEqual(result.sourceHeight, height)
            let pixels = try XCTUnwrap(CIImage(contentsOf: output))
            XCTAssertEqual(pixels.extent.width, CGFloat(geometry.width))
            XCTAssertEqual(pixels.extent.height, CGFloat(geometry.height))
            // Content near every source corner survives. The white pixel is
            // sampled well inside a border to avoid JPEG edge ringing.
            for point in cornerSamples(in: geometry.imageRect) {
                try assertPixel(pixels, at: point, equals: red,
                                message: "Source shape \(width)x\(height)")
            }
            let padding = geometry.imageRect.minX > 0
                ? CGPoint(x: geometry.imageRect.minX / 2, y: geometry.imageRect.midY)
                : CGPoint(x: geometry.imageRect.midX, y: geometry.imageRect.minY / 2)
            try assertPixel(pixels, at: padding, equals: .white,
                            message: "White padding for \(width)x\(height)")
        }
    }

    func testAllEightEXIFOrientationsKeepCorrectCorners() throws {
        // Each expected array is [top-left, top-right, bottom-left, bottom-right].
        let expected: [[CIColor]] = [
            [red, green, blue, yellow],
            [green, red, yellow, blue],
            [yellow, blue, green, red],
            [blue, yellow, red, green],
            [red, blue, green, yellow],
            [blue, red, yellow, green],
            [yellow, green, blue, red],
            [green, yellow, red, blue]
        ]
        for orientation in 1...8 {
            let input = try writeFixture(quadrants(), type: .jpeg, orientation: orientation)
            let output = outputURL()
            let result = try renderer.render(inputURL: input, outputURL: output)
            let width = orientation >= 5 ? 100 : 160
            let height = orientation >= 5 ? 160 : 100
            XCTAssertEqual(result.sourceWidth, width)
            XCTAssertEqual(result.sourceHeight, height)
            let geometry = try CanvasGeometry(sourceWidth: width, sourceHeight: height)
            let pixels = try XCTUnwrap(CIImage(contentsOf: output))
            for (point, color) in zip(cornerSamples(in: geometry.imageRect), expected[orientation - 1]) {
                try assertPixel(pixels, at: point, equals: color,
                                message: "EXIF orientation \(orientation)")
            }
        }
    }

    func testTransparentPNGFlattensToWhiteAndKeepsOpaqueContent() throws {
        let canvas = CGRect(x: 0, y: 0, width: 160, height: 100)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        let content = CIImage(color: red).cropped(to: CGRect(x: 50, y: 30, width: 60, height: 40))
            .composited(over: clear)
        let input = try writeFixture(content, type: .png)
        let output = outputURL()
        _ = try renderer.render(inputURL: input, outputURL: output)
        let pixels = try XCTUnwrap(CIImage(contentsOf: output))
        try assertPixel(pixels, at: CGPoint(x: 10, y: 60), equals: .white) // Transparent source pixel.
        try assertPixel(pixels, at: CGPoint(x: 80, y: 100), equals: red)
        try assertPixel(pixels, at: CGPoint(x: 80, y: 10), equals: .white) // Canvas padding.
        let source = try imageSource(at: output)
        let properties = try imageProperties(source)
        XCTAssertFalse((properties[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue ?? false)
    }

    func testEveryOuterEdgeSurvivesAspectFitAndDownsampling() throws {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 320)
        var fixture = CIImage(color: .black).cropped(to: bounds)
        for (rect, color) in [
            (CGRect(x: 0, y: 304, width: 640, height: 16), red),
            (CGRect(x: 0, y: 0, width: 640, height: 16), blue),
            (CGRect(x: 0, y: 16, width: 16, height: 288), green),
            (CGRect(x: 624, y: 16, width: 16, height: 288), yellow)
        ] {
            fixture = CIImage(color: color).cropped(to: rect).composited(over: fixture)
        }
        let input = try writeFixture(fixture, type: .png)
        let output = outputURL()
        let result = try renderer.render(inputURL: input,
                                         outputURL: output, maximumLongEdge: 400)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 400)
        let pixels = try XCTUnwrap(CIImage(contentsOf: output))
        try assertPixel(pixels, at: CGPoint(x: 160, y: 276), equals: red)
        try assertPixel(pixels, at: CGPoint(x: 160, y: 124), equals: blue)
        try assertPixel(pixels, at: CGPoint(x: 4, y: 200), equals: green)
        try assertPixel(pixels, at: CGPoint(x: 316, y: 200), equals: yellow)
        try assertPixel(pixels, at: CGPoint(x: 160, y: 20), equals: .white)
    }

    func testOutputIsUprightSRGBJPEGWithExactDimensionsAndSourceUnchanged() throws {
        let input = try writeFixture(quadrants(), type: .jpeg, orientation: 6)
        let originalBytes = try Data(contentsOf: input)
        let output = outputURL()
        let result = try renderer.render(inputURL: input, outputURL: output)
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        let source = try imageSource(at: output)
        XCTAssertEqual(CGImageSourceGetType(source)! as String, UTType.jpeg.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let properties = try imageProperties(source)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, result.width)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, result.height)
        XCTAssertEqual(result.width * 5, result.height * 4)
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
        XCTAssertTrue((properties[kCGImagePropertyProfileName as String] as? String)?
            .lowercased().contains("srgb") == true)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
    }

    func testHEICInputWhenEncoderIsAvailable() throws {
        let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
        guard supported.contains(UTType.heic.identifier) else {
            throw XCTSkip("HEIC fixture encoding is unavailable on this test destination.")
        }
        let input = try writeFixture(quadrants(), type: .heic)
        let result = try renderer.render(inputURL: input, outputURL: outputURL())
        XCTAssertEqual(result.sourceWidth, 160)
        XCTAssertEqual(result.sourceHeight, 100)
        XCTAssertEqual(result.width * 5, result.height * 4)
    }

    func testUnsupportedFormatAndSameURLFail() throws {
        let gif = try writeFixture(quadrants(), type: .gif)
        XCTAssertThrowsError(try renderer.render(inputURL: gif, outputURL: outputURL()))
        let input = try writeFixture(quadrants(), type: .png)
        XCTAssertThrowsError(try renderer.render(inputURL: input, outputURL: input))
    }

    func testAnimatedPNGIsRejected() throws {
        let input = outputURL().appendingPathExtension("png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            input as CFURL, UTType.png.identifier as CFString, 2, nil
        ))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]
        ] as CFDictionary)
        let frame = try cgImage(quadrants())
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(destination, frame, properties)
        CGImageDestinationAddImage(destination, frame, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try renderer.render(inputURL: input, outputURL: outputURL()))
    }

    private func quadrants() -> CIImage {
        let bottomLeft = CIImage(color: blue).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 50))
        let bottomRight = CIImage(color: yellow).cropped(to: CGRect(x: 80, y: 0, width: 80, height: 50))
        let topLeft = CIImage(color: red).cropped(to: CGRect(x: 0, y: 50, width: 80, height: 50))
        let topRight = CIImage(color: green).cropped(to: CGRect(x: 80, y: 50, width: 80, height: 50))
        return topLeft.composited(over: topRight).composited(over: bottomLeft).composited(over: bottomRight)
            .cropped(to: CGRect(x: 0, y: 0, width: 160, height: 100))
    }

    private func cgImage(_ image: CIImage) throws -> CGImage {
        try XCTUnwrap(context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB))
    }

    private func writeFixture(_ image: CIImage, type: UTType, orientation: Int = 1) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "image")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try cgImage(image), [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func outputURL() -> URL {
        temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
    }

    private func imageSource(at url: URL) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    private func imageProperties(_ source: CGImageSource) throws -> [String: Any] {
        try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func cornerSamples(in rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX + 10, y: rect.maxY - 10),
         CGPoint(x: rect.maxX - 10, y: rect.maxY - 10),
         CGPoint(x: rect.minX + 10, y: rect.minY + 10),
         CGPoint(x: rect.maxX - 10, y: rect.minY + 10)]
    }

    private func assertPixel(_ image: CIImage, at point: CGPoint, equals color: CIColor,
                             message: String = "", file: StaticString = #filePath,
                             line: UInt = #line) throws {
        // Sample one pixel in Core Image coordinates; a one-row buffer avoids
        // ambiguity about CGImage bitmap row order in orientation tests.
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1),
                           format: .RGBA8, colorSpace: sRGB)
        }
        // JPEG chroma subsampling and rounding make exact byte equality wrong.
        for (channel, expected) in zip(pixel.prefix(3), [color.red, color.green, color.blue]) {
            XCTAssertEqual(Double(channel), Double(expected) * 255, accuracy: 30,
                           message, file: file, line: line)
        }
        XCTAssertEqual(pixel[3], 255, message, file: file, line: line)
    }
}
