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
                VStack(alignment: .leading, spacing: 24) {
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
            }
            .navigationTitle(model.outputs.isEmpty ? "Fit Photos" : "Your Photos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.outputs.isEmpty {
                        Button { showsHelp = true } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("About Fit Photos and Shortcuts")
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
            BatchShareSheet(urls: model.outputs) { _ in showsShare = false }
                .interactiveDismissDisabled()
        }
        .sheet(item: $preview) { selection in
            PhotoPreview(urls: model.outputs, initialIndex: selection.index)
        }
        .sheet(isPresented: $showsHelp) { shortcutsHelp }
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
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44)).accessibilityHidden(true).padding(.top, 24)
            Text("The whole photo.\nA new fit.").font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Add white space to fit your photos into a new shape. No cropping or stretching.")
                .foregroundStyle(.secondary)
            Button("Select Photos") { showsPicker = true }
                .buttonStyle(FitPrimaryButtonStyle()).disabled(model.isBusy)
            Text("Choose 1–20 still images. Your originals stay unchanged. Processing happens on this iPhone.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.inputs.count) selected").font(.headline)
                Spacer()
                Button("Change") { showsPicker = true }.frame(minHeight: 44)
                    .accessibilityLabel("Change photo selection").disabled(model.isBusy)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(model.inputs.enumerated()), id: \.element) { index, url in
                        VStack(spacing: 4) {
                            FileThumbnail(url: url, maximumPixelSize: 192).frame(width: 88, height: 88)
                                .overlay(Rectangle().stroke(.gray.opacity(0.25)))
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .ignore)
                            .accessibilityLabel("Selected photo \(index + 1) of \(model.inputs.count)")
                    }
                }
            }
            RatioChooser(selection: $model.ratio).disabled(model.isBusy)
            Button("Convert \(model.inputs.count) \(model.inputs.count == 1 ? "Photo" : "Photos")") { model.convert() }
                .buttonStyle(FitPrimaryButtonStyle()).disabled(model.isBusy)
            Text("White padding · JPEG output · Nothing saved automatically")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(model.outputs.count) ready · \(model.ratio.title)").font(.title2.bold())
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
            Text("Save All adds new copies to Photos. Share lets you choose a destination that accepts this batch. Originals are never replaced.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var resultActions: some View {
        VStack(spacing: 8) {
            Button { showsShare = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .buttonStyle(FitPrimaryButtonStyle()).disabled(model.isBusy)
                .accessibilityLabel("Share all \(model.outputs.count) photos")
            Button { model.saveAll() } label: {
                Label(model.savedToPhotos ? "Saved to Photos" : model.work == .saving ? "Saving…" : "Save All",
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
                ProgressView("Saving all photos…")
                Text("Keep Fit Photos open until saving finishes.").font(.footnote)
            } else {
                ProgressView(value: Double(model.completed), total: Double(max(1, model.total)))
                Text(model.isCancelling ? "Cancelling…" : "\(model.work == .importing ? "Loading" : "Converting") \(min(model.completed + 1, model.total)) of \(model.total)")
                    .font(.headline)
                Button("Cancel") { model.cancel() }.disabled(model.isCancelling).frame(minHeight: 44)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var shortcutsHelp: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Clear. Fast. Trustworthy.").font(.title2.bold())
                    Text("Fit Photos works on this device. Choose photos, fit the whole image into a white canvas, and decide whether to save or share.")
                    Text("Use it with Shortcuts too").font(.headline)
                    Text("The Fit Photos to 4:5 action is still available in Shortcuts. It returns temporary images to the next action, without saving them automatically. You can build and edit your own workflow.")
                    Button("Open Shortcuts") {
                        if let url = URL(string: "shortcuts://") {
                            openURL(url) { accepted in
                                if !accepted {
                                    showsHelp = false
                                    model.message = FitPhotosMessage(title: "Unable to open Shortcuts", text: "Install or open Apple's Shortcuts app, then add Fit Photos to 4:5.")
                                }
                            }
                        }
                    }.buttonStyle(.bordered).controlSize(.large)
                    Text("Shortcuts is optional. You can select, convert, save, and share directly in this app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .navigationTitle("About Fit Photos").navigationBarTitleDisplayMode(.inline)
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
