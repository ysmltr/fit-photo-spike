import ImageIO
import SwiftUI
import UIKit

/// Decode only useful preview pixels. Only the open detail has a large decode.
struct FileThumbnail: View {
    let url: URL
    var maximumPixelSize = 320
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.title).foregroundStyle(Color.gray)
                    .accessibilityLabel("Preview unavailable")
            }
        }
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
