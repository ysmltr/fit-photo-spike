import Foundation
import SwiftUI

enum EditorPanel: String, CaseIterable, Identifiable {
    case position = "Position"
    case background = "Background"

    var id: String { rawValue }
}

/// Two-part switch with a sliding pill.
struct PanelSwitch: View {
    @Binding var selection: EditorPanel
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditorPanel.allCases) { panel in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = panel }
                } label: {
                    Text(panel.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == panel ? Theme.onInk : Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if selection == panel {
                                Capsule().fill(Theme.ink).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == panel ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.well, in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: Position

struct PositionPanel: View {
    @ObservedObject var model: FitPhotosModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                PlacementChoice(title: "Fit", detail: "whole photo", symbol: .fit,
                                isSelected: model.currentIsFit) { model.applyFit(fill: false) }
                PlacementChoice(title: "Fill", detail: "no background", symbol: .fill,
                                isSelected: model.currentIsFill) { model.applyFit(fill: true) }
            }
            HStack(spacing: 12) {
                Text("Size").font(.subheadline.weight(.semibold))
                Slider(value: sliderValue, in: 0...1)
                    .tint(Theme.ink)
                    .accessibilityLabel("Photo size")
                    .accessibilityValue(percentText)
                Text(percentText)
                    .font(.fitMono(.footnote))
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
                Button { model.resetCurrentPosition() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(Theme.ink)
                .disabled(model.currentIsFit)
                .accessibilityLabel("Reset this photo")
            }
        }
    }

    /// Logarithmic, so small and large zooms are equally easy to set.
    private var sliderValue: Binding<Double> {
        let range = PhotoEdit.scaleRange
        let span = log(range.upperBound / range.lowerBound)
        return Binding(
            get: { log(model.currentEdit.scale / range.lowerBound) / span },
            set: { model.setScale(range.lowerBound * exp($0 * span)) }
        )
    }

    /// Size relative to Fit, which is 100%.
    private var percentText: String {
        "\(Int((model.currentEdit.scale * 100).rounded()))%"
    }
}

struct PlacementChoice: View {
    enum Symbol { case fit, fill }

    let title: String
    let detail: String
    let symbol: Symbol
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PlacementSymbol(symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.fitMono(.caption2)).opacity(0.8)
                }
            }
            .foregroundStyle(isSelected ? Theme.onInk : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(isSelected ? Theme.ink : Theme.well,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected) { _, selected in selected }
    }
}

/// Fit: the photo inside the frame. Fill: the photo past the frame's edges.
struct PlacementSymbol: View {
    let symbol: PlacementChoice.Symbol

    var body: some View {
        ZStack {
            switch symbol {
            case .fit:
                Rectangle().strokeBorder(lineWidth: 1.6)
                Rectangle().frame(width: 18, height: 11)
            case .fill:
                Rectangle().frame(width: 18, height: 22)
                Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
            }
        }
        .frame(width: 24, height: 28)
        .accessibilityHidden(true)
    }
}

// MARK: Background

struct Swatch: Identifiable, Sendable {
    let name: String
    let color: RGBColor
    var id: String { name }

    static let palette: [Swatch] = [
        Swatch(name: "White", color: RGBColor(hex: 0xFFFFFF)),
        Swatch(name: "Paper", color: RGBColor(hex: 0xF1EEE8)),
        Swatch(name: "Fog", color: RGBColor(hex: 0xC9CDD2)),
        Swatch(name: "Black", color: RGBColor(hex: 0x16181B)),
        Swatch(name: "Tomato", color: RGBColor(hex: 0xE2553F)),
        Swatch(name: "Butter", color: RGBColor(hex: 0xF3D477)),
        Swatch(name: "Sage", color: RGBColor(hex: 0x9DB39A)),
        Swatch(name: "Pool", color: RGBColor(hex: 0x6FA8C9)),
        Swatch(name: "Plum", color: RGBColor(hex: 0x5A3E5D)),
        Swatch(name: "Rose", color: RGBColor(hex: 0xEDB8B0)),
        Swatch(name: "Navy", color: RGBColor(hex: 0x1F2A44)),
        Swatch(name: "Sand", color: RGBColor(hex: 0xD8C3A0))
    ]
}

struct BackgroundPanel: View {
    @ObservedObject var model: FitPhotosModel
    @Binding var isPicking: Bool

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 6)

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ToolTile(title: "From photo", isSelected: isPicking, action: { isPicking.toggle() }) {
                    Image(systemName: "eyedropper")
                }
                ToolTile(title: "Blur", isSelected: !isPicking && model.currentEdit.background == .blur, action: {
                    isPicking = false
                    model.setBackground(.blur)
                }) {
                    BlurGlyph()
                }
                CustomColorTile(color: customColor)
            }
            LazyVGrid(columns: BackgroundPanel.columns, spacing: 6) {
                ForEach(Swatch.palette) { swatch in
                    Button {
                        isPicking = false
                        model.setBackground(.color(swatch.color))
                    } label: {
                        Circle()
                            .fill(Color(rgb: swatch.color))
                            .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: 1) }
                            .frame(width: 36, height: 36)
                            .frame(width: 44, height: 44)
                            .markerRing(isCurrent(swatch), inset: -2, lineWidth: 2.5)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(isCurrent(swatch) ? .isSelected : [])
                }
            }
        }
        .sensoryFeedback(.selection, trigger: model.currentEdit.background)
    }

    private func isCurrent(_ swatch: Swatch) -> Bool {
        !isPicking && model.currentEdit.background == .color(swatch.color)
    }

    /// The system color picker edits the current background color.
    private var customColor: Binding<Color> {
        Binding(
            get: {
                if case .color(let color) = model.currentEdit.background { return Color(rgb: color) }
                return .white
            },
            set: { newValue in
                isPicking = false
                model.setBackground(.color(RGBColor(newValue)))
            }
        )
    }
}

struct ToolTile<Icon: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    let icon: Icon

    init(title: String, isSelected: Bool, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
        self.icon = icon()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                icon.font(.title3).frame(height: 24)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .markerRing(isSelected, inset: -5, lineWidth: 2.5)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CustomColorTile: View {
    @Binding var color: Color

    var body: some View {
        VStack(spacing: 6) {
            ColorPicker("Custom color", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(height: 24)
            Text("Custom")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A tiny blurred landscape.
struct BlurGlyph: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color(rgb: RGBColor(hex: 0x9CC9E3)))
            Circle()
                .fill(Color(rgb: RGBColor(hex: 0xF6C85F)))
                .frame(width: 10, height: 10)
                .offset(x: 4, y: -4)
                .blur(radius: 2)
            Rectangle()
                .fill(Color(rgb: RGBColor(hex: 0x2F7FA8)))
                .frame(height: 9)
                .offset(y: 7)
                .blur(radius: 2.5)
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct ApplyToAllRow: View {
    @ObservedObject var model: FitPhotosModel

    var body: some View {
        Toggle(isOn: $model.applyToAll) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apply to all \(model.photoCount) photos").font(.body.weight(.semibold))
                Text(model.applyToAll
                     ? "Fit, Fill and background change every photo"
                     : "Changes affect only photo \(model.currentIndex + 1)")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkQuiet)
            }
        }
        .tint(Theme.marker)
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
