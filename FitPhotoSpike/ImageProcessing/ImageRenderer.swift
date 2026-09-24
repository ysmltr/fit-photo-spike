import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RenderResult: Sendable {
    let width: Int
    let height: Int
    /// Source dimensions after applying the file's EXIF orientation.
    let sourceWidth: Int
    let sourceHeight: Int
}

/// Synchronous, stateless worker. Call from a background task, one image at a
/// time. Never pass the original input URL as the rendered output URL.
struct ImageRenderer: Sendable {
    func render(inputURL: URL, outputURL: URL,
                maximumLongEdge: Int = 5120) throws -> RenderResult {
        try render(inputURL: inputURL, outputURL: outputURL) { width, height in
            try CanvasGeometry(sourceWidth: width, sourceHeight: height,
                               maximumLongEdge: maximumLongEdge)
        }
    }

    func render(inputURL: URL, outputURL: URL, ratio: OutputRatio) throws -> RenderResult {
        try render(inputURL: inputURL, outputURL: outputURL) { width, height in
            try CanvasGeometry(sourceWidth: width, sourceHeight: height, ratio: ratio)
        }
    }

    /// Both entry points share decoding, orientation, compositing and encoding.
    /// Only their sizing policy differs.
    private func render(inputURL: URL, outputURL: URL,
                        geometry makeGeometry: (Int, Int) throws -> CanvasGeometry) throws -> RenderResult {
        try autoreleasepool {
            try Task.checkCancellation()
            guard inputURL.resolvingSymlinksInPath().standardizedFileURL
                    != outputURL.resolvingSymlinksInPath().standardizedFileURL else {
                throw ImageRenderingError.sameInputAndOutput
            }
            let input = try readInput(url: inputURL)
            let geometry = try makeGeometry(input.width, input.height)
            let decodeLongEdge = max(1, Int(ceil(max(geometry.imageRect.width,
                                                     geometry.imageRect.height))))
            // Always make the thumbnail from the actual image rather than a
            // potentially small embedded preview. Decode only the useful size.
            // Apply the file's EXIF orientation exactly once below.
            let decodeOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: decodeLongEdge,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false
            ]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(
                input.source, 0, decodeOptions as CFDictionary
            ) else {
                throw ImageRenderingError.unreadableImage
            }
            try Task.checkCancellation()
            let oriented = CIImage(cgImage: decoded).oriented(forExifOrientation: input.orientation)
            let upright = oriented.transformed(by: CGAffineTransform(
                translationX: -oriented.extent.minX, y: -oriented.extent.minY
            ))
            // ImageIO can round the thumbnail by a pixel. Use one uniform
            // scale for its actual extent, fitting within the planned size.
            let fitScale = min(geometry.imageRect.width / upright.extent.width,
                               geometry.imageRect.height / upright.extent.height)
            let scaled = upright.transformed(by: CGAffineTransform(scaleX: fitScale, y: fitScale))
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(geometry.width) - scaled.extent.width) / 2,
                y: (CGFloat(geometry.height) - scaled.extent.height) / 2
            ))
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                .cropped(to: geometry.canvasRect)
            let canvas = centered.composited(over: white).cropped(to: geometry.canvasRect)
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw ImageRenderingError.renderFailed
            }
            let context = CIContext(options: [
                .workingColorSpace: sRGB,
                .outputColorSpace: sRGB,
                .cacheIntermediates: false
            ])
            defer { context.clearCaches() }
            // An explicit SDR sRGB output flattens transparent PNGs over white.
            // JPEG does not preserve alpha, HDR gain maps, depth, or RAW data.
            guard let rendered = context.createCGImage(canvas, from: geometry.canvasRect,
                                                       format: .RGBA8, colorSpace: sRGB,
                                                       deferred: false) else {
                throw ImageRenderingError.renderFailed
            }
            try Task.checkCancellation()
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else {
                throw ImageRenderingError.destinationFailed
            }
            var finished = false
            defer {
                if !finished { try? FileManager.default.removeItem(at: outputURL) }
            }
            // One JPEG encode; no intermediate JPEG round-trip. Do not copy
            // stale source orientation, dimensions, thumbnails, or GPS data.
            let outputProperties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.95,
                kCGImagePropertyOrientation: 1
            ]
            CGImageDestinationAddImage(destination, rendered, outputProperties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ImageRenderingError.destinationFailed
            }
            try Task.checkCancellation()
            finished = true
            return RenderResult(width: geometry.width, height: geometry.height,
                                sourceWidth: input.width, sourceHeight: input.height)
        }
    }

    private struct Input {
        let source: CGImageSource
        let width: Int
        let height: Int
        let orientation: Int32
    }

    private func readInput(url: URL) throws -> Input {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let sourceType = CGImageSourceGetType(source) else {
            throw ImageRenderingError.unreadableImage
        }
        let type = sourceType as String
        // Generic HEIF is a container designation, not proof of HEIC encoding.
        // The ImageIO-reported content type, not the filename extension, decides.
        guard [UTType.jpeg.identifier, UTType.heic.identifier, UTType.png.identifier]
            .contains(type) else {
            throw ImageRenderingError.unsupportedFormat
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ImageRenderingError.multipleImages
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [String: Any],
              let storedWidth = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let storedHeight = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              storedWidth.intValue > 0, storedHeight.intValue > 0 else {
            throw ImageRenderingError.invalidDimensions
        }
        // Reject even a single-frame APNG that advertises animation semantics.
        let fileProperties = CGImageSourceCopyProperties(source, nil) as? [String: Any]
        for metadata in [properties, fileProperties ?? [:]] {
            if let png = metadata[kCGImagePropertyPNGDictionary as String] as? [String: Any],
               png[kCGImagePropertyAPNGLoopCount as String] != nil
                || png[kCGImagePropertyAPNGDelayTime as String] != nil
                || png[kCGImagePropertyAPNGUnclampedDelayTime as String] != nil {
                throw ImageRenderingError.multipleImages
            }
        }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value
            ?? 1
        guard (1...8).contains(orientation) else {
            throw ImageRenderingError.invalidOrientation
        }
        let swapsAxes = (5...8).contains(orientation)
        return Input(source: source,
                     width: swapsAxes ? storedHeight.intValue : storedWidth.intValue,
                     height: swapsAxes ? storedWidth.intValue : storedHeight.intValue,
                     orientation: orientation)
    }
}
