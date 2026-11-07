import Foundation
import XCTest
@testable import LimLinkAppSupport

@MainActor
final class SaveFolderPreferenceTests: XCTestCase {
    func testRememberedFolderResolvesInANewInstance() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try temporaryDirectory(named: "Downloads")

        let saved = try SaveFolderPreference(defaults: defaults).remember(folder)
        XCTAssertEqual(saved.displayName, "下载")

        let resolved = try XCTUnwrap(SaveFolderPreference(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).resolve())
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(resolved.displayName, "下载")
    }

    func testNothingRememberedAndForgetClearsTheFolder() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = SaveFolderPreference(defaults: defaults)
        XCTAssertNil(preference.resolve())

        try preference.remember(try temporaryDirectory(named: "收件"))
        XCTAssertEqual(preference.resolve()?.displayName, "收件")
        preference.forget()
        XCTAssertNil(preference.resolve())
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "SaveFolderPreferenceTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}

final class FolderFileStoreTests: XCTestCase {
    func testNextSaveRemovesExpiredProtocolStagingFile() async throws {
        let destination = try temporaryDirectory(named: "Downloads")
        let staging = destination.appendingPathComponent(".limlink-receive-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let abandoned = staging.appendingPathComponent("BFA38020-2D0E-47A2-9D88-E2C4D6860BA7.partial")
        try Data("abandoned received content".utf8).write(to: abandoned)
        try makeExpired(abandoned)
        let incoming = try receivedFile(contents: "new")

        let saved = try await FolderFileStore().save(name: "report.txt", fileURL: incoming, expectedSize: 3, destination: destination)

        XCTAssertEqual(try String(contentsOf: saved.url, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path), "The next save must reclaim an interrupted publication.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["report.txt"])
    }

    func testNewStageOfAnOldReceivedFileIsNotImmediatelyExpired() async throws {
        let destination = try temporaryDirectory(named: "Downloads")
        let incoming = try receivedFile(contents: "old received content")
        try makeExpired(incoming)
        let beforeStaging = Date()

        let staged = try FolderFileStaging.shared.stage(incoming, destination: destination)
        // Leaving the lease models a process exit after staging, before publication completed.
        FolderFileStaging.shared.finish(staged)
        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        XCTAssertGreaterThan(try XCTUnwrap(attributes[.modificationDate] as? Date), beforeStaging.addingTimeInterval(-1))
        let otherIncoming = try receivedFile(contents: "new")

        _ = try await FolderFileStore().save(name: "new.txt", fileURL: otherIncoming, expectedSize: 3, destination: destination)

        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "old received content", "Retention starts when a file enters staging, regardless of the received source's age.")
    }

    func testCleanupPreservesFreshAndUnownedStagingItems() async throws {
        let manager = FileManager.default
        let destination = try temporaryDirectory(named: "Downloads")
        let staging = destination.appendingPathComponent(".limlink-receive-staging", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let fresh = staging.appendingPathComponent("D9192195-4CB0-4FD1-BF76-F4E85D093267.partial")
        let recentlyModified = staging.appendingPathComponent("C9767043-EED3-48AE-899B-A9019E8DD71F.partial")
        let recentlyCreated = staging.appendingPathComponent("BB2866A2-8259-45D1-9C85-B42E025A051C.partial")
        let renamed = staging.appendingPathComponent("personal.partial")
        let otherExtension = staging.appendingPathComponent("BFA38020-2D0E-47A2-9D88-E2C4D6860BA7.txt")
        for url in [fresh, recentlyModified, recentlyCreated, renamed, otherExtension] { try Data("keep".utf8).write(to: url) }
        for url in [renamed, otherExtension] { try makeExpired(url) }
        let old = Date().addingTimeInterval(-48 * 60 * 60)
        try manager.setAttributes([.creationDate: old, .modificationDate: Date()], ofItemAtPath: recentlyModified.path)
        // Setting modification time first avoids Foundation clamping creation time to it.
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: recentlyCreated.path)
        try manager.setAttributes([.creationDate: Date()], ofItemAtPath: recentlyCreated.path)
        let nested = staging.appendingPathComponent("CE893B9E-629B-4025-9AD5-0381421B9261.partial", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appendingPathComponent("user.txt")
        try Data("keep".utf8).write(to: nestedFile)
        try makeExpired(nested)
        let outside = try receivedFile(contents: "private user content")
        try makeExpired(outside)
        let link = staging.appendingPathComponent("D6722812-DFFA-46F7-99EF-366B48B60952.partial")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        let incoming = try receivedFile(contents: "new")

        _ = try await FolderFileStore().save(name: "report.txt", fileURL: incoming, expectedSize: 3, destination: destination)

        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: staging.path)), Set([fresh, recentlyModified, recentlyCreated, renamed, otherExtension, nested, link].map(\.lastPathComponent)))
        XCTAssertEqual(try String(contentsOf: nestedFile, encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private user content")
    }

    func testRejectsSymbolicLinkStagingRootBeforeMovingReceivedContent() async throws {
        let manager = FileManager.default
        let destination = try temporaryDirectory(named: "Downloads")
        let outside = try temporaryDirectory(named: "UserFolder")
        let sentinel = outside.appendingPathComponent("BFA38020-2D0E-47A2-9D88-E2C4D6860BA7.partial")
        try Data("private user content".utf8).write(to: sentinel)
        try makeExpired(sentinel)
        try manager.createSymbolicLink(at: destination.appendingPathComponent(".limlink-receive-staging"), withDestinationURL: outside)
        let incoming = try receivedFile(contents: "new")

        do {
            _ = try await FolderFileStore().save(name: "report.txt", fileURL: incoming, expectedSize: 3, destination: destination)
            XCTFail("A staging root must be an ordinary directory owned by the staging protocol.")
        } catch let error as TransferFileStoreError {
            guard case .saveFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertTrue(manager.fileExists(atPath: incoming.path))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "private user content")
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: outside.path), [sentinel.lastPathComponent])
        XCTAssertFalse(manager.fileExists(atPath: destination.appendingPathComponent("report.txt").path))
    }

    func testAnotherStoreCannotReclaimAnExpiredActivePublication() async throws {
        let destination = try temporaryDirectory(named: "Downloads")
        let incoming = try receivedFile(contents: "old received content")
        let (staged, stagedSignal) = AsyncStream<URL>.makeStream()
        let (resume, resumeSignal) = AsyncStream<Void>.makeStream()

        let firstPublication = Task.detached {
            defer { stagedSignal.finish() }
            let temporary = try FolderFileStaging.shared.stage(incoming, destination: destination)
            defer { FolderFileStaging.shared.finish(temporary) }
            stagedSignal.yield(temporary)
            // Suspend at the same boundary as FolderFileStore.save, before the receiving actor
            // publishes. The second store must not infer abandonment from the file's old dates.
            for await _ in resume { break }
            return try await TransferFileStore(inbox: destination).save(name: "first.txt", fileURL: temporary, expectedSize: 20)
        }
        defer { resumeSignal.finish() }
        var stagedFiles = staged.makeAsyncIterator()
        let nextStagedFile = await stagedFiles.next()
        let active = try XCTUnwrap(nextStagedFile)
        try makeExpired(active)
        let otherIncoming = try receivedFile(contents: "new")

        let second = try await FolderFileStore().save(name: "second.txt", fileURL: otherIncoming, expectedSize: 3, destination: destination)
        let activeContents = try? String(contentsOf: active, encoding: .utf8)
        resumeSignal.yield(())
        resumeSignal.finish()
        let first = try await firstPublication.value

        XCTAssertEqual(activeContents, "old received content")
        XCTAssertEqual(try String(contentsOf: first.url, encoding: .utf8), "old received content")
        XCTAssertEqual(try String(contentsOf: second.url, encoding: .utf8), "new")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), ["first.txt", "second.txt"])
    }

    func testPublishesIntoTheFolderAndRenamesOnCollision() async throws {
        let destination = try temporaryDirectory(named: "Downloads")
        try Data("old".utf8).write(to: destination.appendingPathComponent("报告.pdf"))
        let incoming = try receivedFile(contents: "new")

        let saved = try await FolderFileStore().save(name: "报告.pdf", fileURL: incoming, expectedSize: 3, destination: destination)

        XCTAssertEqual(saved.name, "报告 (1).pdf")
        XCTAssertEqual(try String(contentsOf: saved.url, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        let visible = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        XCTAssertEqual(visible, ["报告 (1).pdf", "报告.pdf"], "No staging leftovers or partial files.")
    }

    func testFailureLeavesTheReceivedFileWhereItWas() async throws {
        let destination = try temporaryDirectory(named: "Downloads")
        let incoming = try receivedFile(contents: "data")

        do {
            _ = try await FolderFileStore().save(name: "../escape", fileURL: incoming, expectedSize: 4, destination: destination)
            XCTFail("Unsafe names must be rejected.")
        } catch let error as TransferFileStoreError {
            guard case .invalidFileName = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: incoming, encoding: .utf8), "data")
    }

    func testSizeMismatchIsRejectedBeforeMoving() async throws {
        let destination = try temporaryDirectory(named: "Downloads")
        let incoming = try receivedFile(contents: "data")

        do {
            _ = try await FolderFileStore().save(name: "a.txt", fileURL: incoming, expectedSize: 9, destination: destination)
            XCTFail("Size mismatch must be rejected.")
        } catch let error as TransferFileStoreError {
            guard case .sizeMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    private func receivedFile(contents: String) throws -> URL {
        let url = try temporaryDirectory(named: "incoming").appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeExpired(_ url: URL) throws {
        let old = Date().addingTimeInterval(-48 * 60 * 60)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: url.path)
    }
}

private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SaveFolderTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
