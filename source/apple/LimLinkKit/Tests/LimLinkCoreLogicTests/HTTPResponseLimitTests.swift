import XCTest
import LimLinkCoreLogic

final class HTTPResponseLimitTests: XCTestCase {
    func testHeaderLimitIncludesDelimiterAndAcceptsExactBoundary() throws {
        let bytes = Array("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseResponse(bytes, limits: HTTPResponseLimits(maximumHeaderBytes: bytes.count - 1))) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
        let (response, consumed) = try HTTPCodec.parseResponse(bytes, limits: HTTPResponseLimits(maximumHeaderBytes: bytes.count))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, [])
        XCTAssertEqual(consumed, bytes.count)
    }

    func testFragmentedHeaderIsRejectedWhenAccumulatedBytesReachLimit() {
        let prefix = Array("HTTP/1.1 200 OK\r\nX: y\r\n\r".utf8)
        let limits = HTTPResponseLimits(maximumHeaderBytes: prefix.count)
        XCTAssertThrowsError(try HTTPCodec.parseResponse(Array(prefix.dropLast()), limits: limits)) {
            XCTAssertEqual($0 as? HTTPCodecError, .incomplete)
        }
        XCTAssertThrowsError(try HTTPCodec.parseResponse(prefix, limits: limits)) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
        XCTAssertThrowsError(try HTTPCodec.parseResponse(prefix + [10], limits: limits)) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
        XCTAssertThrowsError(try HTTPCodec.parseResponse([], limits: HTTPResponseLimits(maximumHeaderBytes: 0))) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
    }

    func testOversizedDeclaredBodyIsRejectedBeforeReceivingBody() {
        let bytes = Array("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseResponse(bytes, limits: HTTPResponseLimits(maximumBodyBytes: 10))) {
            XCTAssertEqual($0 as? HTTPCodecError, .bodyTooLarge)
        }
    }

    func testAllowedIncompleteBodyStillReportsIncomplete() {
        let bytes = Array("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nab".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseResponse(bytes, limits: HTTPResponseLimits(maximumBodyBytes: 3))) {
            XCTAssertEqual($0 as? HTTPCodecError, .incomplete)
        }
    }

    func testBodyLimitsAcceptExactBoundaryAndEmptyBodies() throws {
        let bytes = Array("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc".utf8)
        let (response, consumed) = try HTTPCodec.parseResponse(bytes, limits: HTTPResponseLimits(maximumBodyBytes: 3))
        XCTAssertEqual(response.body, [97, 98, 99])
        XCTAssertEqual(consumed, bytes.count)

        for text in ["HTTP/1.1 204 No Content\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"] {
            let emptyBytes = Array(text.utf8)
            let (emptyResponse, emptyConsumed) = try HTTPCodec.parseResponse(emptyBytes, limits: HTTPResponseLimits(maximumBodyBytes: 0))
            XCTAssertEqual(emptyResponse.body, [])
            XCTAssertEqual(emptyConsumed, emptyBytes.count)
        }
    }

    func testContentLengthOverflowIsRejectedWithoutWaitingOrTrapping() {
        let maximumLength = Array("HTTP/1.1 200 OK\r\nContent-Length: \(Int.max)\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseResponse(maximumLength, limits: HTTPResponseLimits(maximumBodyBytes: 10))) {
            XCTAssertEqual($0 as? HTTPCodecError, .bodyTooLarge)
        }
        XCTAssertThrowsError(try HTTPCodec.parseResponse(maximumLength, limits: .unlimited)) {
            XCTAssertEqual($0 as? HTTPCodecError, .malformed)
        }
        let outsideIntegerRange = Array("HTTP/1.1 200 OK\r\nContent-Length: \(Int.max)0\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseResponse(outsideIntegerRange, limits: HTTPResponseLimits(maximumBodyBytes: 10))) {
            XCTAssertEqual($0 as? HTTPCodecError, .malformed)
        }
    }

    func testLimitsPreserveExistingResponseHeaderFraming() throws {
        let bytes = Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\nContent-Length: 11\r\ncontent-length: +3\r\n\r\nabc".utf8)
        let (response, consumed) = try HTTPCodec.parseResponse(bytes, limits: HTTPResponseLimits(maximumBodyBytes: 3))
        XCTAssertEqual(response.body, [97, 98, 99])
        XCTAssertEqual(response.value(for: "Content-Length"), "+3")
        XCTAssertEqual(response.value(for: "Transfer-Encoding"), "identity")
        XCTAssertEqual(consumed, bytes.count)
    }

    func testDefaultLimitsAndPipelinedSuffixPreserveResponseParsing() throws {
        let header = Array("HTTP/1.1 202 Accepted\r\nContent-Length: 3\r\n\r\n".utf8)
        let first = header + [97, 98, 99]
        let second = Array("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nX-Long: another header\r\n\r\nabcdefghijk".utf8)
        let combined = first + second
        let (response, consumed) = try HTTPCodec.parseResponse(combined, limits: HTTPResponseLimits(maximumHeaderBytes: header.count, maximumBodyBytes: 3))
        XCTAssertEqual(response.status, 202)
        XCTAssertEqual(response.body, [97, 98, 99])
        XCTAssertEqual(consumed, first.count)
        let (nextResponse, nextConsumed) = try HTTPCodec.parseResponse(Array(combined.dropFirst(consumed)))
        XCTAssertEqual(nextResponse.status, 200)
        XCTAssertEqual(nextResponse.body, Array("abcdefghijk".utf8))
        XCTAssertEqual(nextConsumed, second.count)
        XCTAssertEqual(try HTTPCodec.parseResponse(second, limits: .unlimited).0, nextResponse)
    }
}
