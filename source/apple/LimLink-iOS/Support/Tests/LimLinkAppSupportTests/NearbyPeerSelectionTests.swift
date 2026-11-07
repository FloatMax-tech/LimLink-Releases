import XCTest
import LimLinkCoreLogic
@testable import LimLinkAppSupport

final class NearbyPeerSelectionTests: XCTestCase {
    private let ownPin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let peerPin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE"
    private let otherPin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI"

    func testUnresolvedOwnAdvertisementIsHiddenUntilIdentityArrives() throws {
        let unresolved = service(name: "我的 iPhone", pin: nil)
        let resolved = service(name: "我的 iPhone", pin: ownPin)
        XCTAssertTrue(try visible([unresolved]).isEmpty)
        XCTAssertTrue(try visible([resolved]).isEmpty)
    }

    func testOnlyCompleteCanonicalFingerprintsAreSelectable() throws {
        let invalidPins = ["", "AAAA-AAAA-AAAA-AAAA", peerPin + "=",
                           "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB", "not-a-fingerprint"]
        let invalid = invalidPins.map { service(name: "无效设备", pin: $0) }
        let peer = service(name: "iPad", pin: peerPin)
        XCTAssertEqual(try visible(invalid + [peer]), [peer])
    }

    func testSameDeviceAdvertisedMoreThanOnceAppearsOnceByFingerprint() throws {
        let first = service(name: "iPad", pin: peerPin)
        let duplicate = service(name: "iPad (2)", pin: peerPin)
        let other = service(name: "Mac", pin: otherPin)
        XCTAssertEqual(try visible([first, other, duplicate]), [first, other])
    }

    func testDifferentDevicesWithSameNameRemainSelectable() throws {
        let first = service(name: "iPhone", pin: peerPin)
        let second = service(name: "iPhone", pin: otherPin)
        XCTAssertEqual(try visible([first, second]), [first, second])
    }

    func testOwnIdentityMustBeReadyBeforeAnyPeerIsSelectable() throws {
        let peer = service(name: "iPad", pin: peerPin)
        for own in ["", "pending", ownPin + "=",
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"] {
            XCTAssertTrue(try visible([peer], ownFingerprint: own).isEmpty)
        }
    }

    private func service(name: String, pin: String?) -> DiscoveredService {
        var fields = TXTFields(entries: ["app": "limlink", "dt": "iphone"])
        fields.entries["fp"] = pin
        return DiscoveredService(instanceName: name, fields: fields)
    }

    private func visible(_ services: [DiscoveredService], ownFingerprint: String? = nil) throws -> [DiscoveredService] {
        NearbyPeerSelection.visible(services, ownFingerprint: ownFingerprint ?? ownPin)
    }
}
