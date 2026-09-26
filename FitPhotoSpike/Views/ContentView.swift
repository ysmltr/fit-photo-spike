import SwiftUI
import UIKit
import PhotosUI

struct ContentView: View {
    @StateObject private var model = FitPhotosModel()
    @Environment(\.openURL) private var openURL
    @State private var showsPicker = false
    @State private var showsShare = false
    @State private var showsStartOver = false
    @State private var showsHelp = false
    @State private var preview: PreviewSelection?
    @State private var pendingSelection: [PHPickerResult] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.inputs.isEmpty { emptySelection }
                    else if model.outputs.isEmpty { selection }
                    else { results }
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.isBusy {
                    progress.padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.outputs.isEmpty { resultActions }
                else { primaryAction }
            }
            .navigationTitle(model.outputs.isEmpty ? "Fit Photos" : "Your Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.outputs.isEmpty {
                        Button { showsHelp = true } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("About Fit Photos")
                            .disabled(model.isBusy)
                    } else {
                        Button("New Batch") { showsStartOver = true }.disabled(model.isBusy)
                    }
                }
            }
        }
        .tint(Color(uiColor: .label))
        .sheet(isPresented: $showsPicker, onDismiss: {
            let selection = pendingSelection
            pendingSelection = []
            model.receiveSelection(selection)
        }) {
            PhotoSelectionPicker { results in
                pendingSelection = results
                showsPicker = false
            }
        }
        .sheet(isPresented: $showsShare) {
            BatchShareSheet(urls: model.outputs, session: model.session) { _ in showsShare = false }
                .interactiveDismissDisabled()
        }
        .sheet(item: $preview) { selection in
            PhotoPreview(urls: model.outputs, initialIndex: selection.index)
        }
        .sheet(isPresented: $showsHelp) { about }
        .alert(item: $model.message) { message in
            if message.offersSettings {
                return Alert(title: Text(message.title), message: Text(message.text),
                             primaryButton: .default(Text("Open Settings"), action: {
                                 if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                             }), secondaryButton: .cancel())
            }
            return Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Start a new batch?", isPresented: $showsStartOver, titleVisibility: .visible) {
            Button("Start New Batch", role: .destructive) { model.startOver(); showsPicker = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the current temporary results from Fit Photos. Photos you already saved or shared are kept.")
        }
    }

    private var emptySelection: some View {
        VStack(spacing: 28) {
            Text("The whole photo. A better fit.")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44)).accessibilityHidden(true)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // Keep the next action reachable independently of the scrollable content.
    private var primaryAction: some View {
        Button {
            if model.inputs.isEmpty { showsPicker = true }
            else { model.convert() }
        } label: {
            Text(model.inputs.isEmpty ? "Select Photos" : "Preview Photos")
        }
        .buttonStyle(FitPrimaryButtonStyle())
        .disabled(model.isBusy)
        .accessibilityLabel(model.inputs.isEmpty ? "Select Photos" : "Preview \(model.inputs.count) photos")
        .accessibilityHint(model.inputs.isEmpty
            ? "Choose up to 20 photos."
            : "Converts your selection using the chosen ratio.")
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("\(model.inputs.count) selected").font(.headline).fixedSize()
                    Spacer(minLength: 0)
                    editSelectionButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.inputs.count) selected").font(.headline)
                    editSelectionButton
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(model.inputs.enumerated()), id: \.element) { index, url in
                        VStack(spacing: 4) {
                            FileThumbnail(url: url, maximumPixelSize: 192).frame(width: 64, height: 64)
                                .overlay(Rectangle().stroke(.gray.opacity(0.25)))
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .ignore)
                            .accessibilityLabel("Selected photo \(index + 1) of \(model.inputs.count)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            RatioChooser(selection: $model.ratio).disabled(model.isBusy)
        }
    }

    private var editSelectionButton: some View {
        Button("Edit selection") { showsPicker = true }
            .frame(minHeight: 44).disabled(model.isBusy)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(model.outputs.count) ready Â· \(model.ratio.title)").font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Review your photos, then save or share the whole batch.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                ForEach(Array(model.outputs.enumerated()), id: \.element) { index, url in
                    Button { preview = PreviewSelection(index: index) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            FileThumbnail(url: url)
                                .aspectRatio(CGFloat(model.ratio.width) / CGFloat(model.ratio.height), contentMode: .fit)
                                .overlay(Rectangle().stroke(.gray.opacity(0.25)))
                            Text("Photo \(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityLabel("Preview photo \(index + 1) of \(model.outputs.count)")
                }
            }
            Button("Change Ratio") { model.changeRatio() }.frame(minHeight: 44).disabled(model.isBusy)
            Text("Save All creates new copies. Your originals stay unchanged.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var resultActions: some View {
        VStack(spacing: 8) {
            Button { showsShare = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .buttonStyle(FitPrimaryButtonStyle()).disabled(model.isBusy)
                .accessibilityLabel("Share all \(model.outputs.count) photos")
            Button { model.saveAll() } label: {
                Label(model.savedToPhotos ? "Saved to Photos" : model.work == .saving ? "Savingâ€¦" : "Save All",
                      systemImage: model.savedToPhotos ? "checkmark" : "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered).disabled(model.isBusy || model.savedToPhotos)
                .accessibilityLabel(model.savedToPhotos ? "All photos saved" : "Save all \(model.outputs.count) photos to Photos")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.work == .saving {
                ProgressView("Saving all photosâ€¦")
                Text("Keep Fit Photos open until saving finishes.").font(.footnote)
            } else {
                ProgressView(value: Double(model.completed), total: Double(max(1, model.total)))
                Text(model.isCancelling ? "Cancellingâ€¦" : "\(model.work == .importing ? "Loading" : "Converting") \(min(model.completed + 1, model.total)) of \(model.total)")
                    .font(.headline)
                Button("Cancel") { model.cancel() }.disabled(model.isCancelling).frame(minHeight: 44)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var about: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your photos stay yours").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Only the photos you select. Processing stays on your device; Fit Photos never uploads your images.")
                    Text("Originals stay unchanged. New copies are saved to Photos only when you choose to save them.")
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("About Fit Photos").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsHelp = false } } }
        }
    }
}

private struct PreviewSelection: Identifiable {
    let id = UUID()
    let index: Int
}

struct FitPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52).padding(.horizontal, 12)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .background(Color(uiColor: .label), in: RoundedRectangle(cornerRadius: 10))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
    }
}
