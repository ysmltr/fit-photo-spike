import Foundation
import PhotosUI
import UniformTypeIdentifiers

enum PhotoSelectionError: LocalizedError, Equatable, Sendable {
    case invalidCount
    case preparationFailed
    case unavailableImage(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCount:
            return "Select between 1 and 20 photos."
        case .preparationFailed:
            return "These photos couldn't be prepared. Check available storage and try again."
        case .unavailableImage(let number):
            return "Photo \(number) couldn't be opened. If it is stored in iCloud, download it in Photos and try again."
        }
    }
}

/// Loads one provider at a time, retaining file URLs instead of a batch of
/// decoded images. This never fetches PHAssets or attempts to identify them.
@MainActor
struct PickerFileLoader {
    func load(_ results: [PHPickerResult], into directory: URL,
              progress: @escaping @MainActor (Int, Int) -> Void) async throws -> [URL] {
        guard (1...20).contains(results.count) else { throw PhotoSelectionError.invalidCount }
        try Task.checkCancellation()
        guard directory.isFileURL else { throw PhotoSelectionError.preparationFailed }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PhotoSelectionError.preparationFailed
        }

        var ownedURLs: [URL] = []
        var succeeded = false
        defer {
            if !succeeded {
                for url in ownedURLs { try? FileManager.default.removeItem(at: url) }
            }
        }
        progress(0, results.count)
        for (index, result) in results.enumerated() {
            try Task.checkCancellation()
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                throw PhotoSelectionError.unavailableImage(index + 1)
            }
            // ImageIO detects the actual format from bytes; do not trust or
            // reuse filenames supplied by an external provider.
            let destination = directory.appendingPathComponent("selected-\(UUID().uuidString).image")
            let operation = PickerFileCopyOperation(destination: destination, imageNumber: index + 1)
            _ = try await operation.load { completion in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier,
                                                completionHandler: completion)
            }
            // Ownership begins only after our copy succeeds. A collision must
            // never make cleanup delete a pre-existing file.
            ownedURLs.append(destination)
            try Task.checkCancellation()
            progress(index + 1, results.count)
        }
        try Task.checkCancellation()
        succeeded = true
        return ownedURLs
    }
}

/// Bridges the provider callback's short file lifetime into structured
/// cancellation. The lock protects all mutable state, including the file copy:
/// cancellation cannot return and clean up while a late callback recreates it.
/// No async work is awaited under the lock.
final class PickerFileCopyOperation: @unchecked Sendable {
    typealias Completion = @Sendable (URL?, (any Error)?) -> Void

    private let lock = NSLock()
    private let destination: URL
    private let imageNumber: Int
    private var continuation: CheckedContinuation<URL, any Error>?
    private var providerProgress: Progress?
    private var finished = false

    init(destination: URL, imageNumber: Int) {
        self.destination = destination
        self.imageNumber = imageNumber
    }

    // Register the UI-owned provider on its caller's actor. Its Sendable
    // completion still copies on the provider callback queue under the lock.
    @MainActor
    func load(start: @MainActor (@escaping Completion) -> Progress) async throws -> URL {
        try await withTaskCancellationHandler {
            let copiedURL: URL = try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }
                let progress = start { [weak self] url, error in self?.complete(url: url, error: error) }
                install(progress)
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: copiedURL)
                throw CancellationError()
            }
            return copiedURL
        } onCancel: {
            self.cancel()
        }
    }

    private func install(_ continuation: CheckedContinuation<URL, any Error>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func install(_ progress: Progress) {
        lock.lock()
        let shouldCancel = finished
        if !finished { providerProgress = progress }
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    private func complete(url: URL?, error: (any Error)?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let result: Result<URL, any Error>
        if error == nil, let url, url.isFileURL,
           url.standardizedFileURL != destination.standardizedFileURL,
           !FileManager.default.fileExists(atPath: destination.path) {
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Apple deletes its temporary representation when this callback
                // returns, so copy synchronously before resuming the caller.
                try FileManager.default.copyItem(at: url, to: destination)
                result = .success(destination)
            } catch {
                // The destination did not exist before our copy attempt. Only
                // remove a partial app-owned copy, never the provider's file.
                try? FileManager.default.removeItem(at: destination)
                result = .failure(PhotoSelectionError.unavailableImage(imageNumber))
            }
        } else {
            result = .failure(PhotoSelectionError.unavailableImage(imageNumber))
        }
        finished = true
        let pending = continuation
        continuation = nil
        providerProgress = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = continuation
        let progress = providerProgress
        continuation = nil
        providerProgress = nil
        lock.unlock()
        progress?.cancel()
        pending?.resume(throwing: CancellationError())
    }
}
