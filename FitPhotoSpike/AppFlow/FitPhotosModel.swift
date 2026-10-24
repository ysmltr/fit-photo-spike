import Combine
import CoreGraphics
import Foundation
import PhotosUI

struct FitPhotosMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    var offersSettings = false
}

/// The whole flow: choose photos, pick a size, edit, then save or share.
/// Holds URLs and small edit values, never a full-resolution decoded batch.
/// Background workers own file loading/rendering; publication and operation
/// sequencing stay here.
@MainActor
final class FitPhotosModel: ObservableObject {
    enum Screen: Equatable { case start, size, editor, export }
    enum Work: Equatable { case idle, importing, converting, saving }

    @Published private(set) var screen: Screen = .start
    @Published private(set) var inputs: [URL] = []
    /// Upright pixel size of each input, in the same order.
    @Published private(set) var sourceSizes: [CGSize] = []
    /// One edit per input, in the same order.
    @Published private(set) var edits: [PhotoEdit] = []
    @Published private(set) var ratio: OutputRatio = .fourFive
    @Published private(set) var currentIndex = 0
    /// Fit, Fill and background changes go to every photo while this is on.
    @Published var applyToAll = true
    @Published private(set) var outputs: [URL] = []
    @Published private(set) var work: Work = .idle
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var isCancelling = false
    @Published private(set) var savedToPhotos = false
    /// Once the editor has opened for a batch, the size screen returns to it.
    @Published private(set) var hasOpenedEditor = false
    /// Goes up when a save is a good moment to ask for an App Store rating.
    @Published private(set) var reviewRequests = 0
    @Published var message: FitPhotosMessage?

    private var files: AppSessionFiles?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var renderedSnapshot: RenderSnapshot?
    private let preferences = EditorPreferences()

    /// What the current outputs were rendered from.
    private struct RenderSnapshot: Equatable {
        let inputs: [URL]
        let edits: [PhotoEdit]
        let ratio: OutputRatio
    }

    var session: AppSessionFiles? { files }
    var isBusy: Bool { work != .idle }
    var canCancel: Bool { work == .importing || work == .converting }
    var photoCount: Int { inputs.count }
    var canvasSize: CGSize { ratio.canvasSize }
    var currentEdit: PhotoEdit { edit(at: currentIndex) }
    var currentSourceSize: CGSize { sourceSize(at: currentIndex) }
    var currentIsFit: Bool { isFit(currentEdit) }
    var currentIsFill: Bool { isFill(currentEdit, source: currentSourceSize, canvas: canvasSize) }

    init() {
        AppSessionFiles.prepareForAppLaunch()
        ratio = preferences.ratio
    }

    deinit {
        operation?.cancel()
    }

    func edit(at index: Int) -> PhotoEdit {
        edits.indices.contains(index) ? edits[index] : .standard
    }

    func sourceSize(at index: Int) -> CGSize {
        sourceSizes.indices.contains(index) ? sourceSizes[index] : CGSize(width: 1, height: 1)
    }

    // MARK: Choosing photos

    func receiveSelection(_ selection: [PHPickerResult]) {
        // Cancelling the picker keeps the current state.
        guard !selection.isEmpty, !isBusy else { return }
        guard selection.count <= AppBatchProcessor.maximumImageCount else {
            message = FitPhotosMessage(title: "Too many photos",
                text: "Choose between 1 and \(AppBatchProcessor.maximumImageCount) still images.")
            return
        }
        let pending: AppSessionFiles
        do { pending = try AppSessionFiles() }
        catch {
            message = FitPhotosMessage(title: "Unable to prepare photos", text: "Temporary storage is unavailable. Check available space and try again.")
            return
        }
        begin(.importing, count: selection.count)
        let requestID = operationID
        operation = Task { [weak self] in
            do {
                let loaded = try await PickerFileLoader().load(selection, into: pending.inputDirectory) { [weak self] done, count in
                    self?.updateProgress(done, count, for: .importing, id: requestID)
                }
                try Task.checkCancellation()
                self?.adopt(loaded, files: pending)
            } catch is CancellationError {
                pending.removeAll()
            } catch {
                pending.removeAll()
                self?.message = FitPhotosMessage(title: "Unable to load selection", text:
                    (error as? PhotoSelectionError)?.errorDescription
                    ?? "The selected photos could not be loaded. Try locally available JPEG, HEIC, or PNG still images.")
            }
            self?.finish()
        }
    }

