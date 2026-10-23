import SwiftUI
import UIKit

/// One photo on its canvas, drawn with the same placement math as the
/// exported file, so the editor shows exactly what will be saved.
struct CanvasArtwork: View {
    let image: UIImage?
    let sourceSize: CGSize
    let canvasSize: CGSize
    let edit: PhotoEdit

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let scale = canvasSize.width > 0 ? size.width / canvasSize.width : 0
            let rect = PlacementGeometry.imageRect(source: sourceSize, canvas: canvasSize, edit: edit)
            ZStack(alignment: .topLeading) {
                background(in: size)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .offset(x: rect.minX * scale, y: rect.minY * scale)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
    }

    @ViewBuilder
    private func background(in size: CGSize) -> some View {
        switch edit.background {
        case .color(let color):
            Rectangle().fill(Color(rgb: color))
        case .blur:
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .blur(radius: min(size.width, size.height) * CanvasBackground.blurFraction, opaque: true)
            } else {
                Rectangle().fill(Theme.well)
            }
        }
    }
}

/// A small canvas preview from a thumbnail decode, for strips and cards.
struct MiniCanvas: View {
    let url: URL
    let sourceSize: CGSize
    let canvasSize: CGSize
    let edit: PhotoEdit
    var maximumPixelSize = 240

    var body: some View {
        ThumbnailImage(url: url, maximumPixelSize: maximumPixelSize) { image in
            CanvasArtwork(image: image, sourceSize: sourceSize, canvasSize: canvasSize, edit: edit)
        }
    }
}

/// The editable canvas. Pinch to resize and drag to move; near the center,
/// Fit or Fill the photo snaps into place. While picking a color, touch and
/// drag to aim the loupe, then lift to choose.
struct PhotoCanvasEditor: View {
    let image: UIImage?
    let sourceSize: CGSize
    let canvasSize: CGSize
    let edit: PhotoEdit
    let isPicking: Bool
    let onPlacement: (PhotoEdit) -> Void
    let onPick: (RGBColor) -> Void

    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var loupePoint: CGPoint?
    @State private var loupeColor: RGBColor?
    @State private var sampler: PixelSampler?
    @State private var snaps = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            CanvasArtwork(image: image, sourceSize: sourceSize, canvasSize: canvasSize,
                          edit: liveEdit(in: size))
                .contentShape(Rectangle())
                .gesture(placementGesture(in: size), including: isPicking ? .none : .all)
                .gesture(pickingGesture(in: size), including: isPicking ? .all : .subviews)
                .overlay(alignment: .topLeading) {
                    if let loupePoint, let image {
                        Loupe(image: image, photoRect: displayRect(in: size), point: loupePoint, color: loupeColor)
                    }
                }
        }
        .sensoryFeedback(.alignment, trigger: snaps)
    }

    /// The committed edit plus the gesture in progress.
    private func liveEdit(in size: CGSize) -> PhotoEdit {
        guard pinch != 1 || drag != .zero, size.width > 0, size.height > 0 else { return edit }
        var live = edit
        live.scale = (edit.scale * Double(pinch)).clamped(to: PhotoEdit.scaleRange)
        live.offsetX = (edit.offsetX + Double(drag.width / size.width)).clamped(to: PhotoEdit.offsetRange)
        live.offsetY = (edit.offsetY + Double(drag.height / size.height)).clamped(to: PhotoEdit.offsetRange)
        return live
    }

    private func placementGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                var next = edit
                next.scale = snapped(scale: edit.scale * Double(value.magnification))
                onPlacement(next)
            }
            .simultaneously(with: DragGesture(minimumDistance: 4)
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    guard size.width > 0, size.height > 0 else { return }
                    var next = edit
                    next.offsetX = snapped(offset: edit.offsetX + Double(value.translation.width / size.width))
                    next.offsetY = snapped(offset: edit.offsetY + Double(value.translation.height / size.height))
                    onPlacement(next)
                })
    }

    private func pickingGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = clampedToPhoto(value.location, in: size)
                loupePoint = point
                loupeColor = color(at: point, in: size)
            }
            .onEnded { value in
                let point = clampedToPhoto(value.location, in: size)
                if let picked = color(at: point, in: size) { onPick(picked) }
                loupePoint = nil
                loupeColor = nil
            }
    }

    /// Fit and Fill are easy to find again by hand.
    private func snapped(scale: Double) -> Double {
        let clamped = scale.clamped(to: PhotoEdit.scaleRange)
        let fill = PlacementGeometry.fillScale(source: sourceSize, canvas: canvasSize)
        for target in [1, fill] where abs(clamped - target) / target < 0.04 {
            if clamped != target { snaps += 1 }
            return target
        }
        return clamped
    }

    /// The photo's center snaps to the canvas center.
    private func snapped(offset: Double) -> Double {
        let clamped = offset.clamped(to: PhotoEdit.offsetRange)
        guard abs(clamped) < 0.02 else { return clamped }
        if clamped != 0 { snaps += 1 }
        return 0
    }

    private func displayRect(in size: CGSize) -> CGRect {
        let scale = canvasSize.width > 0 ? size.width / canvasSize.width : 0
        let rect = PlacementGeometry.imageRect(source: sourceSize, canvas: canvasSize, edit: edit)
        return CGRect(x: rect.minX * scale, y: rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// Keeps the loupe on the part of the photo that is visible on the canvas.
    private func clampedToPhoto(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let visible = displayRect(in: size).intersection(CGRect(origin: .zero, size: size))
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { return point }
        return CGPoint(x: min(max(point.x, visible.minX), visible.maxX - 0.5),
                       y: min(max(point.y, visible.minY), visible.maxY - 0.5))
    }

    private func color(at point: CGPoint, in size: CGSize) -> RGBColor? {
        let rect = displayRect(in: size)
        guard rect.width > 0, rect.height > 0 else { return nil }
        if sampler == nil, let cgImage = image?.cgImage {
            sampler = PixelSampler(image: cgImage)
        }
        return sampler?.color(atUnitX: (point.x - rect.minX) / rect.width,
                              y: (point.y - rect.minY) / rect.height)
    }
}

/// A magnifier above the finger showing the pixels being picked and their color.
struct Loupe: View {
    let image: UIImage
    let photoRect: CGRect
    let point: CGPoint
    let color: RGBColor?

    private static let diameter: CGFloat = 108
    private static let zoom: CGFloat = 5

    var body: some View {
        let diameter = Loupe.diameter
        let zoom = Loupe.zoom
        let local = CGPoint(x: (point.x - photoRect.minX) * zoom, y: (point.y - photoRect.minY) * zoom)
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: photoRect.width * zoom, height: photoRect.height * zoom)
                    .offset(x: diameter / 2 - local.x, y: diameter / 2 - local.y)
            }
            .frame(width: diameter, height: diameter, alignment: .topLeading)
            .clipShape(Circle())
            .overlay { Circle().stroke(Color.white, lineWidth: 3) }
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(0.75), lineWidth: 1.5)
                    .frame(width: 12, height: 12)
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            if let color {
                Text(color.hexString)
                    .font(.fitMono(.caption, weight: .semibold))
                    .foregroundStyle(Theme.onInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.ink, in: Capsule())
            }
        }
        .position(x: point.x, y: point.y - diameter / 2 - 44)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
