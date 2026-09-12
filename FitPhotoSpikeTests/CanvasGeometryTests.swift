import CoreGraphics
import XCTest
@testable import FitPhotoSpike

final class CanvasGeometryTests: XCTestCase {
    func testPortraitKeepsFullHeightAndAddsEqualSideBorders() throws {
        let geometry = try CanvasGeometry(sourceWidth: 60, sourceHeight: 100)
        XCTAssertEqual(geometry.width, 80)
        XCTAssertEqual(geometry.height, 100)
        XCTAssertEqual(geometry.scale, 1)
        XCTAssertEqual(geometry.imageRect, CGRect(x: 10, y: 0, width: 60, height: 100))
    }

    func testSquareKeepsFullWidthAndAddsEqualTopAndBottomBorders() throws {
        let geometry = try CanvasGeometry(sourceWidth: 100, sourceHeight: 100)
        XCTAssertEqual(geometry.width, 100)
        XCTAssertEqual(geometry.height, 125)
        XCTAssertEqual(geometry.scale, 1)
        XCTAssertEqual(geometry.imageRect, CGRect(x: 0, y: 12.5, width: 100, height: 100))
    }

    func testLandscapeHasFullWidthAndCenteredWhiteBands() throws {
        let geometry = try CanvasGeometry(sourceWidth: 4032, sourceHeight: 3024)
        XCTAssertEqual(geometry.width, 4032)
        XCTAssertEqual(geometry.height, 5040)
        XCTAssertEqual(geometry.scale, 1)
        XCTAssertEqual(geometry.imageRect, CGRect(x: 0, y: 1008, width: 4032, height: 3024))
    }

    func testTallScreenshotHasFullHeightAndSideBorders() throws {
        let geometry = try CanvasGeometry(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertEqual(geometry.width, 2028)
        XCTAssertEqual(geometry.height, 2535)
        XCTAssertEqual(geometry.imageRect, CGRect(x: 429, y: 1.5, width: 1170, height: 2532))
    }

    func testSmallSourceIsNotUpscaledToFillRoundedCanvas() throws {
        let geometry = try CanvasGeometry(sourceWidth: 101, sourceHeight: 77)
        XCTAssertEqual(geometry.width, 104)
        XCTAssertEqual(geometry.height, 130)
        XCTAssertEqual(geometry.scale, 1)
        XCTAssertEqual(geometry.imageRect.width, 101)
        XCTAssertEqual(geometry.imageRect.height, 77)
    }

    func testFortyEightMegapixelSourceUsesBoundedCanvas() throws {
        let geometry = try CanvasGeometry(sourceWidth: 8064, sourceHeight: 6048)
        XCTAssertEqual(geometry.width, 4096)
        XCTAssertEqual(geometry.height, 5120)
        XCTAssertEqual(geometry.imageRect.width, 4096, accuracy: 0.0001)
        XCTAssertEqual(geometry.imageRect.height, 3072, accuracy: 0.0001)
        XCTAssertEqual(geometry.imageRect.midX, 2048, accuracy: 0.0001)
        XCTAssertEqual(geometry.imageRect.midY, 2560, accuracy: 0.0001)
    }

    func testExactRatioAndFitAcrossDifferentSourceShapes() throws {
        for (width, height) in [(1, 1), (400, 500), (500, 400), (8000, 1000),
                                (1000, 8000), (3024, 4032), (8064, 6048)] {
            let geometry = try CanvasGeometry(sourceWidth: width, sourceHeight: height)
            XCTAssertEqual(geometry.width * 5, geometry.height * 4)
            XCTAssertLessThanOrEqual(geometry.height, 5120)
            XCTAssertLessThanOrEqual(geometry.scale, 1)
            XCTAssertGreaterThan(geometry.scale, 0)
            XCTAssertGreaterThanOrEqual(geometry.imageRect.minX, -0.0001)
            XCTAssertGreaterThanOrEqual(geometry.imageRect.minY, -0.0001)
            XCTAssertLessThanOrEqual(geometry.imageRect.maxX, CGFloat(geometry.width) + 0.0001)
            XCTAssertLessThanOrEqual(geometry.imageRect.maxY, CGFloat(geometry.height) + 0.0001)
            XCTAssertEqual(geometry.imageRect.width / geometry.imageRect.height,
                           CGFloat(width) / CGFloat(height), accuracy: 0.0001)
        }
    }

    func testCapRoundsDownToFivePixelMultipleAndCannotExceedSafetyLimit() throws {
        let small = try CanvasGeometry(sourceWidth: 6000, sourceHeight: 3000,
                                       maximumLongEdge: 1003)
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 1000)
        let oversized = try CanvasGeometry(sourceWidth: 6000, sourceHeight: 3000,
                                           maximumLongEdge: 9999)
        XCTAssertEqual(oversized.height, 5120)
    }

    func testInvalidDimensionsFail() {
        XCTAssertThrowsError(try CanvasGeometry(sourceWidth: 0, sourceHeight: 100))
        XCTAssertThrowsError(try CanvasGeometry(sourceWidth: 100, sourceHeight: -1))
        XCTAssertThrowsError(try CanvasGeometry(sourceWidth: 100, sourceHeight: 100,
                                                maximumLongEdge: 4))
    }
}
