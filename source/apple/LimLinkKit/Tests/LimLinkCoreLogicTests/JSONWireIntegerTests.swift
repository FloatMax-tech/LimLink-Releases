import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class JSONWireIntegerTests: XCTestCase {
    func testFractionalAndOutOfRangeJSONNumbersNeverBecomeIntegers() throws {
        for literal in ["1.9", "-0.9", "9007199254740993.1", "9223372036854775807.1", "9223372036854775808", "-9223372036854775809", "18446744073709551616", "1e100", "1e-100", "1.00000000000000000000000000000000000000000000000000001"] {
            let object = try XCTUnwrap(JSONWire.object(Array("{\"value\":\(literal)}".utf8)))
            XCTAssertNil(JSONWire.int(object, "value"), literal)
        }
    }

    func testExactIntegersKeepTheirValueAcrossDecimalAndExponentForms() throws {
        let cases: [(String, Int)] = [
            ("0", 0), ("1", 1), ("-1", -1), ("1.0", 1), ("10e-1", 1),
            ("9007199254740993", 9_007_199_254_740_993),
            ("9007199254740993.0", 9_007_199_254_740_993),
            ("90071992547409930e-1", 9_007_199_254_740_993),
            ("9223372036854775807", Int.max), ("9223372036854775807.0", Int.max),
            ("92233720368547758070e-1", Int.max),
            ("-9223372036854775808", Int.min), ("-9223372036854775808.0", Int.min),
            ("-0.0e100", 0),
        ]
        for (literal, expected) in cases {
            let object = try XCTUnwrap(JSONWire.object(Array("{\"value\":\(literal)}".utf8)))
            XCTAssertEqual(JSONWire.int(object, "value"), expected, literal)
            XCTAssertEqual(object["value"] as? Int, expected, "Existing direct numeric consumers: \(literal)")
        }
    }

    func testBooleanStringAndNullAreNotIntegers() throws {
        for literal in ["true", "false", "\"1\"", "null"] {
            let object = try XCTUnwrap(JSONWire.object(Array("{\"value\":\(literal)}".utf8)))
            XCTAssertNil(JSONWire.int(object, "value"), literal)
        }
        XCTAssertNil(JSONWire.int(["value": NSNumber(value: 1.9)], "value"))
        XCTAssertNil(JSONWire.int(["value": NSDecimalNumber(string: "9223372036854775808")], "value"))
    }

    func testMalformedJSONNumbersAreRejectedBeforeNormalization() {
        for literal in ["01", "1e++2", "1.", ".1", "--1", "1e"] {
            XCTAssertNil(JSONWire.object(Array("{\"value\":\(literal)}".utf8)), literal)
        }
    }

    func testNestedNumbersAndEscapedStringsKeepTheirTypes() throws {
        let json = #"{"items":[{"value":9007199254740993.0,"bad":9007199254740993.1}],"text":"123 \"456\" \\ 789","truth":true,"zero":0,"one":1}"#
        let object = try XCTUnwrap(JSONWire.object(Array(json.utf8)))
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(JSONWire.int(item, "value"), 9_007_199_254_740_993)
        XCTAssertNil(JSONWire.int(item, "bad"))
        XCTAssertEqual(JSONWire.string(object, "text"), "123 \"456\" \\ 789")
        XCTAssertEqual(JSONWire.bool(object, "truth"), true)
        XCTAssertEqual(JSONWire.int(object, "zero"), 0)
        XCTAssertEqual(JSONWire.int(object, "one"), 1)
        XCTAssertNil(JSONWire.bool(object, "one"))
    }
}
