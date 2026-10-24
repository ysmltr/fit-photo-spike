import SwiftUI

/// Right after choosing photos: one size for the whole batch, shown with the
/// first photo inside each shape.
struct SizePickerView: View {
    @ObservedObject var model: FitPhotosModel
    let onCancel: () -> Void

    private static let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    selectedStrip
                    sizes(OutputRatio.allCases.filter(\.isInstagram), title: "Instagram")
                    sizes(OutputRatio.allCases.filter { !$0.isInstagram }, title: "More sizes")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            Button { model.openEditor() } label: {
                Text("Continue with \(model.ratio.title)")
            }
            .buttonStyle(InkButtonStyle())
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(Theme.table.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: model.ratio)
    }

    private var topBar: some View {
        ZStack {
            Text("\(model.photoCount) selected")
                .font(.fitMono(.caption, weight: .medium))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(Theme.inkQuiet)
            HStack {
                Button {
                    if model.hasOpenedEditor { model.openEditor() } else { onCancel() }
                } label: {
                    Text(model.hasOpenedEditor ? "Back" : "Cancel").frame(minHeight: 44)
                }
                .foregroundStyle(Theme.ink)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick a size")
                .font(.fitDisplay(.largeTitle))
                .accessibilityAddTraits(.isHeader)
            Text(model.photoCount == 1
                 ? "Your photo is never cropped. The rest becomes background."
                 : "One size for all \(model.photoCount) photos, the way Instagram shows a post. Photos are never cropped.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkQuiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var selectedStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.inputs.prefix(7).enumerated()), id: \.offset) { _, url in
                ThumbnailImage(url: url, maximumPixelSize: 120) { image in
                    ZStack {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            LoadingPlaceholder()
                        }
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            if model.photoCount > 7 {
                Text("+\(model.photoCount - 7)")
                    .font(.fitMono(.caption))
                    .frame(width: 38, height: 38)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }

    private func sizes(_ ratios: [OutputRatio], title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.fitMono(.caption, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(Theme.inkQuiet)
                .padding(.top, 6)
            LazyVGrid(columns: SizePickerView.columns, spacing: 14) {
                ForEach(ratios) { ratio in
                    SizeCard(ratio: ratio,
                             isSelected: model.ratio == ratio,
                             isBest: ratio == .fourFive,
                             previewURL: model.inputs.first,
                             previewSize: model.sourceSize(at: 0),
                             background: model.edit(at: 0).background) {
                        withAnimation(.snappy) { model.chooseRatio(ratio) }
                    }
                }
            }
        }
    }
}

struct SizeCard: View {
    let ratio: OutputRatio
    let isSelected: Bool
    let isBest: Bool
    let previewURL: URL?
    let previewSize: CGSize
    let background: CanvasBackground
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                preview.frame(height: 72)
                HStack(spacing: 6) {
                    Text(ratio.label).font(.subheadline.weight(.bold))
                    if isBest {
                        Text("Best")
                            .font(.fitMono(.caption2, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.marker)
                    }
                }
                .padding(.top, 10)
                Text("\(ratio.title) · \(ratio.width)×\(ratio.height)")
                    .font(.fitMono(.caption2))
                    .foregroundStyle(Theme.inkQuiet)
                    .padding(.top, 3)
            }
            .foregroundStyle(Theme.ink)
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .markerRing(isSelected)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("\(ratio.label), \(ratio.title), \(ratio.width) by \(ratio.height) pixels")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The shape with crop marks, holding the first photo at Fit.
    private var preview: some View {
        let box = CGSize(width: 104, height: 64)
        let aspect = CGFloat(ratio.width) / CGFloat(ratio.height)
        let size = aspect > box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
        return Group {
            if let previewURL {
                MiniCanvas(url: previewURL, sourceSize: previewSize, canvasSize: ratio.canvasSize,
                           edit: PhotoEdit(background: background), maximumPixelSize: 240)
            } else {
                Theme.well
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            CropMarks(length: 9).stroke(Theme.ink, lineWidth: 2).padding(-4)
        }
        .accessibilityHidden(true)
    }
}
