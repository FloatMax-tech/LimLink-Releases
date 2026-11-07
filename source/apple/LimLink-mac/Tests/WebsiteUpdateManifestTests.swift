import Foundation
import XCTest

final class WebsiteUpdateManifestTests: XCTestCase {
    private func manifest(_ version: String = "1.0.1", path: String = "/download/macos") -> Data {
        Data("{\"macos\":{\"version\":\"\(version)\",\"url\":\"\(path)\",\"size\":1234,\"sha256\":\"\(String(repeating: "a", count: 64))\",\"notes\":\"Fixes\"}}".utf8)
    }

    func testNumericVersionsAndEquivalentTrailingZeros() throws {
        XCTAssertNil(try WebsiteUpdateManifest.parse(manifest("1.0.0"), installed: "1.0"))
        XCTAssertNil(try WebsiteUpdateManifest.parse(manifest("0.9.9"), installed: "1.0"))
        XCTAssertNotNil(try WebsiteUpdateManifest.parse(manifest("1.0.1"), installed: "1.0"))
        XCTAssertNotNil(try WebsiteUpdateManifest.parse(manifest("1.10"), installed: "1.9"))
    }

    func testOnlyTheOfficialMacDownloadPageIsAccepted() throws {
        let update = try XCTUnwrap(WebsiteUpdateManifest.parse(manifest(), installed: "1.0"))
        XCTAssertEqual(update.url.absoluteString, "https://limlink.floatmax-tech.com/download/macos")
        XCTAssertEqual(update.notes, "Fixes")
        for path in ["//evil.example/app", "https://evil.example/app", "/download/macos-cn", "/download/../macos", "/download/macos?device=id"] {
            XCTAssertThrowsError(try WebsiteUpdateManifest.parse(manifest(path: path), installed: "1.0"), path)
        }
    }

    func testMissingReleaseDiffersFromCurrentVersion() throws {
        for json in ["{}", "{\"macos\":null}", "{\"android\":{}}"] {
            XCTAssertThrowsError(try WebsiteUpdateManifest.parse(Data(json.utf8), installed: "1.0")) { error in
                XCTAssertEqual(error as? WebsiteUpdateError, .unpublished)
            }
        }
        XCTAssertNil(try WebsiteUpdateManifest.parse(manifest("1.0"), installed: "1.0"))
    }

    func testMalformedVersionsAndIntegrityMetadataAreRejected() {
        for version in ["", "1", "1.0-beta", "1.-1", "1.0.0.1", "999999999999999999999.0"] {
            XCTAssertThrowsError(try WebsiteUpdateManifest.parse(manifest(version), installed: "1.0"), version)
        }
        XCTAssertThrowsError(try WebsiteUpdateManifest.parse(manifest(), installed: "unknown"))
        for json in ["{", "[]", String(decoding: manifest(), as: UTF8.self).replacingOccurrences(of: "1234", with: "0"), String(decoding: manifest(), as: UTF8.self).replacingOccurrences(of: String(repeating: "a", count: 64), with: "bad")] {
            XCTAssertThrowsError(try WebsiteUpdateManifest.parse(Data(json.utf8), installed: "1.0"))
        }
        XCTAssertThrowsError(try WebsiteUpdateManifest.parse(Data(repeating: 32, count: 131073), installed: "1.0"))
    }
}
