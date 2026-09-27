import Foundation
import XCTest
@testable import FitPhotoSpike

/// Exercises file-lifetime/cancellation behavior using synthetic provider
/// callbacks, without opening Photos or retaining image bitmaps.
final class PickerFileLoaderTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitPhotosPickerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("provider.image")
        destination = directory.appendingPathComponent("owned.image")
        try Data([1, 2, 3, 4]).write(to: source)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    func testCopiesBeforeProviderDeletesItsTemporaryFile() async throws {
        let operation = PickerFileCopyOperation(destination: destination, imageNumber: 1)
        let output = try await operation.load { completion in
            XCTAssertTrue(Thread.isMainThread, "Provider registration must stay on MainActor")
            completion(self.source, nil)
            try? FileManager.default.removeItem(at: self.source)
            return Progress(totalUnitCount: 1)
        }
        XCTAssertEqual(output, destination)
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3, 4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testLateCallbackAfterCancellationDoesNotRecreateOutput() async throws {
        let callback = SyntheticPickerCallback()
        let started = XCTestExpectation(description: "provider started")
        let operation = PickerFileCopyOperation(destination: destination, imageNumber: 1)
        let task = Task {
            try await operation.load { completion in
                callback.store(completion)
                started.fulfill()
                return Progress(totalUnitCount: 1)
            }
        }
        defer { task.cancel() }
        // The static waiter keeps the timeout without sending this
        // actor-isolated XCTestCase to a nonisolated async method.
        let registration = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(registration, .completed)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        callback.invoke(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testRetainedProviderCallbackDoesNotRetainFinishedCopyOperation() async throws {
        let callback = SyntheticPickerCallback()
        var operation: PickerFileCopyOperation? = PickerFileCopyOperation(destination: destination, imageNumber: 1)
        weak var weakOperation = operation
        let output = try await operation?.load { completion in
            callback.store(completion)
            completion(self.source, nil)
            return Progress(totalUnitCount: 1)
        }
        XCTAssertEqual(output, destination)
        operation = nil
        XCTAssertNil(weakOperation)
        // A provider retaining or repeating its callback cannot keep completed
        // bridge state alive or overwrite the app-owned result.
        callback.invoke(source)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3, 4]))
    }

    @MainActor
    func testDuplicateCallbackDoesNotResumeTwiceOrOverwriteOutput() async throws {
        let operation = PickerFileCopyOperation(destination: destination, imageNumber: 1)
        let output = try await operation.load { completion in
            completion(self.source, nil)
            completion(nil, NSError(domain: "synthetic", code: 1))
            return Progress(totalUnitCount: 1)
        }
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3, 4]))
    }

    @MainActor
    func testCancellationBeforeStartDoesNotInvokeProvider() async throws {
        let operation = PickerFileCopyOperation(destination: destination, imageNumber: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await operation.load { _ in
                XCTFail("A cancelled import must not start a provider")
                return Progress(totalUnitCount: 1)
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testCancellationBeforeProgressIsReturnedCancelsProviderProgress() async throws {
        let providerProgress = Progress(totalUnitCount: 1)
        let operation = PickerFileCopyOperation(destination: destination, imageNumber: 1)
        let task = Task {
            try await operation.load { _ in
                // Emulates cancellation while loadFileRepresentation is still
                // returning its Progress to the bridge.
                withUnsafeCurrentTask { $0?.cancel() }
                return providerProgress
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertTrue(providerProgress.isCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testCancellationAfterSynchronousCopyRemovesOnlyOwnedCopy() async throws {
        let operation = PickerFileCopyOperation(destination: destination, imageNumber: 1)
        let task = Task {
            try await operation.load { completion in
                completion(self.source, nil)
                withUnsafeCurrentTask { $0?.cancel() }
                return Progress(totalUnitCount: 1)
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3, 4]))
    }

    @MainActor
    func testExistingDestinationIsNotRemovedOrOverwritten() async throws {
        try Data([9, 8, 7]).write(to: destination)
        let operation = PickerFileCopyOperation(destination: destination, imageNumber: 1)
        do {
            _ = try await operation.load { completion in
                completion(self.source, nil)
                return Progress(totalUnitCount: 1)
            }
            XCTFail("Existing destination must fail safely")
        } catch let error as PhotoSelectionError {
            XCTAssertEqual(error, .unavailableImage(1))
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data([9, 8, 7]))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3, 4]))
    }

    @MainActor
    func testProviderSourceEqualToDestinationIsNeverRemoved() async throws {
        let operation = PickerFileCopyOperation(destination: source, imageNumber: 1)
        do {
            _ = try await operation.load { completion in
                completion(self.source, nil)
                return Progress(totalUnitCount: 1)
            }
            XCTFail("An input must not also be the output")
        } catch let error as PhotoSelectionError {
            XCTAssertEqual(error, .unavailableImage(1))
        }
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3, 4]))
    }

    @MainActor
    func testProviderFailureReturnsIndexedSafeErrorWithoutWritingFile() async throws {
        let operation = PickerFileCopyOperation(destination: destination, imageNumber: 3)
        do {
            _ = try await operation.load { completion in
                completion(nil, NSError(domain: "synthetic", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC_PRIVATE_DETAIL"]))
                return Progress(totalUnitCount: 1)
            }
            XCTFail("Provider failure must propagate safely")
        } catch let error as PhotoSelectionError {
            XCTAssertEqual(error, .unavailableImage(3))
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_PRIVATE_DETAIL"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private final class SyntheticPickerCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: PickerFileCopyOperation.Completion?

    func store(_ callback: @escaping PickerFileCopyOperation.Completion) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func invoke(_ url: URL) {
        lock.lock()
        let completion = callback
        lock.unlock()
        completion?(url, nil)
    }
}
