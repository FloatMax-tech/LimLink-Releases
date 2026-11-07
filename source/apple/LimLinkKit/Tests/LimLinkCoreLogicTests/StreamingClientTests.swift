import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class StreamingClientTests: XCTestCase {
    func testLargePayloadIsSplitIntoBoundedPutRequestsBeforeCompletion() throws {
        let bytes = [UInt8](repeating: 97, count: 1_048_576) + [98, 99]
        var client = try waitingForPoll(bytes: bytes)
        let first = client.receive(accepted(offset: 0))
        XCTAssertEqual(first.request?.body.count, 1_048_576)
        XCTAssertEqual(first.request?.value(for: "x-limlink-offset"), "0")
        XCTAssertEqual(first.bytesTotal, 1_048_578)

        let second = client.receive(response(["committedBytes": 1_048_576]))
        XCTAssertEqual(second.request?.body, [98, 99])
        XCTAssertEqual(second.request?.value(for: "x-limlink-offset"), "1048576")
        XCTAssertEqual(second.bytesSent, 1_048_576)

        let complete = client.receive(response(["committedBytes": 1_048_578]))
        XCTAssertEqual(complete.request?.target, "/limlink/v1/sessions/session/files/file/complete")
        XCTAssertEqual(complete.bytesSent, 1_048_578)
    }

    func testPutAcknowledgementMustMatchExactlyTheSentRange() throws {
        let bytes = [UInt8](repeating: 97, count: 1_048_578)
        for committed in [0, 1, 1_048_575, 1_048_577, 1_048_578] {
            var client = try waitingForPoll(bytes: bytes)
            _ = client.receive(accepted(offset: 0))
            assertMalformed(client.receive(response(["committedBytes": committed])))
        }
    }

    func testPutAcknowledgementCannotRegressAfterAResumedOffset() throws {
        var client = try waitingForPoll(bytes: [97, 98, 99])
        _ = client.receive(accepted(offset: 1))
        assertMalformed(client.receive(response(["committedBytes": 0])))
    }

    func testFileSourceReadFailureFailsLocallyWithoutSendingAPut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([97, 98, 99]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try TransferSource(fileURL: url, size: 3, sha256Hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var client = try waitingForPoll(source: source)
        try Data([97]).write(to: url)
        let tick = client.receive(accepted(offset: 0))
        guard case .failed(.wire(let error)) = tick.status else {
            return XCTFail("A truncated source must stop the sender")
        }
        XCTAssertEqual(error.code, .internal)
        XCTAssertEqual(error.detail["reason"], "source_read_failed")
        XCTAssertNil(error.httpStatus)
        XCTAssertNil(tick.request)
    }

    func testFiveGBFileMetadataAndResumedTailDoNotRequireInMemoryBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 5_000_000_000)
        try handle.seek(toOffset: 4_999_999_997)
        try handle.write(contentsOf: Data([97, 98, 99]))
        try handle.close()
        let checksum = String(repeating: "a", count: 64)
        let source = try TransferSource(fileURL: url, size: 5_000_000_000, sha256Hex: checksum)
        var client = try makeClient(source: source)
        XCTAssertTrue(client.bytes.isEmpty)
        _ = client.start()
        let create = client.receive(WireApp.helloResponse(app: "limlink", alias: "receiver", devType: "iphone", port: 52470, trusted: true, busy: false))
        let manifest = try XCTUnwrap(JSONWire.object(try XCTUnwrap(create.request).body))
        XCTAssertEqual(JSONWire.int(manifest, "totalBytes"), 5_000_000_000)
        _ = client.receive(response(["sessionId": "session", "state": "pending"], status: 202))
        let tail = client.receive(accepted(offset: 4_999_999_997))
        XCTAssertEqual(tail.request?.body, [97, 98, 99])
        XCTAssertEqual(tail.request?.value(for: "x-limlink-offset"), "4999999997")
        XCTAssertEqual(tail.bytesTotal, 5_000_000_000)
        let complete = client.receive(response(["committedBytes": 5_000_000_000]))
        XCTAssertEqual(JSONWire.object(try XCTUnwrap(complete.request).body)?["sha256"] as? String, checksum)
        XCTAssertEqual(complete.bytesSent, 5_000_000_000)
    }

    private func waitingForPoll(bytes: [UInt8]) throws -> SingleFileClient {
        try waitingForPoll(source: TransferSource(bytes: bytes))
    }

    private func makeClient(source: TransferSource) throws -> SingleFileClient {
        SingleFileClient(
            local: try HostAppIdentity(app: "limlink"), localAlias: "sender",
            peerHost: "192.168.1.2", deviceName: "receiver", intent: .userTap,
            timestamp: "2026-10-10T12:00:00Z", fileID: "file", relativePath: "test.txt",
            source: source, clientSessionKey: "client"
        )
    }

    private func waitingForPoll(source: TransferSource) throws -> SingleFileClient {
        var client = try makeClient(source: source)
        _ = client.start()
        _ = client.receive(WireApp.helloResponse(app: "limlink", alias: "receiver", devType: "iphone", port: 52470, trusted: true, busy: false))
        _ = client.receive(response(["sessionId": "session", "state": "pending"], status: 202))
        return client
    }

    private func accepted(offset: Int) -> HTTPResponse {
        response(["state": "accepted", "files": ["file": ["token": "token", "offset": offset]]])
    }

    private func response(_ body: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: JSONWire.data(body))
    }

    private func assertMalformed(_ tick: SingleFileClientTick, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(.wire(let error)) = tick.status else {
            return XCTFail("A mismatched chunk acknowledgement must fail", file: file, line: line)
        }
        XCTAssertEqual(error.code, .badRequest, file: file, line: line)
        XCTAssertNil(tick.request, file: file, line: line)
    }
}
