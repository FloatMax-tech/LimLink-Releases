import XCTest
@testable import LimLinkCoreLogic

final class ClientResponseValidationTests: XCTestCase {
    func testCompleteRequiresHTTP200AndVerifiedTrue() throws {
        let invalid = [
            HTTPResponse(status: 202), HTTPResponse(status: 204), HTTPResponse(status: 302),
            HTTPResponse(status: 200), response([:]), response(["verified": false, "finalName": "saved.txt"]),
            response(["verified": 1, "finalName": "saved.txt"]), response(["verified": "true", "finalName": "saved.txt"]),
            response(["verified": true]), response(["verified": true, "finalName": ""]),
            response(["verified": true, "finalName": "saved.txt"], status: 202),
        ]
        for reply in invalid {
            var client = try waitingForComplete()
            assertMalformed(client.receive(reply))
        }
    }

    func testFinishRequiresHTTP200AndAMatchingSuccessfulFileReport() throws {
        var reports: [[String: Any]] = [[:], ["state": "finished"]]
        for (key, value): (String, Any) in [("sessionId", "other"), ("state", "accepted"), ("files", [] as [Any])] {
            var report = validReport()
            report[key] = value
            reports.append(report)
        }
        for (key, value): (String, Any) in [
            ("id", "other"), ("state", "verify_failed"), ("sha256Match", false), ("sha256Match", 1),
            ("size", 4), ("bytesReceived", 2), ("bytesReceived", "3"), ("finalName", "other.txt"),
        ] {
            var report = validReport()
            var file = (report["files"] as! [[String: Any]])[0]
            file[key] = value
            report["files"] = [file]
            reports.append(report)
        }
        for key in ["id", "state", "sha256Match", "size", "bytesReceived", "finalName"] {
            var report = validReport()
            var file = (report["files"] as! [[String: Any]])[0]
            file.removeValue(forKey: key)
            report["files"] = [file]
            reports.append(report)
        }
        for reply in [HTTPResponse(status: 200), HTTPResponse(status: 202), response(validReport(), status: 202)] + reports.map({ response($0) }) {
            var client = try waitingForFinish()
            assertMalformed(client.receive(reply))
        }
    }

    func testMissingAndNonIntegerPutAcknowledgementsFailWithoutAdvancing() throws {
        for body in ["{}", "{\"committedBytes\":\"3\"}", "{\"committedBytes\":true}", "{\"committedBytes\":1.9}", "{\"committedBytes\":null}", ""] {
            var client = try waitingForPut()
            let tick = client.receive(HTTPResponse(status: 200, body: Array(body.utf8)))
            assertMalformed(tick)
            XCTAssertEqual(tick.bytesSent, 0)
        }
    }

    func testPartialAndStalledAcknowledgementsCannotResendAnAlreadySentRange() throws {
        for committed in [0, 1, 2] {
            var client = try waitingForPut()
            let tick = client.receive(response(["committedBytes": committed]))
            assertMalformed(tick)
            XCTAssertEqual(tick.bytesSent, 0)
        }
    }

    func testValidReportCompletesWithTheReceiversSavedName() throws {
        var client = try waitingForFinish()
        let tick = client.receive(response(validReport()))
        XCTAssertEqual(tick.status, .completed(finalName: "saved.txt"))
        XCTAssertEqual(tick.bytesSent, 3)
        XCTAssertNil(tick.request)
    }

    func testApprovalWaitEndsAfterAcceptanceAndDoesNotRestartOnResumePoll() throws {
        var client = try waitingForInitialPoll()
        XCTAssertTrue(client.isAwaitingApproval)
        _ = client.receive(HTTPResponse(status: 202))
        XCTAssertTrue(client.isAwaitingApproval)
        _ = client.receive(response(["state": "accepted", "files": ["file": ["token": "token", "offset": 0]]]))
        XCTAssertFalse(client.isAwaitingApproval)
        _ = client.receive(WireApp.errorResponse(ProtocolError(code: .sessionPaused, httpStatus: 409, retryable: true)))
        XCTAssertFalse(client.isAwaitingApproval)
        let poll = client.continueAfterPeer()
        XCTAssertEqual(poll.request?.method, "GET")
        XCTAssertFalse(client.isAwaitingApproval)
    }

    private func waitingForPut() throws -> SingleFileClient {
        var client = try waitingForInitialPoll()
        _ = client.receive(response(["state": "accepted", "files": ["file": ["token": "token", "offset": 0]]]))
        return client
    }

    private func waitingForInitialPoll() throws -> SingleFileClient {
        var client = SingleFileClient(
            local: try HostAppIdentity(app: "limlink"), localAlias: "sender",
            peerHost: "192.168.1.2", deviceName: "receiver", intent: .userTap,
            timestamp: "2026-10-10T12:00:00Z", fileID: "file", relativePath: "test.txt",
            bytes: [97, 98, 99], clientSessionKey: "client"
        )
        _ = client.start()
        _ = client.receive(WireApp.helloResponse(app: "limlink", alias: "receiver", devType: "iphone", port: 52470, trusted: true, busy: false))
        _ = client.receive(response(["sessionId": "session", "state": "pending"], status: 202))
        return client
    }

    private func waitingForComplete() throws -> SingleFileClient {
        var client = try waitingForPut()
        _ = client.receive(response(["committedBytes": 3]))
        return client
    }

    private func waitingForFinish() throws -> SingleFileClient {
        var client = try waitingForComplete()
        _ = client.receive(response(["verified": true, "finalName": "saved.txt"]))
        return client
    }

    private func validReport() -> [String: Any] {
        [
            "sessionId": "session", "state": "finished", "startedAt": "2026-10-10T12:00:00Z",
            "finishedAt": "2026-10-10T12:00:01Z", "durationMs": 1000,
            "totals": ["files": 1, "completed": 1, "failed": 0, "verifyFailed": 0, "rejected": 0, "cancelled": 0, "bytesPlanned": 3, "bytesReceived": 3],
            "files": [["id": "file", "relativePath": "test.txt", "finalName": "saved.txt", "renamed": true, "state": "completed", "size": 3, "bytesReceived": 3, "sha256Match": true, "errorCode": NSNull()]],
        ]
    }

    private func response(_ body: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: JSONWire.data(body))
    }

    private func assertMalformed(_ tick: SingleFileClientTick, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(.wire(let error)) = tick.status else {
            return XCTFail("An invalid acknowledgement must fail, got \(tick.status)", file: file, line: line)
        }
        XCTAssertEqual(error.code, .badRequest, file: file, line: line)
        XCTAssertNil(tick.request, file: file, line: line)
    }
}
