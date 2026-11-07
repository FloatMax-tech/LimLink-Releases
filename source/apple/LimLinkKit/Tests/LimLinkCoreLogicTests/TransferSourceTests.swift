import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class TransferSourceTests: XCTestCase {
    private let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func testFileSourceReadsSparseOffsetsAboveTwoAndFourGiBAndAtFiveGBLimit() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 5_000_000_000)
        for offset in [2_147_483_651, 4_294_967_299, 4_999_999_997] {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: Data([97, 98, 99]))
        }
        let source = try TransferSource(fileURL: url, size: 5_000_000_000, sha256Hex: emptyDigest)
        for offset in [2_147_483_651, 4_294_967_299, 4_999_999_997] {
            XCTAssertEqual(try source.read(offset: offset, count: 3), [97, 98, 99])
        }
        XCTAssertEqual(try source.read(offset: 5_000_000_000, count: 0), [])
        XCTAssertThrowsError(try source.read(offset: 4_999_999_999, count: 2))
        XCTAssertThrowsError(try source.read(offset: 0, count: 1_048_577))
        try handle.truncate(atOffset: 5_000_000_001)
        XCTAssertThrowsError(try TransferSource(fileURL: url, size: 5_000_000_001, sha256Hex: emptyDigest))
    }

    func testFileSourceRejectsInvalidMetadataAndDetectsTruncation() throws {
        let url = try temporaryFile(data: Data([97, 98, 99]))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try TransferSource(fileURL: url, size: -1, sha256Hex: emptyDigest))
        XCTAssertThrowsError(try TransferSource(fileURL: url, size: 2, sha256Hex: emptyDigest))
        XCTAssertThrowsError(try TransferSource(fileURL: url, size: 3, sha256Hex: "invalid"))
        let source = try TransferSource(fileURL: url, size: 3, sha256Hex: emptyDigest)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1)
        try handle.close()
        XCTAssertThrowsError(try source.read(offset: 0, count: 3))
    }

    func testMemorySourceRejectsNegativeOverflowAndOutOfBoundsRanges() throws {
        let source = TransferSource(bytes: [97, 98, 99])
        XCTAssertEqual(try source.read(offset: 1, count: 2), [98, 99])
        for (offset, count) in [(-1, 1), (0, -1), (2, 2), (Int.max, 1), (1, Int.max)] {
            XCTAssertThrowsError(try source.read(offset: offset, count: count))
        }
        XCTAssertEqual(source.sha256Hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testIncrementalDigestKnownVectorsAcrossPaddingAndChunkBoundaries() {
        let fixtures: [(String, String)] = [
            ("", emptyDigest),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            (String(repeating: "a", count: 1_000_000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"),
        ]
        for (message, expected) in fixtures {
            let bytes = Array(message.utf8)
            var digest = IncrementalFileDigest()
            var fallback = SHA256.Incremental()
            for offset in stride(from: 0, to: bytes.count, by: 63) {
                let data = Data(bytes[offset..<min(offset + 63, bytes.count)])
                digest.update(data)
                fallback.update(data: data)
            }
            XCTAssertEqual(digest.finalizeHex(), expected)
            XCTAssertEqual(SHA256.hex(fallback.finalize()), expected)
            XCTAssertEqual(SHA256.hex(SHA256.hash(bytes)), expected)
        }
    }

    func testFileDigestHashesThroughBoundedReads() throws {
        let url = try temporaryFile(data: Data(repeating: 97, count: 1_000_000))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try FileDigest.sha256Hex(fileURL: url), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testCancelledFileHashStopsBeforeOpeningTheFile() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try FileDigest.sha256Hex(fileURL: URL(fileURLWithPath: "/missing-cancelled-hash-input"))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }

    private func temporaryFile(data: Data = Data()) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
}
