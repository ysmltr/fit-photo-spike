import Foundation

enum AppImageFailureReason: Equatable, Sendable {
    case unsupported
    case unreadable
    case storage
    case conversion

    var message: String {
        switch self {
        case .unsupported: return "Choose JPEG, HEIC, or PNG still images. Animated images are not supported."
        case .unreadable: return "The image could not be read. Select it again and retry."
        case .storage: return "The result could not be written. Check available storage and retry."
        case .conversion: return "The image could not be converted. Select another still image and retry."
        }
    }
}

enum AppBatchProcessingError: LocalizedError, Equatable, Sendable {
    case invalidImageCount(Int)
    case outputUnavailable
    case nonLocalInput(index: Int, total: Int)
    case itemFailed(index: Int, total: Int, reason: AppImageFailureReason)

    var errorDescription: String? {
        switch self {
        case .invalidImageCount(let count):
            return "Choose between 1 and 20 photos. This selection contains \(count)."
        case .outputUnavailable:
            return "Temporary storage is unavailable. Check available storage and try again."
        case .nonLocalInput(let index, let total):
            return "Photo \(index) of \(total) is not available as a local image. Select it again and retry."
        case .itemFailed(let index, let total, let reason):
            return "Photo \(index) of \(total) could not be converted. \(reason.message) No results were kept."
        }
    }
}

/// The app owns the supplied output directory and the returned files' lifetime.
/// Rendering is sequential in one structured child task, with at most one decoded
/// input in flight. Failure/cancellation deletes only this call's outputs.
/// Inputs are never deleted, including when they reside in outputDirectory.
struct AppBatchProcessor: Sendable {
    static let maximumImageCount = 20
    private let render: @Sendable (URL, URL, OutputRatio) throws -> Void

    init(render: @escaping @Sendable (URL, URL, OutputRatio) throws -> Void = { input, output, ratio in
        _ = try ImageRenderer().render(inputURL: input, outputURL: output, ratio: ratio)
    }) {
        self.render = render
    }

    func process(_ inputs: [URL], ratio: OutputRatio, outputDirectory: URL,
                 progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [URL] {
        guard (1...Self.maximumImageCount).contains(inputs.count) else {
            throw AppBatchProcessingError.invalidImageCount(inputs.count)
        }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: [URL].self) { group in
            // Task-group children do not inherit MainActor isolation. The
            // group joins its only child and propagates caller cancellation.
            group.addTask(priority: .userInitiated) {
                try await self.processSequentially(inputs, ratio: ratio, outputDirectory: outputDirectory,
                                                   progress: progress)
            }
            for try await outputs in group {
                if Task.isCancelled {
                    Self.removeOutputs(outputs)
                    throw CancellationError()
                }
                return outputs
            }
            throw CancellationError()
        }
    }

    private func processSequentially(_ inputs: [URL], ratio: OutputRatio, outputDirectory: URL,
                                     progress: @Sendable (Int, Int) async -> Void) async throws -> [URL] {
        try Task.checkCancellation()
        guard outputDirectory.isFileURL else { throw AppBatchProcessingError.outputUnavailable }
        // Reject nonlocal inputs before touching any output. The processor
        // never initiates a network request or resolves a remote image URL.
        for (index, input) in inputs.enumerated() where !input.isFileURL {
            throw AppBatchProcessingError.nonLocalInput(index: index + 1, total: inputs.count)
        }
        let files = FileManager.default
        do {
            try files.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw AppBatchProcessingError.outputUnavailable
        }
        let sources = Set(inputs.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        var ownedOutputs: [URL] = []
        var succeeded = false
        defer { if !succeeded { Self.removeOutputs(ownedOutputs) } }
        await progress(0, inputs.count)

        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let filename = String(format: "fit-%@-%02d-", ratio.title.replacingOccurrences(of: ":", with: "x"), index + 1)
                + UUID().uuidString + ".jpeg"
            let output = outputDirectory.appendingPathComponent(filename)
            guard !sources.contains(output.resolvingSymlinksInPath().standardizedFileURL),
                  !files.fileExists(atPath: output.path) else {
                throw AppBatchProcessingError.outputUnavailable
            }
            ownedOutputs.append(output)
            do {
                try autoreleasepool {
                    let scopedAccess = input.startAccessingSecurityScopedResource()
                    defer { if scopedAccess { input.stopAccessingSecurityScopedResource() } }
                    try render(input, output, ratio)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // Never surface URL paths or arbitrary framework error text.
                throw AppBatchProcessingError.itemFailed(index: index + 1, total: inputs.count,
                                                         reason: Self.failureReason(error))
            }
            try Task.checkCancellation()
            await progress(index + 1, inputs.count)
        }
        try Task.checkCancellation()
        succeeded = true
        return ownedOutputs
    }

    private static func failureReason(_ error: Error) -> AppImageFailureReason {
        guard let error = error as? ImageRenderingError else { return .conversion }
        switch error {
        case .unsupportedFormat, .multipleImages: return .unsupported
        case .unreadableImage, .invalidDimensions, .invalidOrientation: return .unreadable
        case .destinationFailed: return .storage
        case .renderFailed, .sameInputAndOutput: return .conversion
        }
    }

    private static func removeOutputs(_ outputs: [URL]) {
        for output in outputs { try? FileManager.default.removeItem(at: output) }
    }
}
