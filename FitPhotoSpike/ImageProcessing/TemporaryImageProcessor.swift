import AppIntents
import Foundation
import UniformTypeIdentifiers

enum TemporaryImageProcessingError: LocalizedError, Equatable, Sendable {
    case invalidImageCount(Int)
    case nonLocalFile

    var errorDescription: String? {
        switch self {
        case .invalidImageCount(let count):
            return "Choose between 1 and 20 images. This request contains \(count)."
        case .nonLocalFile:
            return "The image must be supplied as a local file. Download it in Shortcuts first."
        }
    }
}

/// Owns only this invocation's generated paths. Successful outputs survive
/// perform() so the next Shortcuts action can read them. No age-based sweep
/// can delete files that another running workflow might still be consuming.
struct TemporaryImageProcessor: Sendable {
    static let maximumImageCount = 20

    private let outputDirectory: URL
    private let render: @Sendable (URL, URL) throws -> Void

    init(outputDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitPhotosOutputs", isDirectory: true),
         render: @escaping @Sendable (URL, URL) throws -> Void = { inputURL, outputURL in
             _ = try ImageRenderer().render(inputURL: inputURL, outputURL: outputURL)
         }) {
        self.outputDirectory = outputDirectory
        self.render = render
    }

    func process(_ inputs: [IntentFile]) async throws -> [IntentFile] {
        guard (1...Self.maximumImageCount).contains(inputs.count) else {
            throw TemporaryImageProcessingError.invalidImageCount(inputs.count)
        }
        try Task.checkCancellation()
        // Synchronous ImageIO/Core Image work never runs on the caller's main
        // actor. Forward cancellation explicitly to this detached worker.
        let worker = Task.detached(priority: .userInitiated) {
            try self.processSequentially(inputs)
        }
        return try await withTaskCancellationHandler {
            let outputs = try await worker.value
            // Covers cancellation after the worker finishes but before handoff.
            if Task.isCancelled {
                Self.removeGeneratedOutputs(outputs)
                throw CancellationError()
            }
            return outputs
        } onCancel: {
            worker.cancel()
        }
    }

    private func processSequentially(_ inputs: [IntentFile]) throws -> [IntentFile] {
        try Task.checkCancellation()
        guard outputDirectory.isFileURL else {
            throw TemporaryImageProcessingError.nonLocalFile
        }
        let files = FileManager.default
        try files.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var ownedURLs: [URL] = []
        var outputs: [IntentFile] = []
        var succeeded = false
        defer {
            if !succeeded {
                // Includes a renderer that failed after writing part of a file.
                for url in ownedURLs { try? files.removeItem(at: url) }
            }
        }

        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let filename = String(format: "fit-4x5-%02d-", index + 1)
                + UUID().uuidString + ".jpeg"
            let outputURL = outputDirectory.appendingPathComponent(filename)
            ownedURLs.append(outputURL)
            try autoreleasepool {
                if let inputURL = input.fileURL {
                    guard inputURL.isFileURL else {
                        throw TemporaryImageProcessingError.nonLocalFile
                    }
                    // Some providers supply security-scoped URLs. A false
                    // result is normal for an already accessible sandbox file.
                    let scopedAccess = inputURL.startAccessingSecurityScopedResource()
                    defer { if scopedAccess { inputURL.stopAccessingSecurityScopedResource() } }
                    try render(inputURL, outputURL)
                } else {
                    // Stage only the current data-backed input, without
                    // retaining extra Data/decoded bitmaps for the whole batch.
                    let scratch = outputDirectory.appendingPathComponent(
                        ".input-\(UUID().uuidString).tmp")
                    defer { try? files.removeItem(at: scratch) }
                    try input.data.write(to: scratch, options: .atomic)
                    try Task.checkCancellation()
                    try render(scratch, outputURL)
                }
            }
            try Task.checkCancellation()
            var output = IntentFile(fileURL: outputURL, filename: filename, type: .jpeg)
            // Public since iOS 16; the deployment target is iOS 18.
            // This requests cleanup when the entire Shortcut finishes, not
            // when this function returns. Never apply it to caller-owned input.
            output.removedOnCompletion = true
            outputs.append(output)
        }
        try Task.checkCancellation()
        succeeded = true
        return outputs
    }

    private static func removeGeneratedOutputs(_ outputs: [IntentFile]) {
        for output in outputs {
            if let url = output.fileURL { try? FileManager.default.removeItem(at: url) }
        }
    }
}
