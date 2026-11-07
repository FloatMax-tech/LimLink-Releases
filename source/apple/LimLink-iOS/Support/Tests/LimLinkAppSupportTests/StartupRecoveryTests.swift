import Foundation
import XCTest
@testable import LimLinkAppSupport

final class StartupRecoveryTests: XCTestCase {
    func testLocalNetworkPermissionFailuresAreRetried() {
        for code in [StartupRecovery.permissionDeniedDNS, StartupRecovery.noAuthDNS] {
            let failure = StartupRecovery.classify(dnsCode: code)
            XCTAssertEqual(failure, .localNetworkPermission)
            XCTAssertTrue(failure.isTransient)
            XCTAssertEqual(StartupRecovery.retryDelays(for: failure).count, 3)
            XCTAssertNotNil(StartupRecovery.waitingTitle(failure))
            XCTAssertTrue(StartupRecovery.message(for: failure).contains("本地网络"))
        }
    }

    func testNetworkAndPortFailuresAreTransient() {
        XCTAssertEqual(StartupRecovery.classify(posixCode: ENETDOWN), .networkDown)
        XCTAssertEqual(StartupRecovery.classify(posixCode: EADDRNOTAVAIL), .networkDown)
        XCTAssertEqual(StartupRecovery.classify(addressInUse: true), .addressInUse)
        XCTAssertFalse(StartupRecovery.retryDelays(for: .addressInUse).isEmpty)
    }

    func testTimeoutsGetASingleLongerRetry() {
        let failure = StartupRecovery.classify(timedOut: true)
        XCTAssertEqual(failure, .timedOut)
        XCTAssertEqual(StartupRecovery.retryDelays(for: failure), [.seconds(1.5)])
        XCTAssertNil(StartupRecovery.waitingTitle(failure))
    }

    func testUnknownFailuresAreNotRetried() {
        let failure = StartupRecovery.classify(posixCode: EPROTO)
        XCTAssertEqual(failure, .other("POSIX \(EPROTO)"))
        XCTAssertFalse(failure.isTransient)
        XCTAssertTrue(StartupRecovery.retryDelays(for: failure).isEmpty)
    }
}
