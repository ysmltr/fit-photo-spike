import CoreGraphics
import ImageIO
import SwiftUI
import UIKit

/// Display-size decodes for the editor canvas. Only the current photo and its
/// neighbors stay in memory; the export decodes from the files again.
@MainActor
final class EditorImageStore: ObservableObject {
    @Published private(set) var images: [URL: UIImage] = [:]
    private var loading: Set<URL> = []
    private var wanted: [URL] = []

    static let maximumPixelSize = 1600

    func image(for url: URL) -> UIImage? { images[url] }

    func prepare(around index: Int, in urls: [URL]) {
        wanted = [index, index + 1, index - 1, index + 2]
            .filter { urls.indices.contains($0) }
            .map { urls[$0] }
        let kept = images.filter { wanted.contains($0.key) }
        if kept.count != images.count { images = kept }
        for url in wanted where images[url] == nil && !loading.contains(url) {
            load(url)
        }
    }

    private func load(_ url: URL) {
        loading.insert(url)
        let size = EditorImageStore.maximumPixelSize
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                EditorImageStore.decode(url, maximumPixelSize: size)
            }.value
            guard let self else { return }
            self.loading.remove(url)
            if let decoded, self.wanted.contains(url) {
                self.images[url] = UIImage(cgImage: decoded)
            }
        }
    }

    nonisolated static func decode(_ url: URL, maximumPixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                      [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
    }
}

/// Reads colors for the eyedropper from a small copy of the photo, drawn once
/// into an sRGB buffer.
struct PixelSampler {
    private static let maximumSide = 512
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int

    init?(image: CGImage) {
        let longest = max(image.width, image.height)
        guard longest > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, CGFloat(PixelSampler.maximumSide) / CGFloat(longest))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.pixels = buffer
        self.width = width
        self.height = height
    }

    /// The average color of a 3 × 3 patch at a point in 0...1 photo
    /// coordinates, origin top-left.
    func color(atUnitX unitX: CGFloat, y unitY: CGFloat) -> RGBColor {
        let centerX = min(max(Int(unitX * CGFloat(width)), 0), width - 1)
        let centerY = min(max(Int(unitY * CGFloat(height)), 0), height - 1)
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for y in max(centerY - 1, 0)...min(centerY + 1, height - 1) {
            for x in max(centerX - 1, 0)...min(centerX + 1, width - 1) {
                let index = (y * width + x) * 4
                // Premultiplied values: summing them and dividing by the
                // total alpha gives the alpha-weighted average color.
                red += Double(pixels[index]) / 255
                green += Double(pixels[index + 1]) / 255
                blue += Double(pixels[index + 2]) / 255
                weight += Double(pixels[index + 3]) / 255
            }
        }
        guard weight > 0 else { return .white }
        return RGBColor(red: red / weight, green: green / weight, blue: blue / weight)
    }
}
