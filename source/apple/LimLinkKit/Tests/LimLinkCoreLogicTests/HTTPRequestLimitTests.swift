import XCTest
@testable import LimLinkCoreLogic

final class HTTPRequestLimitTests: XCTestCase {
    func testHeaderLimitIncludesDelimiterAndAcceptsExactBoundary() throws {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes, limits: HTTPRequestLimits(maximumHeaderBytes: bytes.count - 1))) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
        let (request, consumed) = try HTTPCodec.parseRequest(bytes, limits: HTTPRequestLimits(maximumHeaderBytes: bytes.count))
        XCTAssertEqual(request.target, "/offer")
        XCTAssertEqual(request.body, [])
        XCTAssertEqual(consumed, bytes.count)
    }

    func testIncompleteHeaderIsRejectedAsSoonAsAccumulatedBytesReachLimit() {
        let bytes = Array("GET / HTTP/1.1\r\nX-Fill: abcdefghijklmnopq".utf8)
        let limits = HTTPRequestLimits(maximumHeaderBytes: bytes.count)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(Array(bytes.dropLast()), limits: limits)) {
            XCTAssertEqual($0 as? HTTPCodecError, .incomplete)
        }
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes, limits: limits)) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes + [97], limits: limits)) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
    }

    func testSplitDelimiterCannotExtendPastHeaderLimit() {
        let prefix = Array("GET / HTTP/1.1\r\nX: y\r\n\r".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(prefix, limits: HTTPRequestLimits(maximumHeaderBytes: prefix.count))) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
        XCTAssertThrowsError(try HTTPCodec.parseRequest(prefix + [10], limits: HTTPRequestLimits(maximumHeaderBytes: prefix.count))) {
            XCTAssertEqual($0 as? HTTPCodecError, .headerTooLarge)
        }
    }

    func testOversizedDeclaredBodyIsRejectedBeforeReceivingBody() {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes, limits: HTTPRequestLimits(maximumBodyBytes: 10))) {
            XCTAssertEqual($0 as? HTTPCodecError, .bodyTooLarge)
        }
    }

    func testBodyExactlyAtLimitIsAccepted() throws {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc".utf8)
        let (request, consumed) = try HTTPCodec.parseRequest(bytes, limits: HTTPRequestLimits(maximumBodyBytes: 3))
        XCTAssertEqual(request.body, [97, 98, 99])
        XCTAssertEqual(consumed, bytes.count)
    }

    func testZeroBodyLimitAcceptsDeclaredAndImplicitEmptyBodies() throws {
        for text in ["GET / HTTP/1.1\r\n\r\n", "POST /offer HTTP/1.1\r\nContent-Length: 0\r\n\r\n"] {
            let bytes = Array(text.utf8)
            let (request, consumed) = try HTTPCodec.parseRequest(bytes, limits: HTTPRequestLimits(maximumBodyBytes: 0))
            XCTAssertEqual(request.body, [])
            XCTAssertEqual(consumed, bytes.count)
        }
    }

    func testAllowedButIncompleteBodyStillReportsIncomplete() {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: 3\r\n\r\nab".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes, limits: HTTPRequestLimits(maximumBodyBytes: 3))) {
            XCTAssertEqual($0 as? HTTPCodecError, .incomplete)
        }
    }

    func testDefaultLimitsPreserveUnboundedRequestParsing() throws {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: 11\r\n\r\nabcdefghijk".utf8)
        let (request, consumed) = try HTTPCodec.parseRequest(bytes)
        XCTAssertEqual(request.body, Array("abcdefghijk".utf8))
        XCTAssertEqual(consumed, bytes.count)
        XCTAssertEqual(try HTTPCodec.parseRequest(bytes, limits: .unlimited).0, request)
    }

    func testPipelinedBytesDoNotCountAgainstFirstRequestLimits() throws {
        let header = Array("POST /offer HTTP/1.1\r\nContent-Length: 3\r\n\r\n".utf8)
        let first = header + [97, 98, 99]
        let second = Array("POST /next HTTP/1.1\r\nContent-Length: 30\r\nX-Long: another header\r\n\r\n012345678901234567890123456789".utf8)
        let (request, consumed) = try HTTPCodec.parseRequest(first + second, limits: HTTPRequestLimits(maximumHeaderBytes: header.count, maximumBodyBytes: 3))
        XCTAssertEqual(request.target, "/offer")
        XCTAssertEqual(request.body, [97, 98, 99])
        XCTAssertEqual(consumed, first.count)
        XCTAssertEqual(try HTTPCodec.parseRequest(Array((first + second).dropFirst(consumed))).0.target, "/next")
    }

    func testMaximumIntegerContentLengthRejectsTotalLengthOverflow() {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: \(Int.max)\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes)) {
            XCTAssertEqual($0 as? HTTPCodecError, .malformed)
        }
    }

    func testOversizedMaximumIntegerContentLengthUsesBodyLimitError() {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: \(Int.max)\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes, limits: HTTPRequestLimits(maximumBodyBytes: 10))) {
            XCTAssertEqual($0 as? HTTPCodecError, .bodyTooLarge)
        }
    }

    func testContentLengthOutsideIntegerRangeIsMalformed() {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: \(Int.max)0\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes, limits: HTTPRequestLimits(maximumBodyBytes: 10))) {
            XCTAssertEqual($0 as? HTTPCodecError, .malformed)
        }
    }

    func testDuplicateContentLengthIsRejectedEvenWhenValuesMatch() {
        let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes)) {
            XCTAssertEqual($0 as? HTTPCodecError, .malformed)
        }
    }

    func testRequestTransferEncodingIsRejectedWithOrWithoutContentLength() {
        for text in [
            "POST /offer HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            "POST /offer HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n"
        ] {
            XCTAssertThrowsError(try HTTPCodec.parseRequest(Array(text.utf8))) {
                XCTAssertEqual($0 as? HTTPCodecError, .malformed)
            }
        }
    }

    func testRequestContentLengthRequiresUnsignedDecimalDigits() {
        for value in ["+1", "-0", "1, 1", ""] {
            let bytes = Array("POST /offer HTTP/1.1\r\nContent-Length: \(value)\r\n\r\na".utf8)
            XCTAssertThrowsError(try HTTPCodec.parseRequest(bytes)) {
                XCTAssertEqual($0 as? HTTPCodecError, .malformed)
            }
        }
    }

    func testResponseParserRejectsTotalLengthOverflowWithoutTrap() {
        let bytes = Array("HTTP/1.1 200 OK\r\nContent-Length: \(Int.max)\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPCodec.parseResponse(bytes)) {
            XCTAssertEqual($0 as? HTTPCodecError, .malformed)
        }
    }

    func testResponseParserPreservesExistingHeaderFramingBehavior() throws {
        let bytes = Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\nContent-Length: 0\r\ncontent-length: 1\r\n\r\na".utf8)
        let (response, consumed) = try HTTPCodec.parseResponse(bytes)
        XCTAssertEqual(response.body, [97])
        XCTAssertEqual(consumed, bytes.count)
    }
}
