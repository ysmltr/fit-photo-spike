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

/// Copying photos out of the picker, with a way to stop.
struct ImportProgressCard: View {
    @ObservedObject var model: FitPhotosModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Opening photos").font(.fitDisplay(.title3))
                ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                    .tint(Theme.marker)
                Text(model.isCancelling ? "Cancelling…" : "\(min(model.completed + 1, model.total)) of \(model.total)")
                    .font(.fitMono(.subheadline))
                    .foregroundStyle(Theme.inkQuiet)
                    .contentTransition(.numericText())
                Button("Cancel") { model.cancel() }
                    .disabled(model.isCancelling)
                    .frame(minHeight: 44)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(32)
        }
    }
}
