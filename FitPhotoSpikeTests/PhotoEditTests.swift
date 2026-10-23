import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import FitPhotoSpike

/// Placement, backgrounds and per-photo edits in the shared export path,
/// using synthetic solid-color images.
final class PhotoEditTests: XCTestCase {
    private var directory: URL!
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitPhotosEditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        context.clearCaches()
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testStandardEditMatchesTheCenteredFitGeometryForEveryRatio() throws {
        for ratio in OutputRatio.allCases {
            for (width, height) in [(60, 100), (160, 100), (100, 100), (8064, 6048)] {
                let fit = try CanvasGeometry(sourceWidth: width, sourceHeight: height, ratio: ratio).imageRect
                let placed = PlacementGeometry.imageRect(source: CGSize(width: width, height: height),
                                                         canvas: ratio.canvasSize, edit: .standard)
                XCTAssertEqual(placed.minX, fit.minX, accuracy: 0.0001)
                XCTAssertEqual(placed.minY, fit.minY, accuracy: 0.0001)
                XCTAssertEqual(placed.width, fit.width, accuracy: 0.0001)
                XCTAssertEqual(placed.height, fit.height, accuracy: 0.0001)
            }
        }
    }

    func testFillCoversTheCanvasAndOffsetsMoveTheCenter() {
        let source = CGSize(width: 160, height: 100)
        let canvas = OutputRatio.square.canvasSize
        let fill = PlacementGeometry.fillScale(source: source, canvas: canvas)
        XCTAssertEqual(fill, 1.6, accuracy: 0.0001)
        let covered = PlacementGeometry.imageRect(source: source, canvas: canvas, edit: PhotoEdit(scale: fill))
        XCTAssertLessThanOrEqual(covered.minX, 0.0001)
        XCTAssertLessThanOrEqual(covered.minY, 0.0001)
        XCTAssertGreaterThanOrEqual(covered.maxX, canvas.width - 0.0001)
        XCTAssertGreaterThanOrEqual(covered.maxY, canvas.height - 0.0001)
        let moved = PlacementGeometry.imageRect(source: source, canvas: canvas,
                                                edit: PhotoEdit(offsetX: 0.25, offsetY: -0.1))
        XCTAssertEqual(moved.midX, 540 + 270, accuracy: 0.0001)
        XCTAssertEqual(moved.midY, 540 - 108, accuracy: 0.0001)
    }

    func testColorBackgroundFillsTheMarginsAroundAFittedPhoto() throws {
        let input = try writePNG(width: 160, height: 100, color: CIColor(red: 1, green: 0, blue: 0))
        let output = freshURL()
        let edit = PhotoEdit(background: .color(RGBColor(red: 0, green: 0, blue: 1)))
        _ = try ImageRenderer().render(inputURL: input, outputURL: output, ratio: .square, edit: edit)
        let image = try XCTUnwrap(CIImage(contentsOf: output))
        // The photo is 1080 × 675 and centered, leaving margins above and below.
        assertPixel(image, at: CGPoint(x: 540, y: 60), red: 0, green: 0, blue: 1)
        assertPixel(image, at: CGPoint(x: 540, y: 1020), red: 0, green: 0, blue: 1)
        assertPixel(image, at: CGPoint(x: 540, y: 540), red: 1, green: 0, blue: 0)
    }

    func testFillLeavesNoBackgroundVisible() throws {
        let input = try writePNG(width: 160, height: 100, color: CIColor(red: 0, green: 1, blue: 0))
        let output = freshURL()
        let fill = PlacementGeometry.fillScale(source: CGSize(width: 160, height: 100),
                                               canvas: OutputRatio.fourFive.canvasSize)
        _ = try ImageRenderer().render(inputURL: input, outputURL: output, ratio: .fourFive,
                                       edit: PhotoEdit(scale: fill))
        let image = try XCTUnwrap(CIImage(contentsOf: output))
        for point in [CGPoint(x: 6, y: 6), CGPoint(x: 1073, y: 1343), CGPoint(x: 540, y: 675)] {
            assertPixel(image, at: point, red: 0, green: 1, blue: 0)
        }
    }

    func testBlurBackgroundIsMadeFromThePhotoItself() throws {
        let input = try writePNG(width: 160, height: 100, color: CIColor(red: 1, green: 0, blue: 0))
        let output = freshURL()
        let result = try ImageRenderer().render(inputURL: input, outputURL: output, ratio: .square,
                                                edit: PhotoEdit(background: .blur))
        XCTAssertEqual(result.width, 1080)
        XCTAssertEqual(result.height, 1080)
        let image = try XCTUnwrap(CIImage(contentsOf: output))
        assertPixel(image, at: CGPoint(x: 540, y: 40), red: 1, green: 0, blue: 0)
        assertPixel(image, at: CGPoint(x: 540, y: 1040), red: 1, green: 0, blue: 0)
    }

    func testProcessorRendersEachPhotoWithItsOwnEditInOrder() async throws {
        let recorder = EditRecorder()
        let processor = AppBatchProcessor(editRenderer: { _, output, _, edit in
            recorder.append(edit)
            try Data("synthetic".utf8).write(to: output)
        })
        let inputs = [directory.appendingPathComponent("1.png"), directory.appendingPathComponent("2.png")]
        let edits = [PhotoEdit(scale: 2), PhotoEdit(background: .blur)]
        let result = try await processor.process(inputs, edits: edits, ratio: .square,
                                                 outputDirectory: directory.appendingPathComponent("out", isDirectory: true))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(recorder.values, edits)
    }

    func testMismatchedEditCountFailsBeforeRendering() async {
        let processor = AppBatchProcessor(editRenderer: { _, _, _, _ in XCTFail("Nothing may render.") })
        do {
            _ = try await processor.process([directory.appendingPathComponent("1.png")], edits: [],
                                            ratio: .square, outputDirectory: directory)
            XCTFail("A missing edit must fail.")
        } catch {
            XCTAssertEqual(error as? AppBatchProcessingError, .invalidImageCount(0))
        }
    }

    func testBackgroundsSurviveEncodingForRememberedSettings() throws {
        for background in [CanvasBackground.blur, .color(RGBColor(hex: 0xF6C85F))] {
            let data = try JSONEncoder().encode(background)
            XCTAssertEqual(try JSONDecoder().decode(CanvasBackground.self, from: data), background)
        }
        XCTAssertEqual(RGBColor(hex: 0xF6C85F).hexString, "#F6C85F")
    }

    private func writePNG(width: Int, height: Int, color: CIColor) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try ImageTestFixture.pngData(width: width, height: height, color: color).write(to: url)
        return url
    }

    private func freshURL() -> URL {
        directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpeg")
    }

    /// Core Image coordinates: origin bottom-left.
    private func assertPixel(_ image: CIImage, at point: CGPoint, red: Double, green: Double, blue: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1),
                           format: .RGBA8, colorSpace: colorSpace)
        }
        for (actual, expected) in zip(pixel.prefix(3), [red, green, blue]) {
            XCTAssertEqual(Double(actual), expected * 255, accuracy: 30, file: file, line: line)
        }
    }
}

private final class EditRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PhotoEdit] = []

    var values: [PhotoEdit] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ edit: PhotoEdit) {
        lock.lock()
        recorded.append(edit)
        lock.unlock()
    }
}
