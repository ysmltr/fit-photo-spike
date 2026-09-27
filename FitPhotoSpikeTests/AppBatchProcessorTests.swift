import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FitPhotoSpike

final class AppBatchProcessorTests: XCTestCase {
    private var directory: URL!
    private var outputs: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitPhotosAppBatchTests-\(UUID().uuidString)", isDirectory: true)
        outputs = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testSingleImageProducesReadableJPEGAndKeepsSourceBytes() async throws {
        let input = directory.appendingPathComponent("original.png")
        let bytes = try ImageTestFixture.pngData()
        try bytes.write(to: input)
        let result = try await AppBatchProcessor().process([input], ratio: .threeFour, outputDirectory: outputs)
        let output = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(output.deletingLastPathComponent().standardizedFileURL, outputs.standardizedFileURL)
        XCTAssertNotNil(output.lastPathComponent.range(
            of: #"^fit-3x4-01-[0-9A-Fa-f-]{36}\.jpeg$"#, options: .regularExpression))
        XCTAssertNotEqual(input, output)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source)! as String, UTType.jpeg.identifier)
        let properties = try ImageTestFixture.properties(at: output)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, 1080)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, 1440)
        // Success files survive return so the app can preview, share or save.
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testMultipleImagesPreserveSelectionOrderAndReportOrderedProgress() async throws {
        let colors = [CIColor(red: 1, green: 0, blue: 0), CIColor(red: 0, green: 1, blue: 0),
                      CIColor(red: 0, green: 0, blue: 1)]
        let inputs = try colors.enumerated().map { index, color in
            let input = directory.appendingPathComponent("\(index).png")
            try ImageTestFixture.pngData(color: color).write(to: input)
            return input
        }
        let progress = BatchProgressRecorder()
        let result = try await AppBatchProcessor().process(inputs, ratio: .square, outputDirectory: outputs) { done, total in
            progress.append(done, total)
        }
        XCTAssertEqual(result.count, colors.count)
        for (output, color) in zip(result, colors) {
            try ImageTestFixture.assertCenterPixel(at: output, equals: color)
        }
        XCTAssertEqual(progress.completed, [0, 1, 2, 3])
        XCTAssertEqual(progress.totals, [3, 3, 3, 3])
    }

    func testTwentyImagesAreAcceptedAndWorkIsSequentialOffTheMainThread() async throws {
        let inputs = (1...20).map { directory.appendingPathComponent("\($0).png") }
        let calls = BatchProgressRecorder()
        let processor = AppBatchProcessor { input, output, ratio in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(ratio, .nineSixteen)
            let index = Int(input.deletingPathExtension().lastPathComponent)!
            XCTAssertEqual(calls.completed.count, index - 1)
            calls.append(index, 20)
            try Data("synthetic render \(index)".utf8).write(to: output)
        }
        let result = try await processor.process(inputs, ratio: .nineSixteen, outputDirectory: outputs)
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(Set(result).count, 20)
        XCTAssertEqual(calls.completed, Array(1...20))
        for (index, output) in result.enumerated() {
            XCTAssertEqual(try Data(contentsOf: output), Data("synthetic render \(index + 1)".utf8))
        }
    }

    func testEmptyAndTwentyOneInputsFailBeforeRenderingOrCreatingFiles() async throws {
        let processor = AppBatchProcessor { _, _, _ in XCTFail("Count validation must run first.") }
        for count in [0, 21] {
            do {
                _ = try await processor.process(Array(repeating: directory.appendingPathComponent("absent.png"), count: count),
                                                ratio: .fourFive, outputDirectory: outputs)
                XCTFail("Invalid count must fail.")
            } catch {
                XCTAssertEqual(error as? AppBatchProcessingError, .invalidImageCount(count))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputs.path))
        }
    }

    func testRemoteInputAndRemoteOutputAreRejectedWithoutRendering() async throws {
        let processor = AppBatchProcessor { _, _, _ in XCTFail("Remote URLs must not reach rendering.") }
        let local = directory.appendingPathComponent("local.png")
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/synthetic.png"))
        do {
            _ = try await processor.process([local, remote], ratio: .fourFive, outputDirectory: outputs)
            XCTFail("Remote input must fail.")
        } catch {
            XCTAssertEqual(error as? AppBatchProcessingError, .nonLocalInput(index: 2, total: 2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputs.path))
        do {
            _ = try await processor.process([local], ratio: .fourFive, outputDirectory: remote)
            XCTFail("Remote output must fail.")
        } catch {
            XCTAssertEqual(error as? AppBatchProcessingError, .outputUnavailable)
        }
    }

    func testUnreadableSecondImageFailsEntireBatchAndPreservesInputsAndUnrelatedFiles() async throws {
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        // Source files deliberately share the output folder: cleanup may only
        // remove paths generated by this invocation, never the whole folder.
        let first = outputs.appendingPathComponent("source.png")
        let firstBytes = try ImageTestFixture.pngData()
        try firstBytes.write(to: first)
        let second = outputs.appendingPathComponent("unsupported.png")
        let secondBytes = Data("synthetic invalid image".utf8)
        try secondBytes.write(to: second)
        let sentinel = outputs.appendingPathComponent("previous-result.jpeg")
        let sentinelBytes = Data("unrelated session".utf8)
        try sentinelBytes.write(to: sentinel)
        do {
            _ = try await AppBatchProcessor().process([first, second], ratio: .fourFive, outputDirectory: outputs)
            XCTFail("An unreadable image must not be silently skipped.")
        } catch {
            XCTAssertEqual(error as? AppBatchProcessingError,
                           .itemFailed(index: 2, total: 2, reason: .unreadable))
            XCTAssertTrue(error.localizedDescription.contains("Photo 2 of 2"))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: outputs.path)),
                       Set([first.lastPathComponent, second.lastPathComponent, sentinel.lastPathComponent]))
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
    }

    func testUnsupportedInputGetsAnIndexedMessageAndPartialOutputIsRemoved() async throws {
        let processor = AppBatchProcessor { _, output, _ in
            try Data("partial".utf8).write(to: output)
            throw ImageRenderingError.unsupportedFormat
        }
        do {
            _ = try await processor.process([directory.appendingPathComponent("synthetic.gif")],
                                            ratio: .square, outputDirectory: outputs)
            XCTFail("Unsupported input must fail.")
        } catch {
            XCTAssertEqual(error as? AppBatchProcessingError,
                           .itemFailed(index: 1, total: 1, reason: .unsupported))
            XCTAssertTrue(error.localizedDescription.contains("JPEG, HEIC, or PNG"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputs.path), [])
    }

    func testArbitraryRendererErrorsCannotExposeTheirPathOrErrorDetails() async throws {
        let processor = AppBatchProcessor { _, _, _ in
            throw NSError(domain: "SYNTHETIC_PRIVATE_DETAIL", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "SYNTHETIC_PRIVATE_PATH"
            ])
        }
        do {
            _ = try await processor.process([directory.appendingPathComponent("synthetic.png")],
                                            ratio: .fourFive, outputDirectory: outputs)
            XCTFail("Injected failure must fail the batch.")
        } catch {
            XCTAssertEqual(error as? AppBatchProcessingError,
                           .itemFailed(index: 1, total: 1, reason: .conversion))
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_PRIVATE"))
        }
    }

    func testCallerCancellationRemovesCompletedAndPartialOutputsAndStopsTheBatch() async throws {
        let started = expectation(description: "Renderer wrote an output")
        let gate = DispatchSemaphore(value: 0)
        let calls = BatchProgressRecorder()
        let input = directory.appendingPathComponent("source.png")
        let sourceBytes = Data("synthetic source".utf8)
        try sourceBytes.write(to: input)
        let processor = AppBatchProcessor { _, output, _ in
            calls.append(1, 2)
            try Data("partial output".utf8).write(to: output)
            started.fulfill()
            guard gate.wait(timeout: .now() + 5) == .success else {
                throw AppBatchTestError.timedOut
            }
        }
        let target = outputs!
        let task = Task { try await processor.process([input, input], ratio: .square, outputDirectory: target) }
        defer { task.cancel(); gate.signal() }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        gate.signal()
        do {
            _ = try await task.value
            XCTFail("Caller cancellation must propagate.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(calls.completed.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputs.path), [])
        XCTAssertEqual(try Data(contentsOf: input), sourceBytes)
    }

    func testCancelledCallerDoesNotCreateOutputs() async throws {
        let processor = AppBatchProcessor { _, _, _ in XCTFail("Cancelled work must not render.") }
        let input = directory.appendingPathComponent("unused.png")
        let target = outputs!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await processor.process([input], ratio: .square, outputDirectory: target)
        }
        do {
            _ = try await task.value
            XCTFail("An already-cancelled task must fail.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputs.path))
    }

    @MainActor
    func testMainActorProgressIsDeliveredInOrderBeforeProcessReturns() async throws {
        let target = try XCTUnwrap(outputs)
        let input = try XCTUnwrap(directory).appendingPathComponent("synthetic.png")
        let processor = AppBatchProcessor { _, output, _ in
            XCTAssertFalse(Thread.isMainThread)
            try Data([1]).write(to: output)
        }
        var progress: [Int] = []
        let results = try await processor.process([input, input], ratio: .fourFive, outputDirectory: target) {
            @MainActor done, _ in
            XCTAssertTrue(Thread.isMainThread)
            progress.append(done)
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(progress, [0, 1, 2])
    }

    func testCancellationDuringFinalProgressRemovesFinishedOutputs() async throws {
        let input = try XCTUnwrap(directory).appendingPathComponent("synthetic.png")
        let target = try XCTUnwrap(outputs)
        let processor = AppBatchProcessor { _, output, _ in
            try Data([1]).write(to: output)
        }
        do {
            _ = try await processor.process([input], ratio: .square, outputDirectory: target) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            XCTFail("A cancelled child must not return successful files.")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testSeparateRunsKeepEarlierSuccessfulOutputsReadable() async throws {
        let input = directory.appendingPathComponent("original.png")
        try ImageTestFixture.pngData().write(to: input)
        let first = try await AppBatchProcessor().process([input], ratio: .fourFive, outputDirectory: outputs)
        let firstURL = try XCTUnwrap(first.first)
        let bytes = try Data(contentsOf: firstURL)
        let second = try await AppBatchProcessor().process([input], ratio: .fourFive, outputDirectory: outputs)
        XCTAssertNotEqual(firstURL, second.first)
        XCTAssertEqual(try Data(contentsOf: firstURL), bytes)
    }
}

private enum AppBatchTestError: Error { case timedOut }

private final class BatchProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []

    var completed: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values.map { $0.0 }
    }

    var totals: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values.map { $0.1 }
    }

    func append(_ completed: Int, _ total: Int) {
        lock.lock()
        defer { lock.unlock() }
        values.append((completed, total))
    }
}
