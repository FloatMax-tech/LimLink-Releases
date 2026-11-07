import XCTest
@testable import LimLinkCoreLogic

final class HostHeaderTests: XCTestCase {
    func testStripsTheNetworkScopeIdAppleAdds() {
        XCTAssertEqual(WireApp.hostHeaderWithoutScope("192.168.0.229%en0"), "192.168.0.229")
        XCTAssertEqual(WireApp.hostHeaderWithoutScope("fe80::1%en0"), "fe80::1")
    }

    func testLeavesPlainHostsAlone() {
        XCTAssertEqual(WireApp.hostHeaderWithoutScope("192.168.0.229"), "192.168.0.229")
        XCTAssertEqual(WireApp.hostHeaderWithoutScope("office-pc.local:52470"), "office-pc.local:52470")
        XCTAssertEqual(WireApp.hostHeaderWithoutScope(""), "")
    }

    func testRequestsNeverCarryAScopedHost() {
        let request = WireApp.request(
            method: "POST", path: "/limlink/v1/hello", app: "limlink",
            hostHeader: "192.168.0.229%en0", body: [], json: true
        )
        XCTAssertEqual(request.headers["host"], "192.168.0.229")
    }
}
