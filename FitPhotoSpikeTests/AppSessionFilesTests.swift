import Foundation
import XCTest
@testable import FitPhotoSpike

final class AppSessionFilesTests: XCTestCase {
    func testRemovingResultsKeepsStagedInputsAndOtherSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AppSessionFiles(root: root)
        let second = try AppSessionFiles(root: root)
        let source = first.inputDirectory.appendingPathComponent("source.png")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.createDirectory(at: first.outputDirectory, withIntermediateDirectories: true)
        let result = first.outputDirectory.appendingPathComponent("result.jpeg")
        try Data([4, 5]).write(to: result)
        first.removeOutputs()
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.inputDirectory.path))
        first.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path))
    }

    func testLaunchCleanupOnlyRemovesOwnedBatchDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try AppSessionFiles(root: root)
        let foreign = root.appendingPathComponent("unrelated-files", isDirectory: true)
        let malformed = root.appendingPathComponent("batch-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        let foreignFile = foreign.appendingPathComponent("unrelated.jpeg")
        try Data([9]).write(to: foreignFile)
        AppSessionFiles.removeAbandonedBatches(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path))
        XCTAssertEqual(try Data(contentsOf: foreignFile), Data([9]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
    }

    func testReleasingLastSessionOwnerRemovesStagedInputsAndOutputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session: AppSessionFiles? = try AppSessionFiles(root: root)
        weak var weakSession = session
        let directory = try XCTUnwrap(session?.directory)
        let source = try XCTUnwrap(session?.inputDirectory).appendingPathComponent("synthetic.png")
        let outputDirectory = try XCTUnwrap(session?.outputDirectory)
        try Data([1]).write(to: source)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data([2]).write(to: outputDirectory.appendingPathComponent("synthetic.jpeg"))
        session = nil
        XCTAssertNil(weakSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testSharePresentationRetainsSessionOnlyUntilItIsReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session: AppSessionFiles? = try AppSessionFiles(root: root)
        weak var weakSession = session
        let directory = try XCTUnwrap(session?.directory)
        var presentation: BatchShareSheet.SharePresentationController? = .init(
            urls: [], session: session, onCompletion: { _ in })
        session = nil
        withExtendedLifetime(presentation) {
            XCTAssertNotNil(weakSession)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
        presentation = nil
        XCTAssertNil(weakSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testWorkerRetainsSessionUntilJoinedAfterOwnerReleasesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session: AppSessionFiles? = try AppSessionFiles(root: root)
        weak var weakSession = session
        let directory = try XCTUnwrap(session?.directory)
        let gate = AsyncStream<Void>.makeStream()
        var worker: Task<Void, Never>? = Task { [session] in
            defer { withExtendedLifetime(session) {} }
            for await _ in gate.stream { break }
        }
        session = nil
        XCTAssertNotNil(weakSession)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        gate.continuation.finish()
        await worker?.value
        worker = nil
        XCTAssertNil(weakSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testIndependentSessionsUseDistinctPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AppSessionFiles(root: root)
        let second = try AppSessionFiles(root: root)
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertNotEqual(first.inputDirectory, first.outputDirectory)
    }
}
