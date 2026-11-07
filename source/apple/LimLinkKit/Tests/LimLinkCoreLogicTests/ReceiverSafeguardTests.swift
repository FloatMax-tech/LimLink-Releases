import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class ReceiverSafeguardTests: XCTestCase {
    func testRetainedSessionLimitBlocksUnpolledCreatesButAllowsIdempotentRetry() throws {
        var receiver = try makeReceiver(limit: 1)
        XCTAssertEqual(try response(receiver.handle(manifest(key: "first"), peerAddressIsLocal: false, clientFingerprint: "peer")).status, 202)
        XCTAssertEqual(try response(receiver.handle(manifest(key: "second"), peerAddressIsLocal: false, clientFingerprint: "peer")).status, 409)
        XCTAssertEqual(receiver.sessions.count, 1)
        XCTAssertEqual(receiver.sessionIDs, ["sid-2", "sid-3"])
        let retry = try response(receiver.handle(manifest(key: "first"), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(retry.status, 202)
        XCTAssertEqual(JSONWire.object(retry.body).flatMap { JSONWire.string($0, "sessionId") }, "sid-1")
        receiver.decide(sessionID: "sid-1", accept: false)
        let stillFull = try response(receiver.handle(manifest(key: "second"), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(WireApp.decodeError(stillFull.body)?.code, .busy)
    }

    func testDiscardRemovesExactSessionAndItsDeduplicationKey() throws {
        var receiver = try makeReceiver(limit: 2)
        _ = receiver.handle(manifest(key: "first"), peerAddressIsLocal: false, clientFingerprint: "peer")
        _ = receiver.handle(manifest(key: "second"), peerAddressIsLocal: false, clientFingerprint: "peer")
        XCTAssertTrue(receiver.decide(sessionID: "sid-2", accept: true))
        receiver.incomingBodyCutOff(sessionID: "sid-2", fileID: "file", flushed: [97], tail: [])
        let retained = receiver.sessions["sid-2"]
        XCTAssertTrue(receiver.discardSession(sessionID: "sid-1"))
        XCTAssertFalse(receiver.discardSession(sessionID: "sid-1"))
        XCTAssertEqual(receiver.sessions["sid-2"], retained)
        let recreated = try response(receiver.handle(manifest(key: "first"), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(recreated.status, 202)
        XCTAssertEqual(JSONWire.object(recreated.body).flatMap { JSONWire.string($0, "sessionId") }, "sid-3")
    }

    func testDecisionReportsOnlyAnActualPendingTransition() throws {
        var receiver = try makeReceiver()
        XCTAssertFalse(receiver.decide(sessionID: "missing", accept: true))
        _ = receiver.handle(manifest(key: "first"), peerAddressIsLocal: false, clientFingerprint: "peer")
        let cancel = WireApp.request(method: "POST", path: "/limlink/v1/sessions/sid-1/cancel", app: "limlink", hostHeader: "peer", body: JSONWire.data(["sessionId": "sid-1", "reason": "user"]), json: true)
        XCTAssertEqual(try response(receiver.handle(cancel, peerAddressIsLocal: false, clientFingerprint: "peer")).status, 200)
        XCTAssertFalse(receiver.decide(sessionID: "sid-1", accept: true))
        XCTAssertEqual(receiver.sessions["sid-1"]?.phase, .cancelled)
        _ = receiver.handle(manifest(key: "second"), peerAddressIsLocal: false, clientFingerprint: "peer")
        XCTAssertTrue(receiver.decide(sessionID: "sid-2", accept: false))
        XCTAssertFalse(receiver.decide(sessionID: "sid-2", accept: true))
        XCTAssertEqual(receiver.sessions["sid-2"]?.phase, .rejected)
    }

    func testHostSavedNameMustBeExactSafeBasenameOfVerifiedFile() throws {
        var receiver = try makeReceiver()
        _ = receiver.handle(manifest(key: "first"), peerAddressIsLocal: false, clientFingerprint: "peer")
        XCTAssertFalse(receiver.updatePublishedFileName(sessionID: "sid-1", fileName: "note (1).txt"))
        XCTAssertTrue(receiver.decide(sessionID: "sid-1", accept: true))
        let upload = WireApp.request(method: "PUT", path: "/limlink/v1/sessions/sid-1/files/file", app: "limlink", hostHeader: "peer", body: [97, 98, 99], json: false, extra: ["content-type": "application/octet-stream", "x-limlink-token": "tok-1", "x-limlink-offset": "0"])
        XCTAssertEqual(try response(receiver.handle(upload, peerAddressIsLocal: false, clientFingerprint: "peer")).status, 200)
        let complete = WireApp.request(method: "POST", path: "/limlink/v1/sessions/sid-1/files/file/complete", app: "limlink", hostHeader: "peer", body: JSONWire.data(["sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]), json: true)
        XCTAssertEqual(try response(receiver.handle(complete, peerAddressIsLocal: false, clientFingerprint: "peer")).status, 200)
        for invalid in ["../other.txt", "nested/file.txt", "CON.txt", "bad?.txt", "trailing."] {
            XCTAssertFalse(receiver.updatePublishedFileName(sessionID: "sid-1", fileName: invalid))
        }
        XCTAssertTrue(receiver.updatePublishedFileName(sessionID: "sid-1", fileName: "note (1).txt"))
        XCTAssertEqual(receiver.sessions["sid-1"]?.finalName, "note (1).txt")
        XCTAssertEqual(receiver.sessions["sid-1"]?.published, [97, 98, 99])
        XCTAssertTrue(receiver.discardSession(sessionID: "sid-1"))
        XCTAssertFalse(receiver.sessions.keys.contains("sid-1"))
    }

    private func makeReceiver(limit: Int? = nil) throws -> SingleFileReceiver {
        SingleFileReceiver(host: try HostAppIdentity(app: "limlink"), alias: "receiver", trustedFingerprints: ["peer"], sessionIDs: ["sid-1", "sid-2", "sid-3"], tokens: ["tok-1", "tok-2", "tok-3"], maximumRetainedSessions: limit)
    }

    private func manifest(key: String) -> HTTPRequest {
        WireApp.request(method: "POST", path: "/limlink/v1/sessions", app: "limlink", hostHeader: "peer", body: JSONWire.data(["clientSessionKey": key, "transport": "lan", "entries": [["id": "file", "kind": "file", "relativePath": "note.txt", "size": 3]]]), json: true)
    }

    private func response(_ step: ReceiverStep) throws -> HTTPResponse {
        guard case .response(let response) = step else { throw TestFailure.unexpectedPending }
        return response
    }

    private enum TestFailure: Error { case unexpectedPending }
}
