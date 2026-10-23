import SwiftUI
import UIKit

/// Light Table: a cool, quiet surface so photos stay the most colorful thing
/// on screen, and one red grease-pencil accent that marks the current choice.
enum Theme {
    static let table = adaptive(light: 0xEEF0F2, dark: 0x101113)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1B1D20)
    /// Controls that sit on `surface`.
    static let well = adaptive(light: 0xEEF0F2, dark: 0x26292D)
    static let ink = adaptive(light: 0x15171A, dark: 0xF2F3F5)
    static let inkQuiet = adaptive(light: 0x5B6068, dark: 0xA3A8B0)
    static let hairline = adaptive(light: 0xD5D9DE, dark: 0x2C2F34)
    static let marker = adaptive(light: 0xD92D20, dark: 0xFF5A4E)
    /// Text and icons on an `ink` fill.
    static let onInk = adaptive(light: 0xFFFFFF, dark: 0x101113)
    static let shadow = Color.black.opacity(0.16)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(rgb color: RGBColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
    }
}

extension RGBColor {
    /// Converts a picker color to sRGB, clamping wide-gamut values.
    init(_ color: Color) {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        _ = UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

extension Font {
    /// SF Pro Expanded, heavy: screen titles.
    static func fitDisplay(_ style: Font.TextStyle) -> Font {
        .system(style, weight: .heavy).width(.expanded)
    }

    /// SF Mono: counters, sizes and measurements.
    static func fitMono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }
}

// MARK: Marks

/// A loose, hand-drawn loop, like a grease pencil circling a frame on a
/// contact sheet. Drawn in a 200 × 120 design box scaled to the rect.
struct MarkerRing: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 200 * rect.width, y: rect.minY + y / 120 * rect.height)
        }
        var path = Path()
        path.move(to: point(24, 64))
        path.addCurve(to: point(174, 22), control1: point(16, 22), control2: point(118, 2))
        path.addCurve(to: point(122, 112), control1: point(206, 36), control2: point(198, 98))
        path.addCurve(to: point(12, 56), control1: point(58, 122), control2: point(4, 100))
        path.addCurve(to: point(58, 20), control1: point(16, 40), control2: point(34, 28))
        return path
    }
}

/// The red ring that marks the current choice. It draws itself in.
struct MarkerRingMark: View {
    var lineWidth: CGFloat = 3
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MarkerRing()
            .trim(from: 0, to: progress)
            .stroke(Theme.marker, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                if reduceMotion {
                    progress = 1
                } else {
                    withAnimation(.easeOut(duration: 0.32)) { progress = 1 }
                }
            }
    }
}

extension View {
    /// Circles this view in red while `isShown`. A negative inset draws the
    /// ring outside the view's bounds.
    func markerRing(_ isShown: Bool, inset: CGFloat = -7, lineWidth: CGFloat = 3) -> some View {
        overlay {
            if isShown {
                MarkerRingMark(lineWidth: lineWidth).padding(inset)
            }
        }
    }
}

/// Printer's crop marks at the four corners of a size.
struct CropMarks: Shape {
    var length: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let l = min(length, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return path
    }
}

/// A print-style measurement: end ticks, a hairline and the pixel count.
struct DimensionLine: View {
    let label: String
    var vertical = false

    var body: some View {
        if vertical {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.inkQuiet).frame(width: 9, height: 1)
                Rectangle().fill(Theme.inkQuiet.opacity(0.6)).frame(width: 1)
                Text(label)
                    .font(.fitMono(.caption2))
                    .foregroundStyle(Theme.inkQuiet)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 14, height: 40)
                Rectangle().fill(Theme.inkQuiet.opacity(0.6)).frame(width: 1)
                Rectangle().fill(Theme.inkQuiet).frame(width: 9, height: 1)
            }
            .accessibilityHidden(true)
        } else {
            HStack(spacing: 0) {
                Rectangle().fill(Theme.inkQuiet).frame(width: 1, height: 9)
                Rectangle().fill(Theme.inkQuiet.opacity(0.6)).frame(height: 1)
                Text(label)
                    .font(.fitMono(.caption2))
                    .foregroundStyle(Theme.inkQuiet)
                    .padding(.horizontal, 6)
                    .fixedSize()
                Rectangle().fill(Theme.inkQuiet.opacity(0.6)).frame(height: 1)
                Rectangle().fill(Theme.inkQuiet).frame(width: 1, height: 9)
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: Buttons

/// Full-width primary (ink) or secondary (well) button.
struct InkButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(prominent: Bool = true) {
        self.prominent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(prominent ? Theme.onInk : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 16)
            .background(prominent ? Theme.ink : Theme.well,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Small ink pill for a top-bar action such as Save.
struct CapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, 18)
            .frame(minHeight: 36)
            .background(Theme.ink, in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Keeps a custom label and only adds a soft press.
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
