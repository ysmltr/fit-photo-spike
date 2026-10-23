import SwiftUI

/// Renders the batch at full size, then saves every photo to the library or
/// shares them all at once.
struct ExportView: View {
    @ObservedObject var model: FitPhotosModel
    let onNewBatch: () -> Void
    @State private var showsShare = false
    @State private var confirmsNewBatch = false

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.fitDisplay(.title))
                    .contentTransition(.numericText())
                    .accessibilityAddTraits(.isHeader)
                Text("\(model.ratio.title) · \(model.ratio.width) × \(model.ratio.height) · JPEG, best quality")
                    .font(.fitMono(.caption))
                    .foregroundStyle(Theme.inkQuiet)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            ScrollView {
                LazyVGrid(columns: ExportView.columns, spacing: 14) {
                    ForEach(Array(model.inputs.enumerated()), id: \.offset) { index, url in
                        VStack(alignment: .leading, spacing: 5) {
                            tile(index: index, url: url)
                            Text(String(format: "%02d", index + 1))
                                .font(.fitMono(.caption2))
                                .foregroundStyle(Theme.inkQuiet)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Photo \(index + 1)")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
            actions
        }
        .background(Theme.table.ignoresSafeArea())
        .sheet(isPresented: $showsShare) {
            BatchShareSheet(urls: model.outputs, session: model.session) { _ in showsShare = false }
                .interactiveDismissDisabled()
        }
        .confirmationDialog("Start a new batch?", isPresented: $confirmsNewBatch, titleVisibility: .visible) {
            Button("Choose new photos", role: model.savedToPhotos ? nil : .destructive) { onNewBatch() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(model.savedToPhotos
                 ? "Your saved photos stay in your library."
                 : "These photos aren't saved yet. Save or share them first if you want to keep them.")
        }
        .sensoryFeedback(.success, trigger: model.savedToPhotos) { _, saved in saved }
    }

    private var title: String {
        switch model.work {
        case .converting:
            return "Preparing \(min(model.completed + 1, model.total)) of \(model.total)"
        case .saving:
            return "Saving…"
        case .idle, .importing:
            if model.savedToPhotos { return "Saved to Photos" }
            return model.photoCount == 1 ? "1 photo ready" : "\(model.photoCount) photos ready"
        }
    }

    private var topBar: some View {
        HStack {
            Button { model.backToEditor() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").fontWeight(.semibold)
                    Text("Editor")
                }
                .frame(minHeight: 44)
            }
            .foregroundStyle(Theme.ink)
            .disabled(model.work == .saving || model.isCancelling)
            Spacer()
            if !model.isBusy && !model.outputs.isEmpty {
                Button("New batch") { confirmsNewBatch = true }
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// Finished files once ready; until then, the live preview of each photo.
    @ViewBuilder
    private func tile(index: Int, url: URL) -> some View {
        let aspect = CGFloat(model.ratio.width) / CGFloat(model.ratio.height)
        ZStack {
            if model.outputs.indices.contains(index) {
                FileThumbnail(url: model.outputs[index], maximumPixelSize: 300)
            } else {
                MiniCanvas(url: url, sourceSize: model.sourceSize(at: index),
                           canvasSize: model.canvasSize, edit: model.edit(at: index),
                           maximumPixelSize: 200)
                    .opacity(index < model.completed ? 1 : 0.4)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipped()
        .animation(.smooth(duration: 0.25), value: model.completed)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if model.work == .converting {
                ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                    .tint(Theme.marker)
                    .padding(.vertical, 6)
                Button("Cancel") { model.backToEditor() }
                    .buttonStyle(InkButtonStyle(prominent: false))
                    .disabled(model.isCancelling)
            } else {
                if model.savedToPhotos {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.marker)
                        Text("Saved to Photos").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                } else {
                    Button { model.saveAll() } label: {
                        Label(saveTitle, systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(InkButtonStyle())
                    .disabled(model.isBusy || model.outputs.isEmpty)
                }
                Button { showsShare = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                // Share becomes the main action once everything is saved.
                .buttonStyle(InkButtonStyle(prominent: model.savedToPhotos))
                .disabled(model.isBusy || model.outputs.isEmpty)
                Text("Saved as new photos. Your originals stay untouched.")
                    .font(.fitMono(.caption2))
                    .foregroundStyle(Theme.inkQuiet)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.3), value: model.savedToPhotos)
    }

    private var saveTitle: String {
        if model.work == .saving { return "Saving…" }
        return model.photoCount == 1 ? "Save to Photos" : "Save all \(model.photoCount) to Photos"
    }
}
