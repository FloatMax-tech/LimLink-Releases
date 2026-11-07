import Foundation
import XCTest
@testable import LimLinkKit
@testable import LimLinkCoreLogic

final class DiskServiceTests: XCTestCase {
    func testPeerHelloAliasesStayBoundToTheirCreatingConnection() throws {
        let service = try makeService()
        _ = service.step(hello("Alice"), peerIsLocal: false, fingerprint: "peer", connectionScope: "first")
        let firstID = try sessionID(service.step(manifest(key: "shared"), peerIsLocal: false, fingerprint: "peer", connectionScope: "first").response)
        _ = service.step(hello("Mallory"), peerIsLocal: false, fingerprint: "peer", connectionScope: "second")
        let secondID = try sessionID(service.step(manifest(key: "shared"), peerIsLocal: false, fingerprint: "peer", connectionScope: "second").response)
        let firstPoll = service.step(request("GET", "/\(firstID)"), peerIsLocal: false, fingerprint: "peer", connectionScope: "first")
        let secondPoll = service.step(request("GET", "/\(secondID)"), peerIsLocal: false, fingerprint: "peer", connectionScope: "second")
        XCTAssertEqual(firstPoll.pending?.senderName, "Alice")
        XCTAssertEqual(secondPoll.pending?.senderName, "Mallory")
        XCTAssertNil(service.step(request("GET", "/\(firstID)"), peerIsLocal: false, fingerprint: "peer", connectionScope: "second").pending)
        _ = service.step(hello("Changed after creation"), peerIsLocal: false, fingerprint: "peer", connectionScope: "first")
        XCTAssertEqual(service.step(request("GET", "/\(firstID)"), peerIsLocal: false, fingerprint: "peer", connectionScope: "first").pending?.senderName, "Alice")
    }

    func testDiskServiceCapsRetainedSessionsAtFourBeforeAllocatingAnotherFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try makeService(directory: directory, maximumRetainedSessions: 100)
        for index in 0..<4 {
            XCTAssertEqual(service.step(manifest(key: "key-\(index)"), peerIsLocal: false, fingerprint: "peer").response.status, 202)
        }
        XCTAssertEqual(service.step(manifest(key: "fifth"), peerIsLocal: false, fingerprint: "peer").response.status, 409)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
    }

    func testFailedPublicationRemovesStagingFileAndSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try makeService(directory: directory)
        let id = try sessionID(service.step(manifest(), peerIsLocal: false, fingerprint: "peer").response)
        XCTAssertTrue(service.decide(sessionID: id, accept: true))
        let result = service.step(complete(id), peerIsLocal: false, fingerprint: "peer", deferPublication: true)
        let file = try XCTUnwrap(result.published.first)
        XCTAssertTrue(file.bytes.isEmpty)
        let url = try XCTUnwrap(file.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(service.step(request("POST", "/\(id)/finish"), peerIsLocal: false, fingerprint: "peer").response.status, 409)
        do {
            _ = try await service.completePublication(file) { _ in throw SaveFailure.failed }
            XCTFail("Publication must fail")
        } catch SaveFailure.failed { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(service.step(request("POST", "/\(id)/finish"), peerIsLocal: false, fingerprint: "peer").response.status, 404)
    }

    func testSuccessfulDiskPublicationRetainsDestinationWhenServiceDiscardsSession() async throws {
        let directory = try temporaryDirectory()
        let destination = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: destination) }
        let service = try makeService(directory: directory)
        let id = try sessionID(service.step(manifest(), peerIsLocal: false, fingerprint: "peer").response)
        XCTAssertTrue(service.decide(sessionID: id, accept: true))
        let file = try XCTUnwrap(service.step(complete(id), peerIsLocal: false, fingerprint: "peer", deferPublication: true).published.first)
        let response = try await service.completePublication(file) { file in
            try FileManager.default.moveItem(at: XCTUnwrap(file.fileURL), to: destination)
            return "saved.bin"
        }
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(service.discardSession(sessionID: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private enum SaveFailure: Error { case failed }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("limlink-disk-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeService(directory: URL? = nil, maximumRetainedSessions: Int? = nil) throws -> SingleFileService {
        SingleFileService(configuration: try LimLinkConfiguration.make(deviceName: "receiver", deviceType: .iphone), trustedFingerprints: ["peer"], maximumRetainedSessions: maximumRetainedSessions, receiveDirectory: directory)
    }
    private func hello(_ alias: String) -> HTTPRequest { WireApp.helloRequest(app: "limlink", alias: alias, devType: "iphone", port: 52470, hostHeader: "peer") }
    private func manifest(key: String = "key") -> HTTPRequest {
        request("POST", "", body: JSONWire.data(["clientSessionKey": key, "transport": "lan", "entries": [["id": "file", "kind": "file", "relativePath": "empty.bin", "size": 0]]]))
    }
    private func complete(_ id: String) -> HTTPRequest { request("POST", "/\(id)/files/file/complete", body: JSONWire.data(["sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"])) }
    private func request(_ method: String, _ suffix: String, body: [UInt8] = []) -> HTTPRequest {
        WireApp.request(method: method, path: "/limlink/v1/sessions\(suffix)", app: "limlink", hostHeader: "peer", body: body, json: method == "POST")
    }
    private func sessionID(_ response: HTTPResponse) throws -> String { try XCTUnwrap(JSONWire.object(response.body).flatMap { JSONWire.string($0, "sessionId") }) }
}
