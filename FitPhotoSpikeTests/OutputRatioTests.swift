import CoreGraphics
import XCTest
@testable import FitPhotoSpike

final class OutputRatioTests: XCTestCase {
    func testAllFourChoicesHaveTheSpecifiedDimensionsAndDistinctIdentities() {
        let expected: [(OutputRatio, String, Int, Int)] = [
            (.fourFive, "4:5", 1080, 1350), (.threeFour, "3:4", 1080, 1440),
            (.nineSixteen, "9:16", 1080, 1920), (.square, "1:1", 1080, 1080)
        ]
        XCTAssertEqual(OutputRatio.allCases, expected.map { $0.0 })
        XCTAssertEqual(Set(OutputRatio.allCases.map(\.id)).count, 4)
        for (ratio, title, width, height) in expected {
            XCTAssertEqual(ratio.title, title)
            XCTAssertEqual(ratio.width, width)
            XCTAssertEqual(ratio.height, height)
            XCTAssertFalse(ratio.label.isEmpty)
        }
    }

    func testAllSourceShapesAreCenteredAndFullyContainedWithoutStretching() throws {
        for ratio in OutputRatio.allCases {
            for (width, height) in [(1, 1), (60, 100), (160, 100), (100, 100),
                                    (30, 240), (8064, 6048), (6048, 8064)] {
                let geometry = try CanvasGeometry(sourceWidth: width, sourceHeight: height, ratio: ratio)
                XCTAssertEqual(geometry.width, ratio.width)
                XCTAssertEqual(geometry.height, ratio.height)
                XCTAssertEqual(geometry.imageRect.width / geometry.imageRect.height,
                               CGFloat(width) / CGFloat(height), accuracy: 0.000001)
                XCTAssertEqual(geometry.imageRect.midX, CGFloat(ratio.width) / 2, accuracy: 0.000001)
                XCTAssertEqual(geometry.imageRect.midY, CGFloat(ratio.height) / 2, accuracy: 0.000001)
                XCTAssertGreaterThanOrEqual(geometry.imageRect.minX, -0.000001)
                XCTAssertGreaterThanOrEqual(geometry.imageRect.minY, -0.000001)
                XCTAssertLessThanOrEqual(geometry.imageRect.maxX, CGFloat(ratio.width) + 0.000001)
                XCTAssertLessThanOrEqual(geometry.imageRect.maxY, CGFloat(ratio.height) + 0.000001)
                XCTAssertTrue(abs(geometry.imageRect.width - CGFloat(ratio.width)) < 0.000001
                    || abs(geometry.imageRect.height - CGFloat(ratio.height)) < 0.000001)
            }
        }
    }

    func testInvalidSourcesAreRejectedForEveryRatio() {
        for ratio in OutputRatio.allCases {
            XCTAssertThrowsError(try CanvasGeometry(sourceWidth: 0, sourceHeight: 10, ratio: ratio))
            XCTAssertThrowsError(try CanvasGeometry(sourceWidth: 10, sourceHeight: -1, ratio: ratio))
        }
    }
}
