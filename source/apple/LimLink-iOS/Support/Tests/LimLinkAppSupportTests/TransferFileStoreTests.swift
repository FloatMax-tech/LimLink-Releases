import Foundation
import Testing
@testable import LimLinkAppSupport

struct TransferFileStoreTests {
    @Test func supportsFiveBillionByteSingleFiles() {
        #expect(TransferLimits.maximumFileBytes == 5_000_000_000)
    }

    @Test func loadsAFileAboveTheFormerTwentyMiBLimit() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("larger.bin")
        try Data(repeating: 42, count: 20_971_521).write(to: source)
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))
        let file = try await store.load(source)
        #expect(file.name == "larger.bin")
    }

    @Test func loadsAnEmptyRegularFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("empty.txt")
        try Data().write(to: source)
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))

        let file = try await store.load(source)

        #expect(file.name == "empty.txt")
        #expect(file.size == 0)
        #expect(try file.source.read(offset: 0, count: 0).isEmpty)
    }

    @Test func loadsTwentyMiBIntoAFileBackedSnapshot() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("exact.bin")
        try Data(repeating: 42, count: 20_971_520).write(to: source)
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))

        let file = try await store.load(source)

        #expect(file.size == 20_971_520)
        #expect(file.url != nil)
        #expect(try file.source.read(offset: 0, count: 1) == [42])
        #expect(try file.source.read(offset: file.size - 1, count: 1) == [42])
    }

    @Test func rejectsOneByteAboveTheDefaultLimitBeforeOpeningForRead() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("too-large.bin")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 5_000_000_001)
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))

        await #expect(throws: TransferFileStoreError.fileTooLarge(maximumBytes: 5_000_000_000, actualBytes: 5_000_000_001)) {
            try await store.load(source)
        }
    }

    @Test func selectedSnapshotSurvivesSourceChangesAndIsRemovedWhenReleased() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("source.txt")
        try Data([1, 2, 3]).write(to: source)
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"),
                                      outgoingDirectory: directory.url.appendingPathComponent("Outgoing"))
        var file: TransferFile? = try await store.load(source)
        let snapshot = try #require(file?.url)
        try Data([9, 9]).write(to: source)
        #expect(try file?.source.read(offset: 0, count: 3) == [1, 2, 3])
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        file = nil
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try Data(contentsOf: source) == Data([9, 9]))
    }

    @Test func publishesVerifiedURLAndPreservesExistingDestination() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))
        let original = try await store.save(name: "file.bin", bytes: [1])
        let temporary = directory.url.appendingPathComponent("incoming.tmp")
        try Data([2, 3, 4]).write(to: temporary)
        let saved = try await store.save(name: "file.bin", fileURL: temporary, expectedSize: 3)
        #expect(saved.name == "file (1).bin")
        #expect(saved.size == 3)
        #expect(try Data(contentsOf: saved.url) == Data([2, 3, 4]))
        #expect(try Data(contentsOf: original.url) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func refusesPublishingTruncatedFileAndLeavesSourceForCleanup() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let inbox = directory.url.appendingPathComponent("Inbox")
        let store = TransferFileStore(inbox: inbox)
        let temporary = directory.url.appendingPathComponent("incoming.tmp")
        try Data([1]).write(to: temporary)
        await #expect(throws: TransferFileStoreError.sizeMismatch(expected: 2, actual: 1)) {
            try await store.save(name: "file.bin", fileURL: temporary, expectedSize: 2)
        }
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: inbox.path))
    }

    @Test func cancellationDoesNotLeaveAnOutgoingSnapshot() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("source.bin")
        let outgoing = directory.url.appendingPathComponent("Outgoing")
        try Data([1, 2, 3]).write(to: source)
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"), outgoingDirectory: outgoing)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.load(source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: outgoing.path))
    }

    @Test func rejectsDirectoriesAsNonRegularFiles() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))

        await #expect(throws: TransferFileStoreError.notRegularFile(directory.url)) {
            try await store.load(directory.url)
        }
    }

    @Test func rejectsSymbolicLinksAsNonRegularFiles() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("original.txt")
        let link = directory.url.appendingPathComponent("link.txt")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))

        await #expect(throws: TransferFileStoreError.notRegularFile(link)) {
            try await store.load(link)
        }
    }

    @Test func savesAnEmptyFileToANewInbox() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let inbox = directory.url.appendingPathComponent("Inbox")
        let store = TransferFileStore(inbox: inbox)

        let saved = try await store.save(name: "empty.txt", bytes: [])

        #expect(saved.name == "empty.txt")
        #expect(saved.url == inbox.appendingPathComponent("empty.txt"))
        #expect(saved.size == 0)
        #expect(try Data(contentsOf: saved.url).isEmpty)
    }

    @Test(arguments: ["", ".", "..", "../escape.txt", "/absolute.txt", "folder/file.txt", "folder\\file.txt", "line\nfeed.txt", "null\0name"])
    func rejectsUnsafeBasenames(name: String) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))

        await #expect(throws: TransferFileStoreError.invalidFileName(name)) {
            try await store.save(name: name, bytes: [1])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test func collisionSavesKeepBothFilesAndTheirOriginalBytes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))

        let first = try await store.save(name: "note.txt", bytes: [1, 2])
        let second = try await store.save(name: "note.txt", bytes: [3])
        let third = try await store.save(name: "NOTE.TXT", bytes: [4])

        #expect(first.name == "note.txt")
        #expect(second.name == "note (1).txt")
        #expect(third.name == "NOTE (2).TXT")
        #expect(try Data(contentsOf: first.url) == Data([1, 2]))
        #expect(try Data(contentsOf: second.url) == Data([3]))
        #expect(try Data(contentsOf: third.url) == Data([4]))
    }

    @Test func collisionSavesMaximumLengthBasenameWithoutOverwriting() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))
        let name = String(repeating: "x", count: 251) + ".txt"

        let first = try await store.save(name: name, bytes: [1, 2])
        let second = try await store.save(name: name, bytes: [3])

        #expect(first.name == name)
        #expect(second.name != first.name)
        #expect(second.name.utf8.count <= 255)
        #expect(second.name.hasSuffix(" (1).txt"))
        #expect(try Data(contentsOf: first.url) == Data([1, 2]))
        #expect(try Data(contentsOf: second.url) == Data([3]))
    }

    @Test func collisionSavesMultibyteBasenameAndExtensionWithinUTF8Limit() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))
        let name = String(repeating: "文", count: 82) + ".资料"

        let first = try await store.save(name: name, bytes: [5])
        let second = try await store.save(name: name, bytes: [6])
        let third = try await store.save(name: name, bytes: [7])

        #expect(first.name == name)
        #expect(Set([first.name, second.name, third.name]).count == 3)
        #expect(second.name.utf8.count <= 255)
        #expect(third.name.utf8.count <= 255)
        #expect(second.name.hasSuffix(" (1).资料"))
        #expect(third.name.hasSuffix(" (2).资料"))
        #expect(try Data(contentsOf: first.url) == Data([5]))
        #expect(try Data(contentsOf: second.url) == Data([6]))
        #expect(try Data(contentsOf: third.url) == Data([7]))
    }

    @Test func collisionSavesWithAShorterFallbackWhenTheExtensionConsumesTheBudget() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))
        let name = "a." + String(repeating: "文", count: 84)

        let first = try await store.save(name: name, bytes: [8])
        let second = try await store.save(name: name, bytes: [9])

        #expect(first.name == name)
        #expect(second.name != first.name)
        #expect(second.name.utf8.count <= 255)
        #expect(try Data(contentsOf: first.url) == Data([8]))
        #expect(try Data(contentsOf: second.url) == Data([9]))
    }

    @Test func refusesSavingBytesBeyondTheConfiguredLimit() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"), maximumFileBytes: 4)

        await #expect(throws: TransferFileStoreError.fileTooLarge(maximumBytes: 4, actualBytes: 5)) {
            try await store.save(name: "large.bin", bytes: [1, 2, 3, 4, 5])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test func writeFailureThrowsWithoutPublishingASavedFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let inbox = directory.url.appendingPathComponent("Inbox")
        try Data([9]).write(to: inbox)
        let store = TransferFileStore(inbox: inbox)

        do {
            _ = try await store.save(name: "received.txt", bytes: [1, 2, 3])
            Issue.record("A failed disk write must not return a SavedFile")
        } catch let error as TransferFileStoreError {
            guard case .saveFailed(let url, let message) = error else {
                Issue.record("Expected saveFailed, received \(error)")
                return
            }
            #expect(url == inbox)
            #expect(!message.isEmpty)
        }
        #expect(try Data(contentsOf: inbox) == Data([9]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["Inbox"])
    }

    @Test func listsPersistedFilesFromANewStoreWithTheirActualSize() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let inbox = directory.url.appendingPathComponent("Inbox")
        let writer = TransferFileStore(inbox: inbox)
        let saved = try await writer.save(name: "received.bin", bytes: [10, 11, 12])
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let link = inbox.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: saved.url)
        let reader = TransferFileStore(inbox: inbox)

        let files = try await reader.listSavedFiles()

        #expect(files == [SavedFile(name: "received.bin", url: inbox.appendingPathComponent("received.bin"), size: 3)])
    }

    @Test func listsNoFilesBeforeTheInboxExists() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = TransferFileStore(inbox: directory.url.appendingPathComponent("Inbox"))

        #expect(try await store.listSavedFiles().isEmpty)
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("LimLinkAppSupportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
