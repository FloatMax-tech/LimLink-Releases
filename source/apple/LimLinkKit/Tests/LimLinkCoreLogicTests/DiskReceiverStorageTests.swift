import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class DiskReceiverStorageTests: XCTestCase {
    func testTwentyOneMiBUploadStaysOnDiskAndPublishesOnlyAfterVerification() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        try start(&receiver, size: 21 * 1024 * 1024)
        let chunk = [UInt8](repeating: 97, count: 1024 * 1024)
        for index in 0..<21 {
            let reply = handle(&receiver, upload(chunk, offset: index * chunk.count))
            XCTAssertEqual(reply.status, 200)
            XCTAssertEqual(JSONWire.object(reply.body)?["committedBytes"] as? Int, (index + 1) * chunk.count)
            let session = try XCTUnwrap(receiver.sessions["sid"])
            XCTAssertTrue(session.committed.isEmpty)
            XCTAssertTrue(session.halfFile.isEmpty)
            XCTAssertNil(session.published)
            XCTAssertNil(session.publishedFileURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(session.fileURL).path)
            XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, (index + 1) * chunk.count)
        }
        let finished = handle(&receiver, complete("3c2fc99778b3e3480ae8c54f1fdfee7e7c9b40aea1f642b6bbc9733b08a5a7df"), deferPublication: true)
        XCTAssertEqual(finished.status, 200)
        let session = try XCTUnwrap(receiver.sessions["sid"])
        XCTAssertEqual(session.phase, .completed)
        XCTAssertNotNil(session.publishedFileURL)
        XCTAssertNil(session.published)
        XCTAssertEqual(handle(&receiver, request("POST", "/sid/finish")).status, 409)
        XCTAssertTrue(receiver.updatePublishedFileName(sessionID: "sid", fileName: "saved.bin"))
        let summary = handle(&receiver, request("POST", "/sid/finish"))
        XCTAssertEqual((JSONWire.object(summary.body)?["totals"] as? [String: Any])?["bytesReceived"] as? Int, 21 * 1024 * 1024)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testWrongDigestClearsDurablePrefixAndRetryCanSucceed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        try start(&receiver, size: 3)
        XCTAssertEqual(handle(&receiver, upload([97, 98, 99], offset: 0)).status, 200)
        XCTAssertEqual(handle(&receiver, complete(String(repeating: "0", count: 64))).status, 422)
        XCTAssertEqual(receiver.sessions["sid"]?.committedByteCount, 0)
        let url = try XCTUnwrap(receiver.sessions["sid"]?.fileURL)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        XCTAssertEqual(handle(&receiver, upload([97], offset: 0)).status, 200)
        XCTAssertEqual(handle(&receiver, upload([98, 99], offset: 1)).status, 200)
        XCTAssertEqual(handle(&receiver, complete(abcDigest)).status, 200)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(receiver.sessions["sid"]?.publishedFileURL)), Data([97, 98, 99]))
    }

    func testIncompleteCompleteResetsAndExcessOrEmptyChunksCannotAdvanceOffset() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        try start(&receiver, size: 3)
        XCTAssertEqual(handle(&receiver, upload([], offset: 0)).status, 400)
        XCTAssertEqual(handle(&receiver, upload([97, 98, 99, 100], offset: 0)).status, 400)
        XCTAssertEqual(receiver.sessions["sid"]?.committedByteCount, 0)
        XCTAssertEqual(handle(&receiver, upload([97], offset: 0)).status, 200)
        XCTAssertEqual(handle(&receiver, upload([98], offset: 0)).status, 409)
        XCTAssertEqual(receiver.sessions["sid"]?.committedByteCount, 1)
        XCTAssertEqual(handle(&receiver, complete(abcDigest)).status, 422)
        XCTAssertEqual(receiver.sessions["sid"]?.committedByteCount, 0)
        XCTAssertEqual(handle(&receiver, upload([97, 98, 99], offset: 0)).status, 200)
        XCTAssertEqual(handle(&receiver, complete(String(repeating: "0", count: 64))).status, 422)
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .verifyFailed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testFiveGBMetadataAcceptedAndOneByteOverRejectedWithoutAllocation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        XCTAssertEqual(handle(&receiver, manifest(size: 5_000_000_001)).status, 413)
        XCTAssertTrue(receiver.sessions.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertEqual(handle(&receiver, manifest(size: 5_000_000_000)).status, 202)
        XCTAssertEqual(receiver.sessions["sid"]?.size, 5_000_000_000)
        XCTAssertEqual(receiver.sessions["sid"]?.committedByteCount, 0)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(receiver.sessions["sid"]?.fileURL)).count, 0)
    }

    func testChunkOverOneMiBIsRejectedWithoutWriting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        try start(&receiver, size: 2 * 1024 * 1024)
        XCTAssertEqual(handle(&receiver, upload([UInt8](repeating: 0, count: 1024 * 1024 + 1), offset: 0)).status, 413)
        XCTAssertEqual(receiver.sessions["sid"]?.committedByteCount, 0)
    }

    func testRejectCancelDiscardAndReceiverLifetimeRemoveOwnedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for action in ["reject", "cancel", "skip", "discard", "deinit"] {
            do {
                var receiver = try makeReceiver(directory)
                XCTAssertEqual(handle(&receiver, manifest(size: 3)).status, 202)
                let url = try XCTUnwrap(receiver.sessions["sid"]?.fileURL)
                XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
                XCTAssertFalse(url.lastPathComponent.contains("untrusted"))
                if action == "reject" {
                    XCTAssertTrue(receiver.decide(sessionID: "sid", accept: false))
                } else if action == "discard" {
                    XCTAssertTrue(receiver.discardSession(sessionID: "sid"))
                } else if action == "cancel" {
                    XCTAssertTrue(receiver.decide(sessionID: "sid", accept: true))
                    XCTAssertEqual(handle(&receiver, request("POST", "/sid/cancel", body: JSONWire.data(["sessionId": "sid", "reason": "user"]))).status, 200)
                } else if action == "skip" {
                    XCTAssertTrue(receiver.decide(sessionID: "sid", accept: true))
                    XCTAssertEqual(handle(&receiver, upload([97], offset: 0)).status, 200)
                    XCTAssertEqual(handle(&receiver, request("POST", "/sid/files/file/skip", body: JSONWire.data(["sessionId": "sid", "reason": "user"]))).status, 200)
                }
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, action)
        }
    }

    func testPeerControlledFileIDNeverBecomesAStoragePath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        XCTAssertEqual(handle(&receiver, manifest(size: 3, fileID: "../../untrusted")).status, 202)
        let url = try XCTUnwrap(receiver.sessions["sid"]?.fileURL)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("limlink-"))
        XCTAssertFalse(url.lastPathComponent.contains("untrusted"))
        XCTAssertTrue(receiver.discardSession(sessionID: "sid"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDamagedStagingFileFailsWriteAndDeletesItsOwnedPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        try start(&receiver, size: 3)
        XCTAssertEqual(handle(&receiver, upload([97], offset: 0)).status, 200)
        let url = try XCTUnwrap(receiver.sessions["sid"]?.fileURL)
        let externalWriter = try FileHandle(forWritingTo: url)
        try externalWriter.truncate(atOffset: 0)
        try externalWriter.close()
        let failure = handle(&receiver, upload([98], offset: 1))
        XCTAssertEqual(WireApp.decodeError(failure.body)?.code, .writeFailed)
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(receiver.sessions["sid"]?.committedByteCount, 0)
    }

    func testMissingStagingFileFailsVerificationAndClearsSessionPayload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        try start(&receiver, size: 3)
        XCTAssertEqual(handle(&receiver, upload([97, 98, 99], offset: 0)).status, 200)
        let url = try XCTUnwrap(receiver.sessions["sid"]?.fileURL)
        try FileManager.default.removeItem(at: url)
        let failure = handle(&receiver, complete(abcDigest))
        XCTAssertEqual(WireApp.decodeError(failure.body)?.code, .writeFailed)
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .cancelled)
        XCTAssertNil(receiver.sessions["sid"]?.publishedFileURL)
        XCTAssertEqual(receiver.sessions["sid"]?.committedByteCount, 0)
    }

    func testAnotherFingerprintAndScopeCannotWriteOrDeleteOwnersFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receiver = try makeReceiver(directory)
        try start(&receiver, size: 3)
        XCTAssertEqual(handle(&receiver, upload([97], offset: 0)).status, 200)
        let ownerURL = try XCTUnwrap(receiver.sessions["sid"]?.fileURL)
        for (fingerprint, scope) in [("other", "connection"), ("peer", "sibling")] {
            let attempt = response(receiver.handle(request("POST", "/sid/cancel", body: JSONWire.data(["sessionId": "sid", "reason": "user"])), peerAddressIsLocal: false, clientFingerprint: fingerprint, connectionScope: scope))
            XCTAssertEqual(attempt.status, 404)
            XCTAssertEqual(try Data(contentsOf: ownerURL), Data([97]))
        }
    }

    func testMovedPublishedDestinationSurvivesSessionDiscard() throws {
        let directory = try temporaryDirectory()
        let destination = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: destination) }
        var receiver = try makeReceiver(directory)
        try start(&receiver, size: 3)
        XCTAssertEqual(handle(&receiver, upload([97, 98, 99], offset: 0)).status, 200)
        XCTAssertEqual(handle(&receiver, complete(abcDigest), deferPublication: true).status, 200)
        try FileManager.default.moveItem(at: XCTUnwrap(receiver.sessions["sid"]?.publishedFileURL), to: destination)
        XCTAssertTrue(receiver.updatePublishedFileName(sessionID: "sid", fileName: "saved.bin"))
        XCTAssertTrue(receiver.discardSession(sessionID: "sid"))
        XCTAssertEqual(try Data(contentsOf: destination), Data([97, 98, 99]))
    }

    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("limlink-disk-receiver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeReceiver(_ directory: URL) throws -> SingleFileReceiver {
        SingleFileReceiver(host: try HostAppIdentity(app: "limlink"), alias: "receiver", trustedFingerprints: ["peer", "other"], sessionIDs: ["sid"], tokens: ["token"], storageDirectory: directory)
    }
    private func start(_ receiver: inout SingleFileReceiver, size: Int) throws {
        XCTAssertEqual(handle(&receiver, manifest(size: size)).status, 202)
        XCTAssertTrue(receiver.decide(sessionID: "sid", accept: true))
    }
    private func manifest(size: Int, fileID: String = "file") -> HTTPRequest {
        request("POST", "", body: JSONWire.data(["clientSessionKey": "key", "transport": "lan", "entries": [["id": fileID, "kind": "file", "relativePath": "payload.bin", "size": size]]]))
    }
    private func upload(_ bytes: [UInt8], offset: Int) -> HTTPRequest {
        WireApp.request(method: "PUT", path: "/limlink/v1/sessions/sid/files/file", app: "limlink", hostHeader: "peer", body: bytes, json: false, extra: ["content-type": "application/octet-stream", "x-limlink-token": "token", "x-limlink-offset": String(offset)])
    }
    private func complete(_ digest: String) -> HTTPRequest { request("POST", "/sid/files/file/complete", body: JSONWire.data(["sha256": digest])) }
    private func request(_ method: String, _ suffix: String, body: [UInt8] = []) -> HTTPRequest {
        WireApp.request(method: method, path: "/limlink/v1/sessions\(suffix)", app: "limlink", hostHeader: "peer", body: body, json: method == "POST")
    }
    private func handle(_ receiver: inout SingleFileReceiver, _ request: HTTPRequest, deferPublication: Bool = false) -> HTTPResponse {
        response(receiver.handle(request, peerAddressIsLocal: false, clientFingerprint: "peer", connectionScope: "connection", deferPublication: deferPublication))
    }
    private func response(_ step: ReceiverStep) -> HTTPResponse {
        guard case .response(let response) = step else { XCTFail("Expected response"); return HTTPResponse(status: 500) }
        return response
    }
}
