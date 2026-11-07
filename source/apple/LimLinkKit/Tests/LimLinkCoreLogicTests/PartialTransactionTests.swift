import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class PartialTransactionTests: XCTestCase {
    func testFirstCreationKeepsAliasAndRealPathWritesInTheSameTransaction() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realRoot = root.appendingPathComponent("real")
        let aliasRoot = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: realRoot)
        let aliasDirectory = aliasRoot.appendingPathComponent("missing/partial")
        let realDirectory = realRoot.appendingPathComponent("missing/partial")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ready = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let errors = ConcurrentErrors()

        // Pause the first initializer between creating its directory and its manifest.
        try PartialFileTransactions.withLock(at: aliasDirectory) {
            try FileManager.default.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
            for (id, url) in [("alias", aliasDirectory), ("real", realDirectory)] {
                let record = freshRecord(id, now: now)
                finished.enter()
                DispatchQueue.global().async {
                    defer { finished.leave() }
                    ready.signal()
                    do {
                        let directory = try PartialDirectory(root: url)
                        try directory.upsert(record, bytes: [42])
                    } catch { errors.append(error) }
                    completed.signal()
                }
            }
            XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(completed.wait(timeout: .now() + .milliseconds(100)), .timedOut)
            try Data("[]".utf8).write(to: aliasDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        if let error = errors.first { throw error }
        let directory = try PartialDirectory(root: realDirectory)
        XCTAssertEqual(Set(try directory.records().map(\.id)), ["alias", "real"])
        XCTAssertEqual(try directory.partialFilesSize(), 2)
    }

    func testCleanupCannotLoseConcurrentFreshWritesFromAnotherDirectoryInstance() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try PartialDirectory(root: root)
        let cleaner = try PartialDirectory(root: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<40 {
            let record = freshRecord("fresh-\(index)", now: now)
            try race([
                { try writer.upsert(record, bytes: [42]) },
                { try cleaner.purgeOlderThan24Hours(now: now) },
                { try cleaner.clearPartialFiles(now: now) },
                { try cleaner.remove(id: "absent") }
            ])
        }

        XCTAssertEqual(Set(try writer.records().map(\.id)), Set((0..<40).map { "fresh-\($0)" }))
        XCTAssertEqual(try writer.partialFilesSize(), 40)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".bin") }.count, 40)
    }

    func testConcurrentCreationAndWritesKeepEveryRecord() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<20 {
            let directoryURL = root.appendingPathComponent("directory-\(index)")
            try race((0..<4).map { writer in
                let record = freshRecord("writer-\(writer)", now: now)
                return {
                    let directory = try PartialDirectory(root: directoryURL)
                    try directory.upsert(record, bytes: [42])
                }
            })
            let directory = try PartialDirectory(root: directoryURL)
            XCTAssertEqual(Set(try directory.records().map(\.id)), ["writer-0", "writer-1", "writer-2", "writer-3"])
            XCTAssertEqual(try directory.partialFilesSize(), 4)
        }
    }

    func testCleanupCannotDeleteBytesOfAConcurrentlyRefreshedPartial() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try PartialDirectory(root: root)
        let cleaner = try PartialDirectory(root: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<40 {
            let id = "refresh-\(index)"
            let stale = PartialFileRecord(id: id, byteCount: 1, lastWrite: now.addingTimeInterval(-86_400),
                                          activity: .disconnected, since: now.addingTimeInterval(-1_800))
            try writer.upsert(stale, bytes: [0])
            let fresh = freshRecord(id, now: now)
            try race([
                { try writer.upsert(fresh, bytes: [42]) },
                {
                    if index.isMultiple(of: 2) {
                        try cleaner.clearPartialFiles(now: now)
                    } else {
                        try cleaner.purgeOlderThan24Hours(now: now)
                    }
                }
            ])
            XCTAssertEqual(try writer.records().first { $0.id == id }, fresh)
            XCTAssertEqual(try? Data(contentsOf: root.appendingPathComponent(id).appendingPathExtension("bin")), Data([42]))
        }
    }

    func testConcurrentRegistryCreationAndRememberKeepEveryLocation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<20 {
            let registryURL = root.appendingPathComponent("registry-\(index).json")
            try race((0..<4).map { writer in
                let decision = PartialPlacementDecision(directory: root.appendingPathComponent("partial-\(writer)"),
                                                        volumeID: "disk", mode: .privateDirectory,
                                                        fallbackReason: nil, targetDirectory: nil)
                return {
                    let library = try PartialLibrary(registryURL: registryURL)
                    try library.remember(decision, id: "location-\(writer)")
                }
            })
            let library = try PartialLibrary(registryURL: registryURL)
            XCTAssertEqual(Set(try library.uses().map(\.id)), ["location-0", "location-1", "location-2", "location-3"])
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("partial-transactions-\(UUID().uuidString)")
    }

    private func freshRecord(_ id: String, now: Date) -> PartialFileRecord {
        PartialFileRecord(id: id, byteCount: 1, lastWrite: now, activity: .transferring, since: nil)
    }

    /// Releases all operations together; no sleeps or production-only test hooks.
    private func race(_ operations: [@Sendable () throws -> Void]) throws {
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let errors = ConcurrentErrors()
        for operation in operations {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                ready.signal()
                start.wait()
                do { try operation() } catch { errors.append(error) }
            }
        }
        for _ in operations { ready.wait() }
        for _ in operations { start.signal() }
        finished.wait()
        if let error = errors.first { throw error }
    }
}

private final class ConcurrentErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [any Error] = []

    var first: (any Error)? { lock.withLock { errors.first } }
    func append(_ error: any Error) { lock.withLock { errors.append(error) } }
}
