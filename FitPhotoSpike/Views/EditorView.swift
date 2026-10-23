import SwiftUI

/// The canvas on the table, the photo strip and the tool tray. Swipe beside
/// the canvas, or tap the strip, to move between photos.
struct EditorView: View {
    @ObservedObject var model: FitPhotosModel
    @StateObject private var images = EditorImageStore()
    @State private var panel: EditorPanel = .position
    @State private var isPicking = false
    @State private var arrivalEdge: Edge = .trailing

    var body: some View {
        VStack(spacing: 0) {
            topBar
            stage
            strip
            tray
        }
        .background(Theme.table.ignoresSafeArea())
        .onAppear { images.prepare(around: model.currentIndex, in: model.inputs) }
        .onChange(of: model.currentIndex) { _, index in
            isPicking = false
            images.prepare(around: index, in: model.inputs)
        }
        .onChange(of: panel) { _, newPanel in
            if newPanel == .position { isPicking = false }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            Text(String(format: "%02d / %02d", model.currentIndex + 1, model.photoCount))
                .font(.fitMono(.subheadline, weight: .medium))
                .contentTransition(.numericText())
                .accessibilityLabel("Photo \(model.currentIndex + 1) of \(model.photoCount)")
            HStack {
                Button { model.openSizes() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").fontWeight(.semibold)
                        Text("Sizes")
                    }
                    .frame(minHeight: 44)
                }
                .foregroundStyle(Theme.ink)
                Spacer()
                Button("Save") { model.openExport() }
                    .buttonStyle(CapsuleButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: Canvas

    private var stage: some View {
        GeometryReader { proxy in
            let canvas = fittedCanvas(in: proxy.size)
            VStack(spacing: 8) {
                DimensionLine(label: "\(model.ratio.width)")
                    .frame(width: canvas.width)
                HStack(spacing: 8) {
                    Color.clear.frame(width: 14, height: 1)
                    canvasEditor
                        .frame(width: canvas.width, height: canvas.height)
                        .shadow(color: Theme.shadow, radius: 18, y: 10)
                    DimensionLine(label: "\(model.ratio.height)", vertical: true)
                        .frame(width: 14, height: canvas.height)
                }
                Text(isPicking ? "Touch the photo, lift to pick" : "Pinch to resize · drag to move")
                    .font(.fitMono(.caption2))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(isPicking ? Theme.marker : Theme.inkQuiet)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(swipeGesture)
        }
    }

    private var canvasEditor: some View {
        let index = model.currentIndex
        let url = model.inputs.indices.contains(index) ? model.inputs[index] : nil
        return PhotoCanvasEditor(
            image: url.flatMap { images.image(for: $0) },
            sourceSize: model.currentSourceSize,
            canvasSize: model.canvasSize,
            edit: model.currentEdit,
            isPicking: isPicking,
            onPlacement: { edit in
                model.setPlacement(scale: edit.scale, offsetX: edit.offsetX, offsetY: edit.offsetY)
            },
            onPick: { color in
                isPicking = false
                model.setBackground(.color(color))
            }
        )
        .id(index)
        .transition(.push(from: arrivalEdge))
        .accessibilityElement()
        .accessibilityLabel("Photo \(index + 1) on a \(model.ratio.title) canvas")
        .accessibilityHint("Use Fit, Fill and the size slider below to adjust it.")
    }

    /// The largest canvas of the chosen shape that leaves room for the
    /// measurements and the hint.
    private func fittedCanvas(in size: CGSize) -> CGSize {
        let available = CGSize(width: max(size.width - 88, 60), height: max(size.height - 64, 60))
        let aspect = model.canvasSize.width / max(model.canvasSize.height, 1)
        if available.width / available.height > aspect {
            return CGSize(width: available.height * aspect, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / aspect)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let width = value.translation.width
                guard abs(width) > abs(value.translation.height), abs(width) > 50 else { return }
                go(to: model.currentIndex + (width < 0 ? 1 : -1))
            }
    }

    private func go(to index: Int) {
        guard index != model.currentIndex, model.inputs.indices.contains(index) else { return }
        arrivalEdge = index > model.currentIndex ? .trailing : .leading
        // Let the outgoing canvas pick up the new direction before it leaves.
        Task { @MainActor in
            withAnimation(.snappy(duration: 0.32)) { model.select(index) }
        }
    }

    // MARK: Strip

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(model.inputs.enumerated()), id: \.offset) { index, url in
                        Button { go(to: index) } label: {
                            VStack(spacing: 4) {
                                MiniCanvas(url: url, sourceSize: model.sourceSize(at: index),
                                           canvasSize: model.canvasSize, edit: model.edit(at: index),
                                           maximumPixelSize: 160)
                                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                                Text(String(format: "%02d", index + 1))
                                    .font(.fitMono(.caption2, weight: index == model.currentIndex ? .semibold : .regular))
                                    .foregroundStyle(index == model.currentIndex ? Theme.marker : Theme.inkQuiet)
                            }
                            .markerRing(index == model.currentIndex, inset: -6, lineWidth: 2.5)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel("Photo \(index + 1)")
                        .accessibilityAddTraits(index == model.currentIndex ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(model.currentIndex, anchor: .center) }
            .onChange(of: model.currentIndex) { _, index in
                withAnimation(.snappy) { proxy.scrollTo(index, anchor: .center) }
            }
        }
        .frame(height: thumbnailSize.height + 44)
    }

    /// Strip thumbnails keep the canvas shape within an 80 × 44 point box.
    private var thumbnailSize: CGSize {
        let box = CGSize(width: 80, height: 44)
        let aspect = model.canvasSize.width / max(model.canvasSize.height, 1)
        if aspect > box.width / box.height {
            return CGSize(width: box.width, height: box.width / aspect)
        }
        return CGSize(width: box.height * aspect, height: box.height)
    }

    // MARK: Tray

    private var tray: some View {
        VStack(spacing: 14) {
            PanelSwitch(selection: $panel)
            switch panel {
            case .position:
                PositionPanel(model: model)
            case .background:
                BackgroundPanel(model: model, isPicking: $isPicking)
            }
            if model.photoCount > 1 {
                ApplyToAllRow(model: model)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.shadow.opacity(0.5), radius: 20, y: -4)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
