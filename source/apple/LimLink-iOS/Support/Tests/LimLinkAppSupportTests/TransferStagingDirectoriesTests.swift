import Foundation
import Testing
@testable import LimLinkAppSupport

struct TransferStagingDirectoriesTests {
    @Test func clearsAbandonedSnapshotsAndPartialsWithoutTouchingInbox() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let outgoing = base.appendingPathComponent("LimLinkOutgoing", isDirectory: true)
        let incoming = base.appendingPathComponent("LimLinkIncoming", isDirectory: true)
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        let snapshot = outgoing.appendingPathComponent("abandoned-snapshot")
        let partial = incoming.appendingPathComponent("previous-run/unfinished.limlink-part")
        let saved = inbox.appendingPathComponent("keep.bin")
        try write([1], to: snapshot)
        try write([2], to: partial)
        try write([3], to: saved)

        let directories = TransferStagingDirectories(baseDirectory: base)

        #expect(directories.outgoing == outgoing)
        #expect(directories.incoming == incoming)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try Data(contentsOf: saved) == Data([3]))
    }

    @Test func reservedRootSymbolicLinkDoesNotDeleteItsTarget() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        let saved = inbox.appendingPathComponent("keep.bin")
        try write([4], to: saved)
        let outgoing = base.appendingPathComponent("LimLinkOutgoing")
        try FileManager.default.createSymbolicLink(at: outgoing, withDestinationURL: inbox)

        _ = TransferStagingDirectories(baseDirectory: base)

        #expect(try Data(contentsOf: saved) == Data([4]))
        #expect(!FileManager.default.fileExists(atPath: outgoing.path))
    }

    @Test func nestedSymbolicLinkDoesNotDeleteFilesOutsideStaging() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let saved = base.appendingPathComponent("Inbox/keep.bin")
        try write([5], to: saved)
        let incoming = base.appendingPathComponent("LimLinkIncoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: incoming.appendingPathComponent("outside"), withDestinationURL: saved.deletingLastPathComponent()
        )

        _ = TransferStagingDirectories(baseDirectory: base)

        #expect(try Data(contentsOf: saved) == Data([5]))
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
    }

    @Test func emptyBaseCanBeUsedForNewStagingAfterCleanup() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let directories = TransferStagingDirectories(baseDirectory: base)
        let outgoing = directories.outgoing.appendingPathComponent("new-snapshot")
        let incoming = directories.incoming.appendingPathComponent("new-run/new-partial")

        try write([6], to: outgoing)
        try write([7], to: incoming)

        #expect(try Data(contentsOf: outgoing) == Data([6]))
        #expect(try Data(contentsOf: incoming) == Data([7]))
    }

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LimLinkStagingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }
}
