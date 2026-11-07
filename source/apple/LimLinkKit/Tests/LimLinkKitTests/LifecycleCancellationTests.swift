import Foundation
import XCTest
@testable import LimLinkKit

final class LifecycleCancellationTests: XCTestCase, @unchecked Sendable {
    // A cancellation handler can run before its operation arms the continuation.
    // Forgetting that cancellation hangs the sender and consumes the next command.
    func testAlreadyCancelledTaskExitsWithoutConsumingNextCommand() async {
        let hub = LifecycleObserver.shared
        while hub.tryConsume() != nil {}
        let finished = expectation(description: "cancelled waiter exits")
        let task = Task {
            hub.beginSenderInterest()
            defer {
                hub.endSenderInterest()
                finished.fulfill()
            }
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await hub.waitForCommand()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await fulfillment(of: [finished], timeout: 1)

        // Also releases the old broken implementation, so a regression fails
        // promptly instead of leaving the test runner with a hung task.
        let next = SenderLifecycleCommand.resume(afterWake: true)
        hub.requeueFront(next)
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(hub.tryConsume(), next)
    }

    func testCancellingConcurrentRegistrationsLeavesFollowingCommandsQueued() async {
        let hub = LifecycleObserver.shared
        while hub.tryConsume() != nil {}
        let finished = expectation(description: "all cancelled registrations exit")
        finished.expectedFulfillmentCount = 100
        let tasks = (0..<100).map { _ in
            Task {
                defer { finished.fulfill() }
                do {
                    _ = try await hub.waitForCommand()
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
        }
        for task in tasks { task.cancel() }
        await fulfillment(of: [finished], timeout: 1)

        // A waiter stranded between arming and registration would consume one
        // of these commands. They also release hung waiters on a regression.
        for _ in tasks { hub.requeueFront(.resume(afterWake: false)) }
        for task in tasks {
            let cancelled = await task.value
            XCTAssertTrue(cancelled)
        }
        var remaining = 0
        while hub.tryConsume() != nil { remaining += 1 }
        XCTAssertEqual(remaining, 100)
    }
}
