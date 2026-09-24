import Foundation
import Photos

enum PhotoLibrarySaveError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case permissionRestricted
    case invalidOutput
    case notEnoughSpace
    case failed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Allow Fit Photos to add photos in Settings, or use Share to save them elsewhere."
        case .permissionRestricted:
            return "This device restricts adding photos. You can use Share to save the converted images elsewhere."
        case .invalidOutput:
            return "The converted images are no longer available. Convert your photos again."
        case .notEnoughSpace:
            return "Photos couldn't save the images because there isn't enough storage. Free some space and try again."
        case .failed:
            return "Photos couldn't save this batch. Your converted images are still available to share."
        }
    }

    static func category(for error: any Error) -> PhotoLibrarySaveError {
        let value = error as NSError
        guard value.domain == PHPhotosError.errorDomain else { return .failed }
        switch value.code {
        case PHPhotosError.Code.notEnoughSpace.rawValue: return .notEnoughSpace
        case PHPhotosError.Code.accessUserDenied.rawValue: return .permissionDenied
        case PHPhotosError.Code.accessRestricted.rawValue: return .permissionRestricted
        default: return .failed
        }
    }
}

/// Called only by the explicit Save All control. Authorization and transaction
/// closures allow synthetic tests without accessing a real photo library.
@MainActor
struct PhotoLibrarySaver {
    private let authorize: @MainActor () async -> PHAuthorizationStatus
    private let saveBatch: @MainActor ([URL]) async throws -> Void

    init(authorize: @escaping @MainActor () async -> PHAuthorizationStatus = {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }, saveBatch: @escaping @MainActor ([URL]) async throws -> Void = { urls in
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                // Nonoptional creation avoids silently skipping one input.
                // PhotoKit validates all resources in the single transaction.
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            }
        }
    }) {
        self.authorize = authorize
        self.saveBatch = saveBatch
    }

    func save(_ urls: [URL]) async throws {
        guard (1...20).contains(urls.count), urls.allSatisfy({
            $0.isFileURL
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileManager.default.isReadableFile(atPath: $0.path)
        }) else { throw PhotoLibrarySaveError.invalidOutput }
        try Task.checkCancellation()
        switch await authorize() {
        case .authorized: break
        case .restricted: throw PhotoLibrarySaveError.permissionRestricted
        case .denied, .limited, .notDetermined: throw PhotoLibrarySaveError.permissionDenied
        @unknown default: throw PhotoLibrarySaveError.permissionDenied
        }
        try Task.checkCancellation()
        do {
            // A submitted PhotoKit transaction cannot be cancelled. Await its
            // actual result; do not report cancellation after a successful save.
            try await saveBatch(urls)
        } catch let error as PhotoLibrarySaveError {
            throw error
        } catch {
            // Never expose PhotoKit error payloads, paths, or identifiers.
            throw PhotoLibrarySaveError.category(for: error)
        }
    }
}
