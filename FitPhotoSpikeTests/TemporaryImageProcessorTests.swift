import AppIntents
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FitPhotoSpike

/// File-lifecycle and batch-contract tests. Synthetic fixtures do not require
/// Photos access; these tests still require Apple's frameworks and Xcode.
final class TemporaryImageProcessorTests: XCTestCase {
    private var testDirectory: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitPhotosProcessorTests-\(UUID().uuidString)", isDirectory: true)
        outputDirectory = testDirectory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testDirectory {
            try FileManager.default.removeItem(at: testDirectory)
        }
    }

    func testMultipleImagesKeepTheirInputOrderAndBecomeFourByFive() async throws {
        let colors = [CIColor(red: 1, green: 0, blue: 0),
                      CIColor(red: 0, green: 1, blue: 0),
                      CIColor(red: 0, green: 0, blue: 1)]
        let inputs = try colors.map { color in
            IntentFile(data: try ImageTestFixture.pngData(color: color),
                       filename: "same-name.png", type: .png)
        }
        let outputs = try await TemporaryImageProcessor(outputDirectory: outputDirectory).process(inputs)
        XCTAssertEqual(outputs.count, colors.count)
        for (output, color) in zip(outputs, colors) {
            let url = try XCTUnwrap(output.fileURL)
            let properties = try ImageTestFixture.properties(at: url)
            let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue)
            let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue)
            XCTAssertEqual(width * 5, height * 4)
            try ImageTestFixture.assertCenterPixel(at: url, equals: color)
        }
    }

    func testTwentyImagesAreAccepted() async throws {
        let input = IntentFile(data: try ImageTestFixture.pngData(width: 8, height: 8),
                               filename: "small.png", type: .png)
        let outputs = try await TemporaryImageProcessor(outputDirectory: outputDirectory)
            .process(Array(repeating: input, count: 20))
        XCTAssertEqual(outputs.count, 20)
        let urls = try outputs.map { try XCTUnwrap($0.fileURL) }
        XCTAssertEqual(Set(urls).count, 20)
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testEmptyInputFailsBeforeCreatingOutputDirectory() async throws {
        do {
            _ = try await TemporaryImageProcessor(outputDirectory: outputDirectory).process([])
            XCTFail("An empty batch must fail.")
        } catch {
            XCTAssertEqual(error as? TemporaryImageProcessingError, .invalidImageCount(0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testTwentyOneImagesFailBeforeCreatingOutputDirectory() async throws {
        // Invalid bytes are intentional: count validation must happen before
        // attempting to read or render any individual image.
        let input = IntentFile(data: Data(), filename: "not-read.png", type: .png)
        do {
            _ = try await TemporaryImageProcessor(outputDirectory: outputDirectory)
                .process(Array(repeating: input, count: 21))
            XCTFail("More than 20 images must fail.")
        } catch {
            XCTAssertEqual(error as? TemporaryImageProcessingError, .invalidImageCount(21))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testOutputsHaveJPEGNamesTypesAndCompletionCleanupFlagAndRemainReadable() async throws {
        let input = IntentFile(data: try ImageTestFixture.pngData(),
                               filename: "../../an input with an odd name.png", type: .png)
        let outputs = try await TemporaryImageProcessor(outputDirectory: outputDirectory).process([input])
        let output = try XCTUnwrap(outputs.first)
        let url = try XCTUnwrap(output.fileURL)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       outputDirectory.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, output.filename)
        XCTAssertNotNil(output.filename.range(
            of: #"^fit-4x5-01-[0-9A-Fa-f-]{36}\.jpeg$"#, options: .regularExpression))
        XCTAssertEqual(output.type, .jpeg)
        XCTAssertTrue(output.removedOnCompletion)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let encodedType = try XCTUnwrap(CGImageSourceGetType(source))
        XCTAssertEqual(encodedType as String, UTType.jpeg.identifier)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
        // The processor must not delete successful outputs before Shortcuts
        // consumes them. System cleanup after a live workflow is a device test.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileInputRemainsUnchangedAndIsNeverUsedAsTheOutput() async throws {
        let inputURL = testDirectory.appendingPathComponent("original.png")
        let bytes = try ImageTestFixture.pngData(width: 80, height: 100)
        try bytes.write(to: inputURL)
        let input = IntentFile(fileURL: inputURL, filename: "original.png", type: .png)
        let outputs = try await TemporaryImageProcessor(outputDirectory: outputDirectory).process([input])
        let outputURL = try XCTUnwrap(outputs.first?.fileURL)
        XCTAssertNotEqual(outputURL.standardizedFileURL, inputURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: inputURL), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testFailureRemovesCompletedAndPartialOutputsButKeepsPreexistingFiles() async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sentinel = outputDirectory.appendingPathComponent("another-workflow.jpeg")
        let sentinelBytes = Data("leave another workflow alone".utf8)
        try sentinelBytes.write(to: sentinel)
        let calls = LockedURLRecorder()
        let processor = TemporaryImageProcessor(outputDirectory: outputDirectory) { inputURL, outputURL in
            let invocation = calls.append(inputURL)
            // This injected worker deliberately fails after writing part of
            // the second output. File ownership, not image encoding, is tested.
            try Data("partial render".utf8).write(to: outputURL)
            if invocation == 2 { throw InjectedRenderError.failed }
        }
        let input = IntentFile(data: Data("fixture".utf8), filename: "input.png", type: .png)
        do {
            _ = try await processor.process(Array(repeating: input, count: 3))
            XCTFail("The injected failure must be propagated.")
        } catch {
            XCTAssertTrue(error is InjectedRenderError)
        }
        XCTAssertEqual(calls.urls.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path),
                       [sentinel.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertTrue(calls.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testParentCancellationPropagatesAndRemovesPartialOutputs() async throws {
        let renderStarted = expectation(description: "First renderer has written its output")
        let allowRenderToFinish = DispatchSemaphore(value: 0)
        let calls = LockedURLRecorder()
        let processor = TemporaryImageProcessor(outputDirectory: outputDirectory) { inputURL, outputURL in
            _ = calls.append(inputURL)
            try Data("partial render".utf8).write(to: outputURL)
            renderStarted.fulfill()
            guard allowRenderToFinish.wait(timeout: .now() + 5) == .success else {
                throw InjectedRenderError.timedOut
            }
        }
        let input = IntentFile(data: Data("fixture".utf8), filename: "input.png", type: .png)
        let task = Task { try await processor.process([input, input]) }
        defer { task.cancel(); allowRenderToFinish.signal() }
        await fulfillment(of: [renderStarted], timeout: 5)
        task.cancel()
        allowRenderToFinish.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelling the caller must cancel the processor.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Received \(error)")
        }
        XCTAssertEqual(calls.urls.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path), [])
        XCTAssertTrue(calls.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testDataInputsAreStagedOnlyWhileRenderingAndProcessedSequentially() async throws {
        let inputBytes = Data("synthetic input for lifecycle check".utf8)
        let calls = LockedURLRecorder()
        let processor = TemporaryImageProcessor(outputDirectory: outputDirectory) { inputURL, outputURL in
            // The previous data-backed input must have been released before
            // the next input is staged. This catches unbounded input staging.
            for priorURL in calls.urls {
                XCTAssertFalse(FileManager.default.fileExists(atPath: priorURL.path))
            }
            XCTAssertEqual(try Data(contentsOf: inputURL), inputBytes)
            _ = calls.append(inputURL)
            try Data("output".utf8).write(to: outputURL)
        }
        let input = IntentFile(data: inputBytes, filename: "source.png", type: .png)
        let outputs = try await processor.process([input, input, input])
        XCTAssertEqual(outputs.count, 3)
        XCTAssertEqual(calls.urls.count, 3)
        XCTAssertTrue(calls.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let outputURLs = try outputs.map { try XCTUnwrap($0.fileURL) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)),
                       Set(outputURLs.map(\.lastPathComponent)))
    }

    func testSeparateInvocationsProduceDistinctFilesWithoutDeletingEarlierOutputs() async throws {
        let processor = TemporaryImageProcessor(outputDirectory: outputDirectory)
        let input = IntentFile(data: try ImageTestFixture.pngData(), filename: "same.png", type: .png)
        let first = try await processor.process([input])
        let firstURL = try XCTUnwrap(first.first?.fileURL)
        let firstBytes = try Data(contentsOf: firstURL)
        let second = try await processor.process([input])
        let secondURL = try XCTUnwrap(second.first?.fileURL)
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }
}

private enum InjectedRenderError: Error { case failed, timedOut }

private final class LockedURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func append(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.append(url)
        return storage.count
    }
}

/// Shared by the processor and intent integration tests in this test bundle.
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
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: floor(image.extent.midX), y: floor(image.extent.midY),
                                          width: 1, height: 1),
                           format: .RGBA8, colorSpace: colorSpace)
        }
        for (channel, expected) in zip(pixel.prefix(3), [color.red, color.green, color.blue]) {
            XCTAssertEqual(Double(channel), Double(expected) * 255, accuracy: 30, file: file, line: line)
        }
    }
}