    private func adopt(_ loaded: PickerLoadResult, files pending: AppSessionFiles) {
        files = pending
        inputs = loaded.urls
        sourceSizes = loaded.sizes
        let background = preferences.background
        edits = loaded.urls.map { _ in PhotoEdit(background: background) }
        currentIndex = 0
        clearOutputs()
        hasOpenedEditor = false
        screen = .size
        if !loaded.skipped.isEmpty {
            message = FitPhotosModel.skippedMessage(loaded.skipped, kept: loaded.urls.count)
        }
    }

    // MARK: Size

    func chooseRatio(_ newRatio: OutputRatio) {
        guard newRatio != ratio, !isBusy else { return }
        let oldCanvas = canvasSize
        // Photos set to Fill keep covering the new shape.
        edits = edits.enumerated().map { index, edit in
            var edit = edit
            let source = sourceSize(at: index)
            if !isFit(edit) && isFill(edit, source: source, canvas: oldCanvas) {
                edit.scale = PlacementGeometry.fillScale(source: source, canvas: newRatio.canvasSize)
            }
            return edit
        }
        ratio = newRatio
        preferences.ratio = newRatio
    }

    func openEditor() {
        guard !inputs.isEmpty, !isBusy else { return }
        hasOpenedEditor = true
        screen = .editor
    }

    func openSizes() {
        guard !isBusy else { return }
        screen = .size
    }

    // MARK: Editing

    func select(_ index: Int) {
        guard inputs.indices.contains(index) else { return }
        currentIndex = index
    }

    /// Fit shows the whole photo; Fill covers the canvas.
    func applyFit(fill: Bool) {
        let canvas = canvasSize
        updateEdits(all: applyToAll) { edit, source in
            edit.scale = fill ? PlacementGeometry.fillScale(source: source, canvas: canvas) : 1
            edit.offsetX = 0
            edit.offsetY = 0
        }
    }

    func setBackground(_ background: CanvasBackground) {
        updateEdits(all: applyToAll) { edit, _ in edit.background = background }
        preferences.background = background
    }

    /// Pinch, drag and the size slider adjust only the photo being edited,
    /// because every photo needs its own framing.
    func setPlacement(scale: Double, offsetX: Double, offsetY: Double) {
        updateEdits(all: false) { edit, _ in
            edit.scale = scale.clamped(to: PhotoEdit.scaleRange)
            edit.offsetX = offsetX.clamped(to: PhotoEdit.offsetRange)
            edit.offsetY = offsetY.clamped(to: PhotoEdit.offsetRange)
        }
    }

    func setScale(_ scale: Double) {
        let edit = currentEdit
        setPlacement(scale: scale, offsetX: edit.offsetX, offsetY: edit.offsetY)
    }

    func resetCurrentPosition() {
        setPlacement(scale: 1, offsetX: 0, offsetY: 0)
    }

    private func updateEdits(all: Bool, _ change: (inout PhotoEdit, CGSize) -> Void) {
        var updated = edits
        let indices = all ? Array(updated.indices) : (updated.indices.contains(currentIndex) ? [currentIndex] : [])
        for index in indices { change(&updated[index], sourceSize(at: index)) }
        guard updated != edits else { return }
        edits = updated
    }

    private func isFit(_ edit: PhotoEdit) -> Bool {
        abs(edit.scale - 1) < 0.001 && abs(edit.offsetX) < 0.0005 && abs(edit.offsetY) < 0.0005
    }

    private func isFill(_ edit: PhotoEdit, source: CGSize, canvas: CGSize) -> Bool {
        abs(edit.scale - PlacementGeometry.fillScale(source: source, canvas: canvas)) < 0.001
            && abs(edit.offsetX) < 0.0005 && abs(edit.offsetY) < 0.0005
    }

    // MARK: Export

