import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class DiskReceiverTests: XCTestCase {
    func testReceiverAcknowledgesEachBoundedChunkAtItsDurableOffset() throws {
        var receiver = SingleFileReceiver(host: try HostAppIdentity(app: "limlink"), alias: "receiver", trustedFingerprints: ["peer"], sessionIDs: ["sid"], tokens: ["token"])
        XCTAssertEqual(response(receiver.handle(manifest(size: 3), peerAddressIsLocal: false, clientFingerprint: "peer")).status, 202)
        XCTAssertTrue(receiver.decide(sessionID: "sid", accept: true))
        let first = response(receiver.handle(upload([97], offset: 0), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(JSONWire.object(first.body)?["committedBytes"] as? Int, 1)
        let second = response(receiver.handle(upload([98, 99], offset: 1), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(second.status, 200)
        XCTAssertEqual(JSONWire.object(second.body)?["committedBytes"] as? Int, 3)
    }

    private func manifest(size: Int, key: String = "key", fileID: String = "file") -> HTTPRequest {
        request("POST", "", body: JSONWire.data(["clientSessionKey": key, "transport": "lan", "entries": [["id": fileID, "kind": "file", "relativePath": "payload.bin", "size": size]]]))
    }

    private func upload(_ bytes: [UInt8], offset: Int) -> HTTPRequest {
        WireApp.request(method: "PUT", path: "/limlink/v1/sessions/sid/files/file", app: "limlink", hostHeader: "peer", body: bytes, json: false, extra: ["content-type": "application/octet-stream", "x-limlink-token": "token", "x-limlink-offset": String(offset)])
    }

    private func request(_ method: String, _ suffix: String, body: [UInt8] = []) -> HTTPRequest {
        WireApp.request(method: method, path: "/limlink/v1/sessions\(suffix)", app: "limlink", hostHeader: "peer", body: body, json: method == "POST")
    }

    private func response(_ step: ReceiverStep) -> HTTPResponse {
        guard case .response(let response) = step else { XCTFail("Expected response"); return HTTPResponse(status: 500) }
        return response
    }
}
