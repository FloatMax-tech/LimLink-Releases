import Foundation
import XCTest
@testable import LimLinkKit
@testable import LimLinkCoreLogic

final class ServicePublicationOwnershipTests: XCTestCase {
    func testStrictSiblingCannotReceiveOfferOrReuseCreatorIdempotencyKey() throws {
        let service = try makeService()
        let created = service.step(manifest(), peerIsLocal: false, fingerprint: "peer-a", connectionScope: "first")
        let sid = try sessionID(created.response)
        let stolen = service.step(request("GET", "/\(sid)?wait=0"), peerIsLocal: false, fingerprint: "peer-a", connectionScope: "second")
        XCTAssertEqual(WireApp.decodeError(stolen.response.body)?.code, .sessionNotFound)
        XCTAssertNil(stolen.pending)
        let ownerPoll = service.step(request("GET", "/\(sid)?wait=0"), peerIsLocal: false, fingerprint: "peer-a", connectionScope: "first")
        XCTAssertEqual(ownerPoll.pending?.sessionID, sid)
        XCTAssertEqual(ownerPoll.pending?.fingerprint, "peer-a")
        let siblingCreate = service.step(manifest(), peerIsLocal: false, fingerprint: "peer-a", connectionScope: "second")
        XCTAssertNotEqual(try sessionID(siblingCreate.response), sid)
    }

    func testStrictSiblingCannotTriggerCreatorPublication() throws {
        let service = try makeService()
        let sid = try sessionID(service.step(manifest(), peerIsLocal: false, fingerprint: "peer-a", connectionScope: "first").response)
        XCTAssertTrue(service.decide(sessionID: sid, accept: true))
        let stolen = service.step(complete(sid), peerIsLocal: false, fingerprint: "peer-a", connectionScope: "second")
        XCTAssertEqual(WireApp.decodeError(stolen.response.body)?.code, .sessionNotFound)
        XCTAssertTrue(stolen.published.isEmpty)
        let owner = service.step(complete(sid), peerIsLocal: false, fingerprint: "peer-a", connectionScope: "first")
        XCTAssertEqual(owner.response.status, 200)
        XCTAssertEqual(owner.published.count, 1)
        XCTAssertEqual(owner.published.first?.sessionID, sid)
        XCTAssertEqual(owner.published.first?.fingerprint, "peer-a")
    }

    func testAwaitedDurableSaveBlocksLegacyReconnectFinishUntilSavedNameIsRecorded() async throws {
        let service = try makeService()
        let sid = try sessionID(service.step(manifest(), peerIsLocal: false, fingerprint: "peer-a").response)
        XCTAssertTrue(service.decide(sessionID: sid, accept: true))
        let candidate = service.step(complete(sid), peerIsLocal: false, fingerprint: "peer-a", deferPublication: true)
        let file = try XCTUnwrap(candidate.published.first)
        let latch = PublicationLatch()
        let save = Task { try await service.completePublication(file) { _ in try await latch.save() } }
        await latch.waitUntilSaving()
        let earlyFinish = service.step(request("POST", "/\(sid)/finish"), peerIsLocal: false, fingerprint: "peer-a")
        XCTAssertEqual(WireApp.decodeError(earlyFinish.response.body)?.code, .invalidState)
        let otherPin = service.step(request("POST", "/\(sid)/finish"), peerIsLocal: false, fingerprint: "peer-b")
        XCTAssertEqual(WireApp.decodeError(otherPin.response.body)?.code, .sessionNotFound)
        await latch.succeed(name: "empty (1).txt")
        let acknowledged = try await save.value
        XCTAssertEqual(JSONWire.object(acknowledged.body).flatMap { JSONWire.string($0, "finalName") }, "empty (1).txt")
        let finished = service.step(request("POST", "/\(sid)/finish"), peerIsLocal: false, fingerprint: "peer-a")
        XCTAssertEqual(finished.response.status, 200)
        let files = try XCTUnwrap(JSONWire.object(finished.response.body)?["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["finalName"] as? String, "empty (1).txt")
    }

    func testFailedDurableSaveDiscardsSessionBeforeLegacyReconnectCanFinish() async throws {
        let service = try makeService()
        let sid = try sessionID(service.step(manifest(), peerIsLocal: false, fingerprint: "peer-a").response)
        XCTAssertTrue(service.decide(sessionID: sid, accept: true))
        let candidate = service.step(complete(sid), peerIsLocal: false, fingerprint: "peer-a", deferPublication: true)
        let file = try XCTUnwrap(candidate.published.first)
        let latch = PublicationLatch()
        let save = Task { try await service.completePublication(file) { _ in try await latch.save() } }
        await latch.waitUntilSaving()
        await latch.fail()
        do {
            _ = try await save.value
            XCTFail("A failed durable save must fail publication")
        } catch SaveFailure.failed { }
        let finish = service.step(request("POST", "/\(sid)/finish"), peerIsLocal: false, fingerprint: "peer-a")
        XCTAssertEqual(WireApp.decodeError(finish.response.body)?.code, .sessionNotFound)
        XCTAssertTrue(finish.published.isEmpty)
        let recreated = service.step(manifest(), peerIsLocal: false, fingerprint: "peer-a")
        XCTAssertNotEqual(try sessionID(recreated.response), sid)
    }

    private func makeService() throws -> SingleFileService {
        SingleFileService(configuration: try LimLinkConfiguration.make(deviceName: "receiver", deviceType: .iphone), trustedFingerprints: ["peer-a", "peer-b"])
    }

    private func manifest() -> HTTPRequest {
        request("POST", "", body: JSONWire.data(["clientSessionKey": "shared", "transport": "lan", "entries": [["id": "file", "kind": "file", "relativePath": "empty.txt", "size": 0]]]))
    }

    private func complete(_ sid: String) -> HTTPRequest {
        request("POST", "/\(sid)/files/file/complete", body: JSONWire.data(["sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]))
    }

    private func request(_ method: String, _ suffix: String, body: [UInt8] = []) -> HTTPRequest {
        WireApp.request(method: method, path: "/limlink/v1/sessions\(suffix)", app: "limlink", hostHeader: "peer", body: body, json: method == "POST")
    }

    private func sessionID(_ response: HTTPResponse) throws -> String {
        try XCTUnwrap(JSONWire.object(response.body).flatMap { JSONWire.string($0, "sessionId") })
    }

    private enum SaveFailure: Error { case failed }

    /// Suspends only the host's external durable save; the receiver and service remain real.
    private actor PublicationLatch {
        private var saving = false
        private var saveContinuation: CheckedContinuation<String, Error>?
        private var startContinuation: CheckedContinuation<Void, Never>?

        func save() async throws -> String {
            saving = true
            startContinuation?.resume()
            startContinuation = nil
            return try await withCheckedThrowingContinuation { saveContinuation = $0 }
        }

        func waitUntilSaving() async {
            if !saving { await withCheckedContinuation { startContinuation = $0 } }
        }

        func succeed(name: String) {
            saveContinuation?.resume(returning: name)
            saveContinuation = nil
        }

        func fail() {
            saveContinuation?.resume(throwing: SaveFailure.failed)
            saveContinuation = nil
        }
    }
}