    /// Renders every photo with its own edit. Results that are still current
    /// are reused, so going back and forth without changes is instant.
    func openExport() {
        guard !isBusy, !inputs.isEmpty, let files else { return }
        screen = .export
        let snapshot = RenderSnapshot(inputs: inputs, edits: edits, ratio: ratio)
        guard snapshot != renderedSnapshot || outputs.count != inputs.count else { return }
        clearOutputs()
        begin(.converting, count: snapshot.inputs.count)
        let requestID = operationID
        operation = Task { [weak self] in
            // The worker must settle before its session can be deleted.
            defer { withExtendedLifetime(files) {} }
            do {
                let urls = try await AppBatchProcessor().process(
                    snapshot.inputs, edits: snapshot.edits, ratio: snapshot.ratio,
                    outputDirectory: files.outputDirectory
                ) { @MainActor [weak self] done, count in
                    self?.updateProgress(done, count, for: .converting, id: requestID)
                }
                try Task.checkCancellation()
                self?.outputs = urls
                self?.renderedSnapshot = snapshot
                self?.savedToPhotos = false
            } catch is CancellationError {
                files.removeOutputs()
                self?.screen = .editor
            } catch {
                files.removeOutputs()
                self?.message = FitPhotosMessage(title: "Unable to prepare photos", text:
                    (error as? AppBatchProcessingError)?.errorDescription
                    ?? "The photos could not be prepared. Nothing was saved. Check available storage and try again.")
                self?.screen = .editor
            }
            self?.finish()
        }
    }

    /// While photos are being prepared this cancels, and the editor opens once
    /// the work has stopped.
    func backToEditor() {
        if work == .converting {
            cancel()
        } else if !isBusy {
            screen = .editor
        }
    }

    func saveAll() {
        guard !isBusy, !outputs.isEmpty, !savedToPhotos, let files else { return }
        let urls = outputs
        begin(.saving, count: urls.count)
        operation = Task { [weak self] in
            // A submitted PhotoKit transaction cannot be cancelled. Keep its
            // files alive until the transaction settles, even if the view exits.
            defer { withExtendedLifetime(files) {} }
            do {
                try await PhotoLibrarySaver().save(urls)
                self?.savedToPhotos = true
                self?.countSuccessfulSave()
            } catch {
                let saveError = error as? PhotoLibrarySaveError
                self?.message = FitPhotosMessage(title: "Unable to save photos",
                    text: saveError?.errorDescription ?? "The photos could not be saved. Your converted files are still available to share or retry.",
                    offersSettings: saveError == .permissionDenied)
            }
            self?.finish()
        }
    }

    func cancel() {
        guard canCancel else { return }
        isCancelling = true
        operation?.cancel()
    }

    func startOver() {
        guard !isBusy else { return }
        inputs = []
        sourceSizes = []
        edits = []
        currentIndex = 0
        clearOutputs()
        files = nil
        hasOpenedEditor = false
        message = nil
        screen = .start
    }

    /// Asks after the 3rd and 10th saved batch. iOS decides whether the
    /// prompt actually appears and limits how often.
    private func countSuccessfulSave() {
        let saves = preferences.successfulSaves + 1
        preferences.successfulSaves = saves
        if saves == 3 || saves == 10 { reviewRequests += 1 }
    }

    private func clearOutputs() {
        outputs = []
        renderedSnapshot = nil
        files?.removeOutputs()
        savedToPhotos = false
    }

    /// Positions follow the picker order the user saw, e.g. "Photos 3 and 7".
    private static func skippedMessage(_ skipped: [Int], kept: Int) -> FitPhotosMessage {
        let positions = ListFormatter.localizedString(byJoining: skipped.map(String.init))
        let title = skipped.count == 1 ? "1 photo was skipped" : "\(skipped.count) photos were skipped"
        let which = skipped.count == 1 ? "Photo \(positions) couldn't be opened." : "Photos \(positions) couldn't be opened."
        let ready = kept == 1 ? "The other photo is ready." : "The other \(kept) are ready."
        return FitPhotosMessage(title: title, text: which + " " + ready
            + " Photos stored in iCloud need an internet connection, and animated images aren't supported.")
    }

    private func begin(_ work: Work, count: Int) {
        operationID = UUID()
        self.work = work
        total = count
        completed = 0
        isCancelling = false
        message = nil
    }

    private func updateProgress(_ done: Int, _ count: Int, for expectedWork: Work, id: UUID) {
        guard operationID == id, work == expectedWork, count == total else { return }
        completed = max(completed, min(done, total))
    }

    private func finish() {
        work = .idle
        operation = nil
        isCancelling = false
    }
}
