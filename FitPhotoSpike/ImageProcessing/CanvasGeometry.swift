import CoreGraphics
import Foundation

/// Integer canvas dimensions are always exactly 4n × 5n. Coordinates use a
/// bottom-left origin, matching Core Image.
struct CanvasGeometry: Sendable {
    let width: Int
    let height: Int
    let scale: CGFloat
    let imageRect: CGRect

    init(sourceWidth: Int, sourceHeight: Int, maximumLongEdge: Int = 5120) throws {
        guard sourceWidth > 0, sourceHeight > 0, maximumLongEdge >= 5 else {
            throw ImageRenderingError.invalidDimensions
        }
        // Integer ceiling division avoids rounding the ratio or overflowing
        // when adding to an untrusted source dimension.
        let columns = sourceWidth / 4 + (sourceWidth % 4 == 0 ? 0 : 1)
        let rows = sourceHeight / 5 + (sourceHeight % 5 == 0 ? 0 : 1)
        let n = min(max(columns, rows), min(maximumLongEdge, 5120) / 5)
        width = 4 * n
        height = 5 * n
        scale = min(1, min(CGFloat(width) / CGFloat(sourceWidth),
                           CGFloat(height) / CGFloat(sourceHeight)))
        let fittedWidth = CGFloat(sourceWidth) * scale
        let fittedHeight = CGFloat(sourceHeight) * scale
        imageRect = CGRect(x: (CGFloat(width) - fittedWidth) / 2,
                           y: (CGFloat(height) - fittedHeight) / 2,
                           width: fittedWidth, height: fittedHeight)
    }

    var canvasRect: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }
}

enum ImageRenderingError: LocalizedError, Sendable {
    case unreadableImage
    case unsupportedFormat
    case multipleImages
    case invalidDimensions
    case invalidOrientation
    case renderFailed
    case destinationFailed
    case sameInputAndOutput

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The photo could not be read."
        case .unsupportedFormat: return "Choose JPEG, HEIC, or PNG still images."
        case .multipleImages: return "Animated and multiple-frame image files are not supported."
        case .invalidDimensions: return "The photo dimensions or output size are invalid."
        case .invalidOrientation: return "The photo contains an unsupported orientation value."
        case .renderFailed: return "The 4:5 photo could not be rendered."
        case .destinationFailed: return "The temporary JPEG could not be written. Check available storage and try again."
        case .sameInputAndOutput: return "The rendered file must be separate from its source."
        }
    }
}
