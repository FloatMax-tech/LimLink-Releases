import XCTest
@testable import LimLinkCoreLogic

final class ClientOffsetTests: XCTestCase {
    func testInvalidAcceptedOffsetsFailWithoutCreatingAPut() throws {
        for offset in [-1, 4, Int.max] {
            var client = try waitingForPoll()
            let tick = client.receive(accepted(offset: offset))
            assertMalformed(tick)
        }
    }

    func testInvalidPutAcknowledgementsFailWithoutResendingOrCompleting() throws {
        for offset in [-1, 4, Int.max] {
            var client = try waitingForPoll()
            _ = client.receive(accepted(offset: 0))
            let tick = client.receive(response(["committedBytes": offset]))
            assertMalformed(tick)
        }
    }

    func testInvalidPauseAcknowledgementCannotBecomeAResumeOffset() throws {
        for offset in [-1, 4, Int.max] {
            var client = try waitingForPoll()
            _ = client.receive(accepted(offset: 0))
            _ = client.pause(reason: "app_background")
            let tick = client.receive(control(offset: offset))
            assertMalformed(tick)
        }
    }

    func testInvalidResumeAcknowledgementCannotCreateAPut() throws {
        for offset in [-1, 4, Int.max] {
            var client = try waitingForPoll()
            _ = client.receive(accepted(offset: 0))
            _ = client.pause(reason: "app_background")
            _ = client.receive(control(offset: 0))
            _ = client.resume()
            let tick = client.receive(control(offset: offset))
            assertMalformed(tick)
        }
    }

    func testZeroAndEndOffsetsRemainValid() throws {
        let bytes: [UInt8] = [97, 98, 99]
        for offset in [0, 3] {
            var client = try waitingForPoll()
            let tick = client.receive(accepted(offset: offset))
            XCTAssertEqual(tick.status, .inProgress)
            XCTAssertEqual(tick.request?.method, "PUT")
            XCTAssertEqual(tick.request?.body, Array(bytes.dropFirst(offset)))
        }
    }

    func testPresentMalformedOffsetsFailInAcceptedPauseAndResumeResponses() throws {
        for literal in ["1.9", "-0.9", "true", "\"1\"", "null", "18446744073709551616"] {
            var acceptedClient = try waitingForPoll()
            assertMalformed(acceptedClient.receive(HTTPResponse(status: 200, body: Array("{\"state\":\"accepted\",\"files\":{\"file\":{\"token\":\"token\",\"offset\":\(literal)}}}".utf8))))

            var pauseClient = try waitingForPoll()
            _ = pauseClient.receive(accepted(offset: 0))
            _ = pauseClient.pause(reason: "app_background")
            let control = HTTPResponse(status: 200, body: Array("{\"state\":\"paused\",\"files\":{\"file\":{\"committedBytes\":\(literal)}}}".utf8))
            assertMalformed(pauseClient.receive(control))

            var resumeClient = try waitingForPoll()
            _ = resumeClient.receive(accepted(offset: 0))
            _ = resumeClient.pause(reason: "app_background")
            _ = resumeClient.receive(self.control(offset: 0))
            _ = resumeClient.resume()
            assertMalformed(resumeClient.receive(control))
        }
    }

    private func waitingForPoll() throws -> SingleFileClient {
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

    private func accepted(offset: Int) -> HTTPResponse {
        response(["state": "accepted", "files": ["file": ["token": "token", "offset": offset]]])
    }

    private func control(offset: Int) -> HTTPResponse {
        response(["state": "paused", "files": ["file": ["committedBytes": offset]]])
    }

    private func response(_ body: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: JSONWire.data(body))
    }

    private func assertMalformed(_ tick: SingleFileClientTick, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(.wire(let error)) = tick.status else {
            XCTFail("Invalid peer offsets must fail the transfer", file: file, line: line)
            return
        }
        XCTAssertEqual(error.code, .badRequest, file: file, line: line)
        XCTAssertNil(tick.request, file: file, line: line)
        XCTAssertGreaterThanOrEqual(tick.bytesSent, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(tick.bytesSent, tick.bytesTotal, file: file, line: line)
    }
}
