import CoreServices
import XCTest

final class QuarantineTests: XCTestCase {
    func testStampOmitsPeerIdentity() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stamp = QuarantinePolicy.stamp(at: date)
        XCTAssertEqual(stamp.agentName, "LimLink")
        XCTAssertEqual(stamp.timestamp, date)
        XCTAssertFalse(stamp.includesOriginURL)
        XCTAssertFalse(stamp.includesDataURL)
        XCTAssertFalse(stamp.includesAgentBundleIdentifier)

        let properties = QuarantineMarker.properties(at: date)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "LimLink")
        XCTAssertNotNil(properties[kLSQuarantineTimeStampKey as String])
        XCTAssertNil(properties[kLSQuarantineOriginURLKey as String])
        XCTAssertNil(properties[kLSQuarantineDataURLKey as String])
        XCTAssertNil(properties[kLSQuarantineAgentBundleIdentifierKey as String])
        XCTAssertEqual(properties.count, 3)
    }

    func testApplyWritesQuarantineWithoutOrigin() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("limlink-quarantine-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try QuarantineMarker.apply(to: url, now: now)
        let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        let properties = try XCTUnwrap(values.quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "LimLink")
        XCTAssertNil(properties[kLSQuarantineOriginURLKey as String])
        XCTAssertNil(properties[kLSQuarantineDataURLKey as String])
        XCTAssertNil(properties[kLSQuarantineAgentBundleIdentifierKey as String])
    }
}
