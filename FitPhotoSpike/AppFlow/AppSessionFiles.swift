import Foundation

/// Owns staged picker copies and converted files for one foreground batch.
/// Separate from the intent's FitPhotosOutputs, which Shortcuts owns.
struct AppSessionFiles: Sendable {
    let directory: URL
    var inputDirectory: URL { directory.appendingPathComponent("Inputs", isDirectory: true) }
    var outputDirectory: URL { directory.appendingPathComponent("Outputs", isDirectory: true) }

    static var appRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FitPhotosAppSessions", isDirectory: true)
    }

    init(root: URL = AppSessionFiles.appRoot) throws {
        guard root.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        directory = root.appendingPathComponent("batch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
    }

    func removeOutputs() { try? FileManager.default.removeItem(at: outputDirectory) }
    func removeAll() { try? FileManager.default.removeItem(at: directory) }

    /// Once per process, before any UI batch exists. Never on backgrounding,
    /// while sharing, or from the intent. OS cleanup also applies to temp files.
    @MainActor private static var preparedForLaunch = false
    @MainActor static func prepareForAppLaunch() {
        guard !preparedForLaunch else { return }
        preparedForLaunch = true
        removeAbandonedBatches(in: appRoot)
    }

    static func removeAbandonedBatches(in root: URL) {
        guard root.isFileURL,
              let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else { return }
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix("batch-"), UUID(uuidString: String(name.dropFirst(6))) != nil,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}
