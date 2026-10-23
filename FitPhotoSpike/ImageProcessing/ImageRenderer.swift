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
    /// Upper bound for one decode of a zoomed-in photo; Core Image enlarges
    /// beyond it. Fit never needs more than the canvas size.
    static let maximumDecodeLongEdge = 4096

    /// Places the photo as `edit` describes. The standard edit is the whole
    /// photo, centered, on white.
    func render(inputURL: URL, outputURL: URL, ratio: OutputRatio,
                edit: PhotoEdit = .standard) throws -> RenderResult {
        try autoreleasepool {
            try Task.checkCancellation()
            guard inputURL.resolvingSymlinksInPath().standardizedFileURL
                    != outputURL.resolvingSymlinksInPath().standardizedFileURL else {
                throw ImageRenderingError.sameInputAndOutput
            }
            let input = try readInput(url: inputURL)
            let geometry = try CanvasGeometry(sourceWidth: input.width, sourceHeight: input.height, ratio: ratio)
            let placed = PlacementGeometry.imageRect(
                source: CGSize(width: input.width, height: input.height),
                canvas: CGSize(width: geometry.width, height: geometry.height), edit: edit)
            guard placed.width.isFinite, placed.height.isFinite, placed.width > 0, placed.height > 0 else {
                throw ImageRenderingError.invalidDimensions
            }
            let decodeLongEdge = min(Self.maximumDecodeLongEdge,
                                     max(1, Int(ceil(max(placed.width, placed.height)))))
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
            let photoScale = min(placed.width / upright.extent.width,
                                 placed.height / upright.extent.height)
            let scaled = upright.transformed(by: CGAffineTransform(scaleX: photoScale, y: photoScale))
            // Core Image's origin is bottom-left; the placement's is top-left.
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: placed.midX - scaled.extent.width / 2,
                y: CGFloat(geometry.height) - placed.midY - scaled.extent.height / 2
            ))
            let canvas = positioned
                .composited(over: background(edit.background, photo: upright, canvas: geometry.canvasRect))
                .cropped(to: geometry.canvasRect)
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

    /// An opaque background; transparent photo regions show through to it.
    private func background(_ background: CanvasBackground, photo: CIImage, canvas: CGRect) -> CIImage {
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: canvas)
        switch background {
        case .color(let color):
            return CIImage(color: CIColor(red: CGFloat(color.red), green: CGFloat(color.green),
                                          blue: CGFloat(color.blue), alpha: 1)).cropped(to: canvas)
        case .blur:
            // Cover the canvas with the photo, then blur. Clamping before
            // scaling keeps the enlarged edges opaque.
            let cover = max(canvas.width / photo.extent.width, canvas.height / photo.extent.height)
            let coverRect = CGRect(x: 0, y: 0, width: photo.extent.width * cover,
                                   height: photo.extent.height * cover)
            let scaled = photo.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: cover, y: cover))
                .cropped(to: coverRect)
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: canvas.midX - coverRect.midX, y: canvas.midY - coverRect.midY))
            let sigma = Double(min(canvas.width, canvas.height) * CanvasBackground.blurFraction)
            return centered.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: canvas)
                .composited(over: white)
        }
    }

    /// The photo's upright pixel size if it passes the same format checks as
    /// `render` and a tiny decode. Used at import, so an unusable photo is
    /// skipped before any conversion starts.
    func renderableSize(inputURL: URL) -> CGSize? {
        autoreleasepool {
            guard let input = try? readInput(url: inputURL),
                  CGImageSourceCreateThumbnailAtIndex(input.source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 64
                  ] as CFDictionary) != nil else { return nil }
            return CGSize(width: input.width, height: input.height)
        }
    }

    func canRender(inputURL: URL) -> Bool { renderableSize(inputURL: inputURL) != nil }

    /// Still formats that iOS decodes. GIF stays unsupported because it is
    /// usually animated. The ImageIO-reported type decides, not the filename.
    private static func isSupportedStillType(_ identifier: String) -> Bool {
        let stillTypes = [UTType.jpeg, .heic, .heif, .png, .tiff, .bmp, .webP].map(\.identifier)
            + ["public.avif"]
        return stillTypes.contains(identifier)
            || UTType(identifier)?.conforms(to: .rawImage) == true
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
        // A file ImageIO reports but cannot decode still fails later as
        // unreadable; `canRender` catches that case at import time.
        guard Self.isSupportedStillType(sourceType as String) else {
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
