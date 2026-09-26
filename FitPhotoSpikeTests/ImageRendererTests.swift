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

    func testOutputIsUprightSRGBJPEGWithExactDimensionsAndSourceUnchanged() throws {
        let input = try writeFixture(quadrants(), type: .jpeg, orientation: 6)
        let originalBytes = try Data(contentsOf: input)
        let output = outputURL()
        let result = try renderer.render(inputURL: input, outputURL: output, ratio: .fourFive)
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
        let result = try renderer.render(inputURL: input, outputURL: outputURL(), ratio: .fourFive)
        XCTAssertEqual(result.sourceWidth, 160)
        XCTAssertEqual(result.sourceHeight, 100)
        XCTAssertEqual(result.width * 5, result.height * 4)
    }

    func testUnsupportedFormatAndSameURLFail() throws {
        let gif = try writeFixture(quadrants(), type: .gif)
        XCTAssertThrowsError(try renderer.render(inputURL: gif, outputURL: outputURL(), ratio: .fourFive))
        let input = try writeFixture(quadrants(), type: .png)
        XCTAssertThrowsError(try renderer.render(inputURL: input, outputURL: input, ratio: .fourFive))
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
        XCTAssertThrowsError(try renderer.render(inputURL: input, outputURL: outputURL(), ratio: .fourFive))
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

}
