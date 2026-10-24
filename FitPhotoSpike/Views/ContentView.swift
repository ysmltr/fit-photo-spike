import PhotosUI
import SwiftUI
import UIKit

/// Start → pick a size → edit → save or share.
struct ContentView: View {
    @StateObject private var model = FitPhotosModel()
    @Environment(\.openURL) private var openURL
    @State private var showsPicker = false
    @State private var pendingSelection: [PHPickerResult] = []

    var body: some View {
        ZStack {
            Theme.table.ignoresSafeArea()
            screen
            if model.work == .importing {
                ImportProgressCard(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.screen)
        .animation(.smooth(duration: 0.2), value: model.work)
        .foregroundStyle(Theme.ink)
        .tint(Theme.ink)
        .sheet(isPresented: $showsPicker, onDismiss: {
            let selection = pendingSelection
            pendingSelection = []
            model.receiveSelection(selection)
        }) {
            PhotoSelectionPicker { results in
                pendingSelection = results
                showsPicker = false
            }
            .ignoresSafeArea()
        }
        .alert(item: $model.message) { message in
            if message.offersSettings {
                return Alert(title: Text(message.title), message: Text(message.text),
                             primaryButton: .default(Text("Open Settings"), action: {
                                 if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                             }), secondaryButton: .cancel())
            }
            return Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text("OK")))
        }
    }

    /// Each screen carries its own transition, so switching cross-fades.
    @ViewBuilder
    private var screen: some View {
        let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.98))
        switch model.screen {
        case .start:
            StartView(isBusy: model.isBusy) { showsPicker = true }
                .transition(transition)
        case .size:
            SizePickerView(model: model) { model.startOver() }
                .transition(transition)
        case .editor:
            EditorView(model: model)
                .transition(transition)
        case .export:
            ExportView(model: model) {
                model.startOver()
                showsPicker = true
            }
            .transition(transition)
        }
    }
}

/// Copying photos out of the picker, with a way to stop. One tile per photo:
/// finished tiles fill in and the current one shimmers, so a slow iCloud
/// download never looks frozen.
struct ImportProgressCard: View {
    @ObservedObject var model: FitPhotosModel
    @State private var isSlow = false

    private static let columns = [GridItem(.adaptive(minimum: 20, maximum: 24), spacing: 6)]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Opening photos").font(.fitDisplay(.title3))
                LazyVGrid(columns: ImportProgressCard.columns, spacing: 6) {
                    ForEach(0..<model.total, id: \.self) { index in
                        tile(index)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .animation(.snappy(duration: 0.25), value: model.completed)
                .accessibilityHidden(true)
                Text(model.isCancelling ? "Cancelling…" : "\(min(model.completed + 1, model.total)) of \(model.total)")
                    .font(.fitMono(.subheadline))
                    .foregroundStyle(Theme.inkQuiet)
                    .contentTransition(.numericText())
                if isSlow && !model.isCancelling {
                    Text("Waiting for iCloud. On a slow connection this can take a moment.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkQuiet)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                Button("Cancel") { model.cancel() }
                    .disabled(model.isCancelling)
                    .frame(minHeight: 44)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(32)
            .animation(.smooth(duration: 0.3), value: isSlow)
        }
        // A photo taking more than a few seconds is usually downloading.
        .task(id: model.completed) {
            isSlow = false
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { isSlow = true }
        }
    }

    @ViewBuilder
    private func tile(_ index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if index < model.completed {
            shape.fill(Theme.ink)
        } else if index == model.completed {
            LoadingPlaceholder().clipShape(shape)
        } else {
            shape.strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }
}
