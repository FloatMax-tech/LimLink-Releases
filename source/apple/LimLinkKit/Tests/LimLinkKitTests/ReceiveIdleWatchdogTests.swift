import XCTest
@testable import LimLinkKit

final class ReceiveIdleWatchdogTests: XCTestCase {
    func testIdleDeadlineInvokesCancellationForAStalledReader() async {
        let cancelled = XCTestExpectation(description: "stalled read cancelled")
        let watchdog = ReceiveIdleWatchdog(timeout: .milliseconds(20)) { cancelled.fulfill() }
        defer { watchdog.stop() }
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testStoppedWatchdogDoesNotCancelACompletedRead() async {
        let cancelled = XCTestExpectation(description: "completed read remains open")
        cancelled.isInverted = true
        let watchdog = ReceiveIdleWatchdog(timeout: .milliseconds(20)) { cancelled.fulfill() }
        watchdog.stop()
        await fulfillment(of: [cancelled], timeout: 0.08)
    }

    func testProgressRestartsTheIdleDeadline() async throws {
        let early = XCTestExpectation(description: "progress extends deadline")
        early.isInverted = true
        let eventual = XCTestExpectation(description: "idle deadline eventually expires")
        let watchdog = ReceiveIdleWatchdog(timeout: .milliseconds(250)) {
            early.fulfill()
            eventual.fulfill()
        }
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(180))
        watchdog.reset()
        await fulfillment(of: [early], timeout: 0.12)
        await fulfillment(of: [eventual], timeout: 1)
    }
}
