import Foundation
import XCTest
@testable import LimLinkKit

final class LifecycleReceiverTests: XCTestCase {
    func testConcurrentRestartCannotOvertakeEndingCallback() {
        let hub = LifecycleObserver.shared
        let endingStarted = DispatchSemaphore(value: 0)
        let releaseEnding = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        let restarted = DispatchSemaphore(value: 0)
        let receiver = hub.addReceiver { directive in
            if directive.activity == .end || directive.backgroundTask == .end {
                endingStarted.signal()
                _ = releaseEnding.wait(timeout: .now() + 2)
            }
        }
        defer {
            releaseEnding.signal()
            hub.removeReceiver(receiver)
        }
        hub.setReceiverSessions(["first"], receiverID: receiver, revision: 1)
        DispatchQueue.global().async {
            hub.setReceiverSessions([], receiverID: receiver, revision: 2)
            ended.signal()
        }
        XCTAssertEqual(endingStarted.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            hub.setReceiverSessions(["second"], receiverID: receiver, revision: 3)
            restarted.signal()
        }
        let overtook = restarted.wait(timeout: .now() + .milliseconds(50))
        releaseEnding.signal()
        XCTAssertEqual(ended.wait(timeout: .now() + 1), .success)
        if overtook == .timedOut {
            XCTAssertEqual(restarted.wait(timeout: .now() + 1), .success)
        }
        XCTAssertEqual(overtook, .timedOut)
    }

    func testStaleSnapshotWithinOneReceiverCannotEndNewerTransfer() {
        let hub = LifecycleObserver.shared
        let events = EndEvents()
        let receiver = hub.addReceiver { events.record($0) }
        defer { hub.removeReceiver(receiver) }

        hub.setReceiverSessions(["new-session"], receiverID: receiver, revision: 2)
        let before = events.count
        hub.setReceiverSessions([], receiverID: receiver, revision: 1)
        XCTAssertEqual(events.count, before)
        hub.setReceiverSessions([], receiverID: receiver, revision: 3)
        XCTAssertEqual(events.count, before + 1)
    }

    func testOlderReceiverTeardownCannotEndNewerReceiverActivity() {
        let hub = LifecycleObserver.shared
        let events = EndEvents()
        let older = hub.addReceiver { _ in }
        let newer = hub.addReceiver { events.record($0) }
        defer {
            hub.removeReceiver(older)
            hub.removeReceiver(newer)
        }

        hub.setReceiverSessions(["older-session"], receiverID: older)
        hub.setReceiverSessions(["newer-session"], receiverID: newer)
        let before = events.count
        hub.removeReceiver(older)
        XCTAssertEqual(events.count, before)
        // A late callback from the departing service must not clear the newer one.
        hub.setReceiverSessions([], receiverID: older)
        XCTAssertEqual(events.count, before)
        hub.setReceiverSessions([], receiverID: newer)
        XCTAssertEqual(events.count, before + 1)
    }

    private final class EndEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record(_ directive: LifecycleDirective) {
            if directive.activity == .end || directive.backgroundTask == .end {
                lock.withLock { value += 1 }
            }
        }
    }
}
