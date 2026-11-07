import Foundation
import XCTest
@testable import LimLinkKit

final class PathSatisfactionTests: XCTestCase, @unchecked Sendable {
    // Without a cancellation handler, an offline sender cannot unwind its cleanup.
    func testCancellationInterruptsOfflineWaitBeforePathRecovery() async {
        let started = expectation(description: "path monitor started")
        let finished = expectation(description: "cancelled path wait unwinds")
        let monitor = ControlledPathMonitor(onStart: { started.fulfill() })
        let task = Task {
            defer { finished.fulfill() }
            do {
                try await PathSatisfaction.waitUntilSatisfied(monitor: monitor)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let queuedRecovery = monitor.satisfiedCallback
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)

        // Release the broken implementation after a timeout; also exercise an
        // already-queued network callback arriving after cancellation.
        queuedRecovery?()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(monitor.cancelCount, 1)
    }

    // A cancellation handler may run before the continuation is registered.
    func testAlreadyCancelledWaitExitsWithoutStartingMonitor() async {
        let finished = expectation(description: "already cancelled path wait unwinds")
        let monitor = ControlledPathMonitor()
        let task = Task {
            defer { finished.fulfill() }
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await PathSatisfaction.waitUntilSatisfied(monitor: monitor)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await fulfillment(of: [finished], timeout: 1)
        monitor.satisfiedCallback?() // Unstrand a regression before awaiting its result.
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(monitor.startCount, 0)
        XCTAssertEqual(monitor.cancelCount, 1)
    }

    func testPathRecoveryCompletesWaitAndReleasesMonitor() async throws {
        let started = expectation(description: "path monitor started")
        let monitor = ControlledPathMonitor(onStart: { started.fulfill() })
        let task = Task { try await PathSatisfaction.waitUntilSatisfied(monitor: monitor) }
        await fulfillment(of: [started], timeout: 1)
        let queuedRecovery = try XCTUnwrap(monitor.satisfiedCallback)
        queuedRecovery()
        try await task.value
        queuedRecovery() // Repeated/queued updates must not resume the continuation twice.
        XCTAssertEqual(monitor.cancelCount, 1)
    }

    func testCancellationRacingWithPathRecoveryCompletesEachWaitOnce() async throws {
        let started = expectation(description: "all path monitors started")
        let finished = expectation(description: "all raced waits unwind")
        started.expectedFulfillmentCount = 100
        finished.expectedFulfillmentCount = 100
        let monitors = (0..<100).map { _ in ControlledPathMonitor(onStart: { started.fulfill() }) }
        let tasks = monitors.map { monitor in
            Task {
                defer { finished.fulfill() }
                do {
                    try await PathSatisfaction.waitUntilSatisfied(monitor: monitor)
                    return true
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        for (monitor, task) in zip(monitors, tasks) {
            let queuedRecovery = try XCTUnwrap(monitor.satisfiedCallback)
            DispatchQueue.global().async { task.cancel() }
            DispatchQueue.global().async { queuedRecovery() }
        }
        await fulfillment(of: [finished], timeout: 5)
        for (monitor, task) in zip(monitors, tasks) {
            let completed = await task.value
            XCTAssertTrue(completed)
            XCTAssertEqual(monitor.cancelCount, 1)
        }
    }
}

/// Controls only the external path notification; production continuation and
/// cancellation handling run unchanged, without changing the machine's network.
private final class ControlledPathMonitor: PathSatisfactionMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: @Sendable () -> Void
    private var callback: (@Sendable () -> Void)?
    private var starts = 0
    private var cancellations = 0

    init(onStart: @escaping @Sendable () -> Void = {}) { self.onStart = onStart }

    var satisfiedCallback: (@Sendable () -> Void)? { lock.withLock { callback } }
    var startCount: Int { lock.withLock { starts } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func start(onSatisfied: @escaping @Sendable () -> Void) {
        lock.withLock {
            starts += 1
            callback = onSatisfied
        }
        onStart()
    }

    func cancel() {
        lock.withLock {
            cancellations += 1
            callback = nil
        }
    }
}
