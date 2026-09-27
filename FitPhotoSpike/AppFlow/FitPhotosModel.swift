import Combine
import Foundation
import PhotosUI

struct FitPhotosMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    var offersSettings = false
}

/// Holds URLs, never a full-resolution decoded batch. Background workers own
/// file loading/rendering; publication and operation sequencing stay here.
@MainActor
final class FitPhotosModel: ObservableObject {
    enum Work: Equatable { case idle, importing, converting, saving }
    @Published private(set) var inputs: [URL] = []
    @Published private(set) var outputs: [URL] = []
    @Published var ratio: OutputRatio = .fourFive
    @Published private(set) var work: Work = .idle
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var isCancelling = false
    @Published private(set) var savedToPhotos = false
    @Published var message: FitPhotosMessage?
    private var files: AppSessionFiles?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    var session: AppSessionFiles? { files }
    var isBusy: Bool { work != .idle }
    var canCancel: Bool { work == .importing || work == .converting }

    init() { AppSessionFiles.prepareForAppLaunch() }

    deinit {
        operation?.cancel()
    }

    func receiveSelection(_ selection: [PHPickerResult]) {
        // Cancelling the picker keeps the previous selection.
        guard !selection.isEmpty, !isBusy else { return }
        guard selection.count <= 20 else {
            message = FitPhotosMessage(title: "Too many photos", text: "Choose between 1 and 20 still images.")
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
                let urls = try await PickerFileLoader().load(selection, into: pending.inputDirectory) { [weak self] done, count in
                    self?.updateProgress(done, count, for: .importing, id: requestID)
                }
                try Task.checkCancellation()
                self?.files = pending
                self?.inputs = urls
                self?.outputs = []
                self?.savedToPhotos = false
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

    func convert() {
        guard !isBusy, outputs.isEmpty, let files else { return }
        guard (1...20).contains(inputs.count) else {
            message = FitPhotosMessage(title: "Select photos first", text: "Choose between 1 and 20 still images.")
            return
        }
        let selectedInputs = inputs
        let selectedRatio = ratio
        begin(.converting, count: selectedInputs.count)
        let requestID = operationID
        operation = Task { [weak self] in
            // The worker must settle before its session can be deleted.
            defer { withExtendedLifetime(files) {} }
            do {
                let urls = try await AppBatchProcessor().process(
                    selectedInputs, ratio: selectedRatio, outputDirectory: files.outputDirectory
                ) { @MainActor [weak self] done, count in
                    self?.updateProgress(done, count, for: .converting, id: requestID)
                }
                try Task.checkCancellation()
                self?.outputs = urls
                self?.savedToPhotos = false
            } catch is CancellationError {
                files.removeOutputs()
            } catch {
                files.removeOutputs()
                self?.message = FitPhotosMessage(title: "Unable to convert batch", text:
                    (error as? AppBatchProcessingError)?.errorDescription
                    ?? "The batch could not be converted. No photos were saved. Check the selected files and available storage.")
            }
            self?.finish()
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

    func changeRatio() {
        guard !isBusy else { return }
        outputs = []
        files?.removeOutputs()
        savedToPhotos = false
    }

    func startOver() {
        guard !isBusy else { return }
        inputs = []
        outputs = []
        files = nil
        savedToPhotos = false
        message = nil
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
