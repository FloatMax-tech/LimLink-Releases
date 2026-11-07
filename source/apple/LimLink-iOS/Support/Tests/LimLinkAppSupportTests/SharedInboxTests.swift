import Foundation
import XCTest
@testable import LimLinkAppSupport

final class SharedInboxTests: XCTestCase {
    func testStagedFileStaysReadableUntilAcknowledged() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try temporaryFile(contents: "shared", name: "s.png", in: base)

        let staged = try SharedInbox.stage(source, name: "s.png", container: base)
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "shared")
        let pending = SharedInbox.pending(container: base)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.name, "s.png")
        XCTAssertEqual(pending.first?.size, 6)

        let readAgain = SharedInbox.pending(container: base)
        XCTAssertEqual(readAgain, pending)
        XCTAssertEqual(try String(contentsOf: readAgain[0].url, encoding: .utf8), "shared")
        SharedInbox.discard(readAgain[0])
        XCTAssertTrue(SharedInbox.pending(container: base).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testUnsafeNamesAreMadeSafeAndOversizedFilesRejected() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try temporaryFile(contents: "x", name: "a.txt", in: base)

        let staged = try SharedInbox.stage(source, name: "../../evil.txt", container: base)
        XCTAssertEqual(staged.lastPathComponent, "..-..-evil.txt")
        XCTAssertTrue(staged.path.hasPrefix(base.path))

        let big = base.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(TransferLimits.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try SharedInbox.stage(big, name: "big.bin", container: base)) {
            XCTAssertEqual($0 as? ShareInboxError, .tooLarge)
        }
    }

    func testPendingDoesNotPublishAFileUntilItsCopyFinishes() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try temporaryFile(contents: "complete", name: "shared.txt", in: base)

        let staged = try SharedInbox.stage(source, name: "shared.txt", container: base) { _, destination in
            XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: nil))
            let writer = try FileHandle(forWritingTo: destination)
            try writer.write(contentsOf: Data("comp".utf8))
            XCTAssertTrue(SharedInbox.pending(container: base).isEmpty,
                          "The app must not be offered the partial file while the extension is copying it")
            try writer.write(contentsOf: Data("lete".utf8))
            try writer.close()
        }

        let pending = SharedInbox.pending(container: base)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].size, 8)
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "complete")
    }

    func testFailedCopyPublishesNothingAndRemovesThePartialFile() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try temporaryFile(contents: "complete", name: "shared.txt", in: base)
        var partial: URL?

        XCTAssertThrowsError(try SharedInbox.stage(source, name: "shared.txt", container: base) { _, destination in
            partial = destination
            try Data("comp".utf8).write(to: destination)
            throw CocoaError(.fileWriteOutOfSpace)
        })

        XCTAssertTrue(SharedInbox.pending(container: base).isEmpty)
        let partialURL = try XCTUnwrap(partial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.deletingLastPathComponent().path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "complete")
    }

    @MainActor
    func testFailedImportRetainsTheOriginalForASuccessfulRetry() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try temporaryFile(contents: "retry me", name: "shared.txt", in: base)
        let staged = try SharedInbox.stage(source, name: "shared.txt", container: base)
        let outgoing = base.appendingPathComponent("Outgoing")
        // A file in place of the snapshot directory makes the real disk import fail.
        try Data([0]).write(to: outgoing)
        let store = TransferFileStore(inbox: base.appendingPathComponent("Inbox"), outgoingDirectory: outgoing)
        var selected: TransferFile?
        let failed = await SharedInbox.importNext(container: base) { url in
            selected = try? await store.load(url)
            return selected != nil
        }

        XCTAssertEqual(failed, .failed)
        XCTAssertNil(selected)
        XCTAssertEqual(SharedInbox.pending(container: base).map { $0.url.resolvingSymlinksInPath() }, [staged.resolvingSymlinksInPath()])
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "retry me")

        try FileManager.default.removeItem(at: outgoing)
        let retried = await SharedInbox.importNext(container: base) { url in
            selected = try? await store.load(url)
            return selected != nil
        }
        XCTAssertEqual(retried, .imported(hasMore: false))
        XCTAssertTrue(SharedInbox.pending(container: base).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try selected?.source.read(offset: 0, count: 8), Array("retry me".utf8))
    }

    @MainActor
    func testSuccessfulImportConsumesOnlyTheSelectedFile() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try temporaryFile(contents: "first", name: "first.txt", in: base)
        let second = try temporaryFile(contents: "second", name: "second.txt", in: base)
        try SharedInbox.stage(first, name: "first.txt", container: base)
        try SharedInbox.stage(second, name: "second.txt", container: base)
        let original = SharedInbox.pending(container: base)
        let store = TransferFileStore(inbox: base.appendingPathComponent("Inbox"),
                                      outgoingDirectory: base.appendingPathComponent("Outgoing"))
        var selected: TransferFile?

        let result = await SharedInbox.importNext(container: base) { url in
            selected = try? await store.load(url)
            return selected != nil
        }

        XCTAssertEqual(result, .imported(hasMore: true))
        XCTAssertEqual(selected?.name, original[0].name)
        XCTAssertEqual(SharedInbox.pending(container: base), [original[1]])
    }

    @MainActor
    func testFileAboveFiftyMiBUsesDiskHandoffAndFileBackedImport() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("video.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 52_428_801)
        try handle.seek(toOffset: 52_428_800)
        try handle.write(contentsOf: Data([42]))
        try handle.close()
        try SharedInbox.stage(source, name: "video.mov", container: base)
        let store = TransferFileStore(inbox: base.appendingPathComponent("Inbox"),
                                      outgoingDirectory: base.appendingPathComponent("Outgoing"))
        var selected: TransferFile?

        let result = await SharedInbox.importNext(container: base) { url in
            selected = try? await store.load(url)
            return selected != nil
        }

        XCTAssertEqual(result, .imported(hasMore: false))
        XCTAssertEqual(selected?.size, 52_428_801)
        XCTAssertNotNil(selected?.url)
        XCTAssertEqual(try selected?.source.read(offset: 52_428_800, count: 1), [42])
        XCTAssertTrue(SharedInbox.pending(container: base).isEmpty)
    }

    @MainActor
    func testSelectedFileDefersTheNextShareWithoutConsumingIt() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try temporaryFile(contents: "keep A", name: "A.txt", in: base)
        let second = try temporaryFile(contents: "queued B", name: "B.txt", in: base)
        try SharedInbox.stage(second, name: "B.txt", container: base)
        let store = TransferFileStore(inbox: base.appendingPathComponent("Inbox"),
                                      outgoingDirectory: base.appendingPathComponent("Outgoing"))
        var selected: TransferFile? = try await store.load(first)

        let deferred = await SharedInbox.importNext(canImport: selected == nil, container: base) { url in
            selected = try? await store.load(url)
            return selected != nil
        }

        XCTAssertEqual(deferred, .deferred)
        XCTAssertEqual(selected?.name, "A.txt")
        XCTAssertEqual(try selected?.source.read(offset: 0, count: 6), Array("keep A".utf8))
        XCTAssertEqual(SharedInbox.pending(container: base).map(\.name), ["B.txt"])

        selected = nil
        let imported = await SharedInbox.importNext(canImport: selected == nil, container: base) { url in
            selected = try? await store.load(url)
            return selected != nil
        }
        XCTAssertEqual(imported, .imported(hasMore: false))
        XCTAssertEqual(selected?.name, "B.txt")
        XCTAssertEqual(try selected?.source.read(offset: 0, count: 8), Array("queued B".utf8))
        XCTAssertTrue(SharedInbox.pending(container: base).isEmpty)
    }

    func testPendingReclaimsOnlyAbandonedStagingAndPreservesFreshAndCompletedFiles() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try temporaryFile(contents: "complete", name: "complete.txt", in: base)
        let completed = try SharedInbox.stage(source, name: "complete.txt", container: base)
        let inbox = completed.deletingLastPathComponent().deletingLastPathComponent()
        let old = inbox.appendingPathComponent("." + UUID().uuidString, isDirectory: true)
        let fresh = inbox.appendingPathComponent("." + UUID().uuidString, isDirectory: true)
        let unrelated = inbox.appendingPathComponent(".unrelated-cache", isDirectory: true)
        let oldDate = Date().addingTimeInterval(-172_800)
        for directory in [old, fresh, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: directory.appendingPathComponent("partial.bin"))
        }
        for directory in [old, unrelated, completed.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.creationDate: oldDate, .modificationDate: oldDate], ofItemAtPath: directory.path)
        }

        let pending = SharedInbox.pending(container: base)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("partial.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("partial.bin").path))
        XCTAssertEqual(pending.map(\.name), ["complete.txt"])
        XCTAssertEqual(try String(contentsOf: completed, encoding: .utf8), "complete")
    }

    @MainActor
    func testEmptyInboxDoesNotInvokeAnImport() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let result = await SharedInbox.importNext(container: base) { _ in
            XCTFail("There is no pending share to import")
            return true
        }
        XCTAssertEqual(result, .empty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SharedInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryFile(contents: String, name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
