import Network
import XCTest
@testable import LimLinkKit

final class FramedResponseLimitTests: XCTestCase {
    func testBufferedResponseRejectsBodyOverHostLimit() async throws {
        let connection = try bufferOnlyConnection()
        defer { connection.cancel() }
        var buffer = Array("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabcde".utf8)
        do {
            _ = try await FramedExchange.readResponse(connection, buffer: &buffer, limits: HTTPResponseLimits(maximumBodyBytes: 4))
            XCTFail("response body exceeded the host limit")
        } catch {
            XCTAssertEqual(error as? HTTPCodecError, .bodyTooLarge)
        }
    }

    func testBufferedResponseRejectsHeaderOverHostLimit() async throws {
        let connection = try bufferOnlyConnection()
        defer { connection.cancel() }
        var buffer = Array("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        let limit = buffer.count - 1
        do {
            _ = try await FramedExchange.readResponse(connection, buffer: &buffer, limits: HTTPResponseLimits(maximumHeaderBytes: limit))
            XCTFail("response header exceeded the host limit")
        } catch {
            XCTAssertEqual(error as? HTTPCodecError, .headerTooLarge)
        }
    }

    func testBufferedResponseConsumesOnlyTheBoundedFirstFrame() async throws {
        let connection = try bufferOnlyConnection()
        defer { connection.cancel() }
        let header = Array("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n".utf8)
        let tail = Array("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n".utf8)
        var buffer = header + [97, 98, 99] + tail
        let response = try await FramedExchange.readResponse(connection, buffer: &buffer, limits: HTTPResponseLimits(maximumHeaderBytes: header.count, maximumBodyBytes: 3))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, [97, 98, 99])
        XCTAssertEqual(buffer, tail)
    }

    /// No listener or handshake is involved: every test supplies a complete buffered frame.
    private func bufferOnlyConnection() throws -> LimLinkConnection {
        LimLinkConnection(
            peerFingerprint: try Fingerprint(rawSHA256: [UInt8](repeating: 0, count: 32)),
            negotiatedVersionRaw: 0,
            earlyDataAccepted: false,
            negotiatedALPN: nil,
            verifyObservation: VerifyBlockObservation(negotiatedVersionRaw: 0, versionWasAvailable: false, earlyDataAccepted: false, sawCertificate: false, acceptedFingerprint: false),
            connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        )
    }
}
