import Foundation
import XCTest
import LimLinkCoreLogic
@testable import LimLinkKit

final class PartialWriteOrderingTests: XCTestCase {
    func testQueuedWritesCannotRestoreDiscardedBytesOrManifestEntry() throws {
        let id = "ordering-" + UUID().uuidString
        let root = try PartialFileMaintenance.privatePartialURL()
        let directory = try PartialDirectory(root: root)
        defer { try? directory.remove(id: id) }
        let drained = DispatchSemaphore(value: 0)
        for count in 1...8 {
            PartialFileMaintenance.enqueue([
                PartialSyncItem(id: id, bytes: Array(repeating: 42, count: count * 1024),
                                activity: .transferring, since: nil, lastWrite: Date(), remove: false)
            ], saveLocation: nil)
        }
        PartialFileMaintenance.enqueue([
            PartialSyncItem(id: id, bytes: [], activity: .transferring,
                            since: nil, lastWrite: Date(), remove: true)
        ], saveLocation: nil)
        PartialFileMaintenance.enqueueFileWork { drained.signal() }
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).appendingPathExtension("bin").path))
        XCTAssertFalse(try directory.records().contains { $0.id == id })
    }

    func testDiscardWaitsForAnAlreadyQueuedPartialWrite() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let discarded = DispatchSemaphore(value: 0)
        let events = OrderedEvents()

        PartialFileMaintenance.enqueueFileWork {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            events.append("write")
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        PartialFileMaintenance.enqueueFileWork {
            events.append("discard")
            discarded.signal()
        }
        let prematureDiscard = discarded.wait(timeout: .now() + .milliseconds(50))
        release.signal()
        if prematureDiscard == .timedOut {
            XCTAssertEqual(discarded.wait(timeout: .now() + 1), .success)
        }
        XCTAssertEqual(prematureDiscard, .timedOut)
        XCTAssertEqual(events.values, ["write", "discard"])
    }

    private final class OrderedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] { lock.withLock { storage } }
        func append(_ value: String) { lock.withLock { storage.append(value) } }
    }
}
