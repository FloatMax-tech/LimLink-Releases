import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class ReceiverOwnershipTests: XCTestCase {
    func testOtherTrustedFingerprintCannotReadOrMutateAnySessionRoute() throws {
        let routes: [(String, HTTPRequest, Bool, Bool)] = [
            ("poll", request("GET", "/sid-1?wait=0"), false, false),
            ("progress", request("GET", "/sid-1/files/file"), false, false),
            ("pause", control("pause"), false, false),
            ("resume", control("resume"), false, false),
            ("cancel", control("cancel"), false, false),
            ("skip", request("POST", "/sid-1/files/file/skip", body: JSONWire.data(["sessionId": "sid-1", "reason": "user"])), false, false),
            ("put", upload(), false, false),
            ("complete", complete(), true, false),
            ("finish", request("POST", "/sid-1/finish"), true, true),
        ]
        for (name, operation, uploaded, completed) in routes {
            var receiver = try makeReceiver()
            _ = receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a")
            XCTAssertTrue(receiver.decide(sessionID: "sid-1", accept: true))
            if uploaded { _ = receiver.handle(upload(), peerAddressIsLocal: false, clientFingerprint: "peer-a") }
            if completed { _ = receiver.handle(complete(), peerAddressIsLocal: false, clientFingerprint: "peer-a") }
            let before = receiver.sessions
            let denied = try response(receiver.handle(operation, peerAddressIsLocal: false, clientFingerprint: "peer-b"))
            XCTAssertEqual(denied.status, 404, name)
            XCTAssertEqual(WireApp.decodeError(denied.body)?.code, .sessionNotFound, name)
            XCTAssertEqual(receiver.sessions, before, name)
            let ownerPoll = try response(receiver.handle(request("GET", "/sid-1?wait=0"), peerAddressIsLocal: false, clientFingerprint: "peer-a"))
            XCTAssertEqual(ownerPoll.status, 200, name)
        }
    }

    func testSameClientSessionKeyFromDifferentFingerprintsCreatesIndependentSessions() throws {
        var receiver = try makeReceiver()
        let first = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a"))
        let second = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-b"))
        XCTAssertEqual(sessionID(first), "sid-1")
        XCTAssertEqual(sessionID(second), "sid-2")
        XCTAssertEqual(receiver.sessions.count, 2)
        let retry = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a"))
        XCTAssertEqual(sessionID(retry), "sid-1")
    }

    func testSiblingStrictConnectionCannotUseOwnerTokenOrFinishItsSession() throws {
        var receiver = try makeReceiver()
        _ = receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first")
        XCTAssertTrue(receiver.decide(sessionID: "sid-1", accept: true))
        for operation in [request("GET", "/sid-1?wait=0"), upload(), complete(), control("cancel")] {
            let denied = try response(receiver.handle(operation, peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "second"))
            XCTAssertEqual(WireApp.decodeError(denied.body)?.code, .sessionNotFound)
        }
        XCTAssertEqual(try response(receiver.handle(upload(), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first")).status, 200)
        XCTAssertEqual(try response(receiver.handle(complete(), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first")).status, 200)
        let finish = request("POST", "/sid-1/finish")
        XCTAssertEqual(WireApp.decodeError(try response(receiver.handle(finish, peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "second")).body)?.code, .sessionNotFound)
        XCTAssertEqual(try response(receiver.handle(finish, peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first")).status, 200)
    }

    func testIdempotencyKeyIncludesFingerprintAndStrictConnectionScope() throws {
        var receiver = try makeReceiver()
        let first = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first"))
        let sibling = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "second"))
        let other = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-b", connectionScope: "first"))
        XCTAssertEqual(sessionID(first), "sid-1")
        XCTAssertEqual(sessionID(sibling), "sid-2")
        XCTAssertEqual(sessionID(other), "sid-3")
        let retry = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first"))
        XCTAssertEqual(sessionID(retry), "sid-1")
    }

    func testLegacySameFingerprintReconnectCanResumeButOtherFingerprintCannot() throws {
        var receiver = try makeReceiver()
        _ = receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a")
        XCTAssertTrue(receiver.decide(sessionID: "sid-1", accept: true))
        receiver.incomingBodyCutOff(sessionID: "sid-1", fileID: "file", flushed: [97], tail: [98])
        receiver.noteDisconnected(sessionID: "sid-1")
        let retried = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a"))
        XCTAssertEqual(sessionID(retried), "sid-1")
        let resumed = try response(receiver.handle(request("GET", "/sid-1/files/file"), peerAddressIsLocal: false, clientFingerprint: "peer-a"))
        XCTAssertEqual(JSONWire.object(resumed.body).flatMap { JSONWire.int($0, "committedBytes") }, 1)
        let denied = try response(receiver.handle(request("GET", "/sid-1/files/file"), peerAddressIsLocal: false, clientFingerprint: "peer-b"))
        XCTAssertEqual(WireApp.decodeError(denied.body)?.code, .sessionNotFound)
    }

    func testDiscardReleasesOwnershipAndScopedIdempotency() throws {
        var receiver = try makeReceiver()
        _ = receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first")
        XCTAssertTrue(receiver.discardSession(sessionID: "sid-1"))
        let old = try response(receiver.handle(request("GET", "/sid-1?wait=0"), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first"))
        XCTAssertEqual(WireApp.decodeError(old.body)?.code, .sessionNotFound)
        let recreated = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "first"))
        XCTAssertEqual(sessionID(recreated), "sid-2")
        let sibling = try response(receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a", connectionScope: "second"))
        XCTAssertEqual(sessionID(sibling), "sid-3")
    }

    func testDurablePublicationBlocksSessionObservationUntilSavedNameIsRecorded() throws {
        var receiver = try makeReceiver()
        _ = receiver.handle(manifest(key: "shared"), peerAddressIsLocal: false, clientFingerprint: "peer-a")
        XCTAssertTrue(receiver.decide(sessionID: "sid-1", accept: true))
        _ = receiver.handle(upload(), peerAddressIsLocal: false, clientFingerprint: "peer-a")
        XCTAssertEqual(try response(receiver.handle(complete(), peerAddressIsLocal: false, clientFingerprint: "peer-a", deferPublication: true)).status, 200)
        for operation in [request("GET", "/sid-1?wait=0"), request("GET", "/sid-1/files/file"), request("POST", "/sid-1/finish")] {
            let blocked = try response(receiver.handle(operation, peerAddressIsLocal: false, clientFingerprint: "peer-a"))
            XCTAssertEqual(WireApp.decodeError(blocked.body)?.code, .invalidState)
        }
        XCTAssertFalse(receiver.updatePublishedFileName(sessionID: "sid-1", fileName: "../bad.txt"))
        XCTAssertEqual(WireApp.decodeError(try response(receiver.handle(request("POST", "/sid-1/finish"), peerAddressIsLocal: false, clientFingerprint: "peer-a")).body)?.code, .invalidState)
        XCTAssertTrue(receiver.updatePublishedFileName(sessionID: "sid-1", fileName: "note (1).txt"))
        let finished = try response(receiver.handle(request("POST", "/sid-1/finish"), peerAddressIsLocal: false, clientFingerprint: "peer-a"))
        XCTAssertEqual(finished.status, 200)
        let object = try XCTUnwrap(JSONWire.object(finished.body))
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["finalName"] as? String, "note (1).txt")
    }

    private func makeReceiver() throws -> SingleFileReceiver {
        SingleFileReceiver(host: try HostAppIdentity(app: "limlink"), alias: "receiver", trustedFingerprints: ["peer-a", "peer-b"], sessionIDs: ["sid-1", "sid-2", "sid-3"], tokens: ["tok-1", "tok-2", "tok-3"])
    }

    private func manifest(key: String) -> HTTPRequest {
        request("POST", "", body: JSONWire.data(["clientSessionKey": key, "transport": "lan", "entries": [["id": "file", "kind": "file", "relativePath": "note.txt", "size": 3]]]))
    }

    private func control(_ action: String) -> HTTPRequest {
        request("POST", "/sid-1/\(action)", body: JSONWire.data(["sessionId": "sid-1", "reason": "user"]))
    }

    private func upload() -> HTTPRequest {
        WireApp.request(method: "PUT", path: "/limlink/v1/sessions/sid-1/files/file", app: "limlink", hostHeader: "peer", body: [97, 98, 99], json: false, extra: ["content-type": "application/octet-stream", "x-limlink-token": "tok-1", "x-limlink-offset": "0"])
    }

    private func complete() -> HTTPRequest {
        request("POST", "/sid-1/files/file/complete", body: JSONWire.data(["sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]))
    }

    private func request(_ method: String, _ suffix: String, body: [UInt8] = []) -> HTTPRequest {
        WireApp.request(method: method, path: "/limlink/v1/sessions\(suffix)", app: "limlink", hostHeader: "peer", body: body, json: method == "POST")
    }

    private func sessionID(_ response: HTTPResponse) -> String? {
        JSONWire.object(response.body).flatMap { JSONWire.string($0, "sessionId") }
    }

    private func response(_ step: ReceiverStep) throws -> HTTPResponse {
        guard case .response(let response) = step else { throw TestFailure.unexpectedPending }
        return response
    }

    private enum TestFailure: Error { case unexpectedPending }
}
