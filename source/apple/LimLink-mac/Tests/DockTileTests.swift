import AppKit
import XCTest

final class DockTileTests: XCTestCase {
    @MainActor
    func testCompletionClearsActualDockWithoutAnyFurtherTransferUpdate() async throws {
        _ = NSApplication.shared
        defer { NSApp.dockTile.contentView = nil }
        let surfaces = ProgressSurfaces()
        surfaces.attach(dock: DockTileController(), menuBar: MenuBarProgressController())
        surfaces.render(BatchProgressSnapshot.make(phase: .completed(verified: true)))
        XCTAssertNotNil(NSApp.dockTile.contentView)

        try await Task.sleep(for: .milliseconds(3_200))

        XCTAssertNil(NSApp.dockTile.contentView)
    }

    @MainActor
    func testCompletionExpiryCannotClearANewerActiveTransfer() async throws {
        _ = NSApplication.shared
        defer { NSApp.dockTile.contentView = nil }
        let surfaces = ProgressSurfaces()
        surfaces.attach(dock: DockTileController(), menuBar: MenuBarProgressController())
        surfaces.render(BatchProgressSnapshot.make(phase: .completed(verified: true)))
        try await Task.sleep(for: .milliseconds(100))
        surfaces.render(BatchProgressSnapshot.make(bytesTransferred: 25, totalBytes: 100))

        try await Task.sleep(for: .milliseconds(3_200))

        XCTAssertEqual((NSApp.dockTile.contentView as? DockProgressView)?.visual, .ring(fraction: 0.25, style: .active))
    }

    func testAggregateAndPausedAndIndeterminate() {
        var reducer = DockTileReducer()
        let now = Date(timeIntervalSince1970: 0)
        let first = BatchProgressSnapshot.make(bytesTransferred: 50, totalBytes: 100)
        let second = BatchProgressSnapshot.make(bytesTransferred: 0, totalBytes: 100)
        XCTAssertEqual(
            reducer.present(sessions: [first, second], now: now),
            .ring(fraction: 0.25, style: .active)
        )

        let paused = BatchProgressSnapshot.make(
            bytesTransferred: 50,
            totalBytes: 100,
            phase: .paused(reason: "已暂停")
        )
        XCTAssertEqual(
            reducer.present(sessions: [paused, paused], now: now),
            .ring(fraction: 0.5, style: .paused)
        )
        XCTAssertEqual(
            reducer.present(sessions: [paused, first], now: now),
            .ring(fraction: 0.5, style: .active)
        )

        let unknown = BatchProgressSnapshot.make(totalBytesKnown: false, phase: .indeterminate)
        XCTAssertEqual(
            reducer.present(sessions: [unknown, first], now: now),
            .ring(fraction: 0.75, style: .indeterminateGap)
        )
    }

    func testIdleAndFailedUseSystemIcon() {
        var reducer = DockTileReducer()
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            reducer.present(sessions: [BatchProgressSnapshot.make(phase: .idle)], now: now),
            .systemIcon
        )
        XCTAssertEqual(
            reducer.present(sessions: [BatchProgressSnapshot.make(phase: .failed(summary: "传输失败"))], now: now),
            .systemIcon
        )
        XCTAssertEqual(reducer.present(sessions: [], now: now), .systemIcon)
    }

    func testCheckmarkHoldsForThreeSecondsOnce() {
        var reducer = DockTileReducer(completedHold: 3)
        let done = BatchProgressSnapshot.make(phase: .completed(verified: true))
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(reducer.present(sessions: [done], now: start), .checkmark)
        XCTAssertEqual(reducer.present(sessions: [done], now: start.addingTimeInterval(2.9)), .checkmark)
        XCTAssertEqual(reducer.present(sessions: [done], now: start.addingTimeInterval(3)), .systemIcon)
        XCTAssertEqual(reducer.present(sessions: [done], now: start.addingTimeInterval(30)), .systemIcon)

        let active = BatchProgressSnapshot.make(bytesTransferred: 10, totalBytes: 100)
        XCTAssertEqual(
            reducer.present(sessions: [active], now: start.addingTimeInterval(31)),
            .ring(fraction: 0.1, style: .active)
        )
    }

    func testThrottleLimitsRedraws() {
        var throttle = DisplayThrottle()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(throttle.shouldDisplay(visual: .ring(fraction: 0.10, style: .active), now: start))
        XCTAssertFalse(
            throttle.shouldDisplay(
                visual: .ring(fraction: 0.105, style: .active),
                now: start.addingTimeInterval(0.2)
            )
        )
        XCTAssertTrue(
            throttle.shouldDisplay(
                visual: .ring(fraction: 0.12, style: .active),
                now: start.addingTimeInterval(0.4)
            )
        )
        XCTAssertTrue(
            throttle.shouldDisplay(
                visual: .ring(fraction: 0.12, style: .active),
                now: start.addingTimeInterval(1.5)
            )
        )
        XCTAssertTrue(
            throttle.shouldDisplay(
                visual: .ring(fraction: 0.75, style: .indeterminateGap),
                now: start.addingTimeInterval(1.6)
            )
        )
        XCTAssertFalse(
            throttle.shouldDisplay(
                visual: .ring(fraction: 0.75, style: .indeterminateGap),
                now: start.addingTimeInterval(9)
            )
        )
    }
}
