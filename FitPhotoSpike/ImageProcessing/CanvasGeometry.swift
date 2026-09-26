import CoreGraphics
import Foundation

/// Centered aspect-fit geometry in Core Image's bottom-left coordinates.
struct CanvasGeometry: Sendable {
    let width: Int
    let height: Int
    let scale: CGFloat
    let imageRect: CGRect

    /// App outputs have fixed pixel dimensions. Small sources may be enlarged
    /// proportionally; neither axis is independently stretched or cropped.
    init(sourceWidth: Int, sourceHeight: Int, ratio: OutputRatio) throws {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw ImageRenderingError.invalidDimensions
        }
        width = ratio.width
        height = ratio.height
        scale = min(CGFloat(width) / CGFloat(sourceWidth),
                    CGFloat(height) / CGFloat(sourceHeight))
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
        case .renderFailed: return "The photo could not be rendered."
        case .destinationFailed: return "The temporary JPEG could not be written. Check available storage and try again."
        case .sameInputAndOutput: return "The rendered file must be separate from its source."
        }
    }
}
