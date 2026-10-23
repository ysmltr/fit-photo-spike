import ImageIO
import SwiftUI
import UIKit

/// Decodes a small, upright preview off the main thread and hands it to
/// `content`. Decode only useful preview pixels; only the editor canvas has
/// a large decode.
struct ThumbnailImage<Content: View>: View {
    let url: URL
    let maximumPixelSize: Int
    let content: (UIImage?) -> Content
    @State private var image: UIImage?

    init(url: URL, maximumPixelSize: Int = 320, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.url = url
        self.maximumPixelSize = maximumPixelSize
        self.content = content
    }

    var body: some View {
        content(image)
            .task(id: url) {
                image = nil
                let size = maximumPixelSize
                let sourceURL = url
                // ImageIO is synchronous. Keep its bounded decode off the UI actor;
                // cancellation is forwarded below and this task always awaits it.
                let worker = Task.detached(priority: .utility) { () -> CGImage? in
                    autoreleasepool {
                        guard !Task.isCancelled,
                              let source = CGImageSourceCreateWithURL(sourceURL as CFURL,
                                  [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: size,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary)
                    }
                }
                let decoded = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                if let decoded { image = UIImage(cgImage: decoded) }
            }
            .onDisappear { image = nil }
    }
}

/// A rendered result, shown whole.
struct FileThumbnail: View {
    let url: URL
    var maximumPixelSize = 320

    var body: some View {
        ThumbnailImage(url: url, maximumPixelSize: maximumPixelSize) { image in
            ZStack {
                Theme.well
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").font(.title3).foregroundStyle(Theme.inkQuiet)
                        .accessibilityLabel("Preview unavailable")
                }
            }
        }
    }
}
