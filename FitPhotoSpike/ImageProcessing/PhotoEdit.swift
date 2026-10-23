import CoreGraphics
import Foundation

/// An opaque sRGB color with components from 0 to 1.
struct RGBColor: Equatable, Hashable, Sendable, Codable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = RGBColor.clamped(red)
        self.green = RGBColor.clamped(green)
        self.blue = RGBColor.clamped(blue)
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    static let white = RGBColor(hex: 0xFFFFFF)

    /// For example "#F6C85F".
    var hexString: String {
        String(format: "#%02X%02X%02X", RGBColor.byte(red), RGBColor.byte(green), RGBColor.byte(blue))
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private static func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
}

enum CanvasBackground: Equatable, Hashable, Sendable, Codable {
    case color(RGBColor)
    /// An enlarged, blurred copy of the photo itself.
    case blur

    /// Blur strength as a fraction of the canvas's shorter side. The editor
    /// preview and the exported file use the same value.
    static let blurFraction: CGFloat = 0.035
}

/// How one photo sits on its canvas. Every value is relative to the canvas,
/// so an edit looks the same in the editor and in the full-size export.
struct PhotoEdit: Equatable, Hashable, Sendable, Codable {
    /// 1 shows the whole photo (Fit). Larger values zoom in.
    var scale: Double = 1
    /// Horizontal offset of the photo's center, as a fraction of the canvas width.
    var offsetX: Double = 0
    /// Vertical offset of the photo's center, as a fraction of the canvas
    /// height. Positive values move the photo down.
    var offsetY: Double = 0
    var background: CanvasBackground = .color(.white)

    static let standard = PhotoEdit()
    static let scaleRange: ClosedRange<Double> = 0.25...8
    static let offsetRange: ClosedRange<Double> = -1...1
}

/// Placement shared by the editor and the renderer, in canvas pixels with
/// the origin at the top left.
enum PlacementGeometry {
    static func fitScale(source: CGSize, canvas: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0 else { return 0 }
        return min(canvas.width / source.width, canvas.height / source.height)
    }

    /// How much larger than Fit the photo must be to cover the whole canvas.
    static func fillScale(source: CGSize, canvas: CGSize) -> Double {
        guard source.width > 0, source.height > 0, canvas.width > 0, canvas.height > 0 else { return 1 }
        let fit = min(canvas.width / source.width, canvas.height / source.height)
        let cover = max(canvas.width / source.width, canvas.height / source.height)
        return Double(cover / fit)
    }

    static func imageRect(source: CGSize, canvas: CGSize, edit: PhotoEdit) -> CGRect {
        let scale = fitScale(source: source, canvas: canvas) * CGFloat(edit.scale)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: (canvas.width - width) / 2 + CGFloat(edit.offsetX) * canvas.width,
                      y: (canvas.height - height) / 2 + CGFloat(edit.offsetY) * canvas.height,
                      width: width, height: height)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
