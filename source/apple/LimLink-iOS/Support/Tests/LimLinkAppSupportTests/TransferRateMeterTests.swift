import Foundation
import XCTest
@testable import LimLinkAppSupport

final class TransferRateMeterTests: XCTestCase {
    func testNoSpeedUntilTwoSamplesHalfASecondApart() {
        var meter = TransferRateMeter()
        let start = Date()
        XCTAssertNil(meter.record(bytes: 0, at: start))
        XCTAssertNil(meter.record(bytes: 1_000, at: start.addingTimeInterval(0.2)))
        XCTAssertEqual(meter.record(bytes: 50_000_000, at: start.addingTimeInterval(0.5)) ?? 0, 100_000_000, accuracy: 1)
    }

    func testSmoothsLaterSamplesAndIgnoresStalls() {
        var meter = TransferRateMeter()
        let start = Date()
        meter.record(bytes: 0, at: start)
        meter.record(bytes: 100, at: start.addingTimeInterval(1))
        XCTAssertEqual(meter.record(bytes: 400, at: start.addingTimeInterval(2)) ?? 0, 100 * 0.7 + 300 * 0.3, accuracy: 0.001)
        XCTAssertEqual(meter.record(bytes: 400, at: start.addingTimeInterval(3)) ?? 0, 160, accuracy: 0.001, "A stall keeps the last speed.")
    }

    func testThousandsOfChunkUpdatesForALargeFile() {
        var meter = TransferRateMeter()
        let start = Date()
        let chunk = 4 * 1024 * 1024
        var last: Double?
        for index in 0...1_280 { last = meter.record(bytes: index * chunk, at: start.addingTimeInterval(Double(index) * 0.05)) }
        XCTAssertEqual(last ?? 0, Double(chunk) / 0.05, accuracy: 1)
    }
}
