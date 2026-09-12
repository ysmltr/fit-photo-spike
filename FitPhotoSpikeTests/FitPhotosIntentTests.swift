import AppIntents
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FitPhotoSpike

/// Calls perform() directly. This does not exercise Shortcuts transport,
/// system-managed file removal, or AppIntentsTesting's out-of-process runtime.
final class FitPhotosIntentTests: XCTestCase {
    func testIntentReturnsMultipleReadableJPEGFilesForTheNextAction() async throws {
        let inputs = try [(60, 100), (160, 100), (100, 100)].map { width, height in
            IntentFile(data: try ImageTestFixture.pngData(width: width, height: height),
                       filename: "fixture.png", type: .png)
        }
        let result = try await FitPhotosIntent(photos: inputs).perform()
        let outputs = try XCTUnwrap(result.value)
        defer {
            // This test is the consumer. Real workflows leave this cleanup
            // to Shortcuts via removedOnCompletion, which needs device testing.
            for output in outputs {
                if let url = output.fileURL { try? FileManager.default.removeItem(at: url) }
            }
        }
        XCTAssertEqual(outputs.count, 3)
        for output in outputs {
            XCTAssertEqual(output.type, .jpeg)
            XCTAssertTrue(output.removedOnCompletion)
            XCTAssertTrue(output.filename.hasSuffix(".jpeg"))
            let url = try XCTUnwrap(output.fileURL)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let encodedType = try XCTUnwrap(CGImageSourceGetType(source))
            XCTAssertEqual(encodedType as String, UTType.jpeg.identifier)
            let properties = try ImageTestFixture.properties(at: url)
            let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue)
            let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue)
            XCTAssertEqual(width * 5, height * 4)
        }
    }

    func testIntentRejectsAnEmptyBatch() async throws {
        do {
            _ = try await FitPhotosIntent(photos: []).perform()
            XCTFail("The intent must reject empty input.")
        } catch {
            XCTAssertEqual(error as? TemporaryImageProcessingError, .invalidImageCount(0))
        }
    }

    func testIntentRejectsMoreThanTwentyImages() async throws {
        let input = IntentFile(data: Data(), filename: "not-read.png", type: .png)
        do {
            _ = try await FitPhotosIntent(photos: Array(repeating: input, count: 21)).perform()
            XCTFail("The intent must reject oversized input before rendering.")
        } catch {
            XCTAssertEqual(error as? TemporaryImageProcessingError, .invalidImageCount(21))
        }
    }
}
