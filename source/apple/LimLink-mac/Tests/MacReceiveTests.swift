import Foundation
import XCTest
import LimLinkKit
import LimLinkAppSupport

final class MacReceiveTests: XCTestCase {
    func testConsentRequiresAcceptanceAndExactTLSConnectionAndMetadata() throws {
        var consent = MacReceiveConsent()
        let connection = UUID()
        let pending = PendingSession(sessionID: "offer", fingerprint: "peer", fileName: "video.mov", size: 5_000_000_000, senderName: "客厅 iPad")
        XCTAssertTrue(consent.register(pending, connectionID: connection))
        let file = PublishedFile(sessionID: "offer", fingerprint: "peer", fileName: "video.mov", size: 5_000_000_000, bytes: [], fileURL: URL(fileURLWithPath: "/private/tmp/verified"))
        XCTAssertFalse(consent.permits(file, connectionID: connection))
        consent.decide(sessionID: "offer", accept: true)
        XCTAssertTrue(consent.permits(file, connectionID: connection))
        XCTAssertFalse(consent.permits(file, connectionID: UUID()))
        var changed = file
        changed.fingerprint = "other"
        XCTAssertFalse(consent.permits(changed, connectionID: connection))
        changed = file
        changed.size = 1
        XCTAssertFalse(consent.permits(changed, connectionID: connection))
        changed = file
        changed.fileName = "other.mov"
        XCTAssertFalse(consent.permits(changed, connectionID: connection))
        consent.disconnect(connectionID: connection)
        XCTAssertFalse(consent.permits(file, connectionID: connection))
    }

    func testOversizedAndUnsafeOffersCannotBecomeAccepted() {
        for (name, size) in [("huge", 5_000_000_001), ("../escape", 1), ("negative", -1)] {
            var consent = MacReceiveConsent()
            let connection = UUID()
            XCTAssertFalse(consent.register(PendingSession(sessionID: "bad", fingerprint: "peer", fileName: name, size: size), connectionID: connection))
            consent.decide(sessionID: "bad", accept: true)
            XCTAssertFalse(consent.permits(PublishedFile(sessionID: "bad", fingerprint: "peer", fileName: name, size: size, bytes: []), connectionID: connection))
        }
    }

    func testPublishingCopiesVerifiedFileWithoutOverwritingAndQuarantinesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = destination.appendingPathComponent("report.txt")
        try Data("existing".utf8).write(to: original)
        let verified = root.appendingPathComponent("verified")
        let bytes = Data(repeating: 0x51, count: 1_048_611)
        try bytes.write(to: verified)
        let store = MacReceivedFileStore()
        let saved = try await store.save(name: "report.txt", verifiedURL: verified, size: bytes.count, destination: destination)
        XCTAssertEqual(saved.name, "report (1).txt")
        XCTAssertEqual(try Data(contentsOf: original), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: saved.url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: verified.path))
        let values = try saved.url.resourceValues(forKeys: [.quarantinePropertiesKey])
        XCTAssertNotNil(values.quarantineProperties)
        let visible = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(visible), ["report.txt", "report (1).txt"])
    }

    func testStartupCleanupOnlyReclaimsOwnedPartialNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".limlink-receive-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let abandoned = staging.appendingPathComponent(UUID().uuidString + ".partial")
        let unrelated = staging.appendingPathComponent("keep.txt")
        try Data([1]).write(to: abandoned)
        try Data([2]).write(to: unrelated)
        let store = MacReceivedFileStore()
        try await store.reclaimAbandonedFiles(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([2]))
    }

    func testWrongLengthAndUnsafeNamePublishNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let verified = root.appendingPathComponent("verified")
        try Data([1, 2, 3]).write(to: verified)
        let destination = root.appendingPathComponent("destination")
        let store = MacReceivedFileStore()
        for (name, size) in [("file", 4), ("../escape", 3), ("file", 5_000_000_001)] {
            do {
                _ = try await store.save(name: name, verifiedURL: verified, size: size, destination: destination)
                XCTFail("Invalid verified file must not be published")
            } catch { }
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        XCTAssertTrue(entries.filter { !$0.hasPrefix(".") }.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }
}
