import Foundation
import Photos
import XCTest
@testable import FitPhotoSpike

/// Only injected closures run. These tests never request real authorization or
/// create assets in a simulator/device photo library.
final class PhotoLibrarySaverTests: XCTestCase {
    @MainActor
    private func withSyntheticFiles(_ body: @MainActor ([URL]) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitPhotosSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...3).map { directory.appendingPathComponent("synthetic-\($0).jpeg") }
        for url in urls { try Data([1, 2, 3]).write(to: url) }
        try await body(urls)
    }

    @MainActor
    func testConstructingSaverDoesNotRequestPermissionOrSave() {
        var calls = 0
        _ = PhotoLibrarySaver(authorize: { calls += 1; return .authorized },
                             saveBatch: { _ in calls += 1 })
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testSaveAuthorizesThenSubmitsEntireBatchExactlyOnceInOrder() async throws {
        try await withSyntheticFiles { urls in
            var events: [String] = []
            var received: [[URL]] = []
            let saver = PhotoLibrarySaver(authorize: {
                events.append("authorization")
                return .authorized
            }, saveBatch: { batch in
                events.append("transaction")
                received.append(batch)
            })
            try await saver.save(urls)
            XCTAssertEqual(events, ["authorization", "transaction"])
            XCTAssertEqual(received, [urls])
            for url in urls {
                XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
            }
        }
    }

    @MainActor
    func testDeniedRestrictedAndLimitedNeverSubmitTransaction() async throws {
        try await withSyntheticFiles { urls in
            for status in [PHAuthorizationStatus.denied, .restricted, .limited, .notDetermined] {
                var transactions = 0
                let saver = PhotoLibrarySaver(authorize: { status },
                                             saveBatch: { _ in transactions += 1 })
                do {
                    try await saver.save(urls)
                    XCTFail("Unauthorized status must fail")
                } catch let error as PhotoLibrarySaveError {
                    XCTAssertEqual(error, status == .restricted ? .permissionRestricted : .permissionDenied)
                }
                XCTAssertEqual(transactions, 0)
            }
        }
    }

    @MainActor
    func testInvalidBatchFailsBeforeAuthorization() async throws {
        var authorizationCalls = 0
        let saver = PhotoLibrarySaver(authorize: {
            authorizationCalls += 1
            return .authorized
        }, saveBatch: { _ in XCTFail("Invalid files must not reach transaction") })
        let invalidBatches: [[URL]] = [[], [URL(string: "https://example.invalid/synthetic.jpeg")!]]
        for urls in invalidBatches {
            do {
                try await saver.save(urls)
                XCTFail("Invalid output must fail")
            } catch let error as PhotoLibrarySaveError {
                XCTAssertEqual(error, .invalidOutput)
            }
        }
        XCTAssertEqual(authorizationCalls, 0)
    }

    @MainActor
    func testMissingFilesDirectoriesAndTwentyOneOutputsFailBeforeAuthorization() async throws {
        try await withSyntheticFiles { urls in
            var authorizationCalls = 0
            let saver = PhotoLibrarySaver(authorize: {
                authorizationCalls += 1
                return .authorized
            }, saveBatch: { _ in XCTFail("Invalid files must not reach transaction") })
            let missing = urls[0].deletingLastPathComponent().appendingPathComponent("missing.jpeg")
            let invalidBatches = [[missing], [urls[0].deletingLastPathComponent()],
                                  Array(repeating: urls[0], count: 21)]
            for batch in invalidBatches {
                do {
                    try await saver.save(batch)
                    XCTFail("Invalid output must fail")
                } catch let error as PhotoLibrarySaveError {
                    XCTAssertEqual(error, .invalidOutput)
                }
            }
            XCTAssertEqual(authorizationCalls, 0)
        }
    }

    @MainActor
    func testCancellationAfterAuthorizationDoesNotStartTransaction() async throws {
        try await withSyntheticFiles { urls in
            var transactions = 0
            let saver = PhotoLibrarySaver(authorize: {
                withUnsafeCurrentTask { $0?.cancel() }
                return .authorized
            }, saveBatch: { _ in transactions += 1 })
            let task = Task { try await saver.save(urls) }
            do {
                try await task.value
                XCTFail("Cancelled save must fail before submitting")
            } catch is CancellationError {}
            XCTAssertEqual(transactions, 0)
        }
    }

    @MainActor
    func testCompletedTransactionStillReportsSuccessIfCallerCancelledDuringSave() async throws {
        try await withSyntheticFiles { urls in
            let saver = PhotoLibrarySaver(authorize: { .authorized }, saveBatch: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
            let task = Task { try await saver.save(urls) }
            // A real submitted PhotoKit transaction is not cancellable. A late
            // cancellation must not invite duplicate saving by hiding success.
            try await task.value
        }
    }

    @MainActor
    func testStorageErrorIsCategorizedWithoutExposingRawError() async throws {
        try await withSyntheticFiles { urls in
            let saver = PhotoLibrarySaver(authorize: { .authorized }, saveBatch: { _ in
                throw NSError(domain: PHPhotosError.errorDomain,
                              code: PHPhotosError.Code.notEnoughSpace.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC_PRIVATE_DETAIL"])
            })
            do {
                try await saver.save(urls)
                XCTFail("Storage failure must be reported")
            } catch let error as PhotoLibrarySaveError {
                XCTAssertEqual(error, .notEnoughSpace)
                XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_PRIVATE_DETAIL"))
            }
        }
    }
}
