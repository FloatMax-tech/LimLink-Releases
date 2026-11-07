import Foundation
import XCTest
@testable import LimLinkKit
@testable import LimLinkCoreLogic

final class DeviceBindingTests: XCTestCase {
    func testStartControlRejectsUnsupportedVersionBeforeFileTrust() throws {
        let service = SingleFileService(configuration: try .make(deviceName: "receiver", deviceType: .iphone))
        let request = HTTPRequest(method: "POST", target: "/limlink/v1/pair/start", headers: ["Host": "receiver", "X-LimLink-App": "limlink"], body: Array(try JSONSerialization.data(withJSONObject: ["version": 2, "requestId": "c33e215e-f1ca-40a4-a8aa-c34dd8b31fb9", "alias": "sender", "deviceType": "mac"])))
        let response = service.step(request, peerIsLocal: false, fingerprint: String(repeating: "A", count: 43), connectionID: "owner").response
        XCTAssertEqual(response.status, 400, "Binding control validates the protocol version before file trust")
        let body = try XCTUnwrap(JSONWire.object(response.body))
        XCTAssertEqual(JSONWire.string(body, "code"), "E_PAIR_VERSION")
    }
}

final class BindingConsentAndStorageTests: XCTestCase {
    let own = Base64URL.encode([UInt8](repeating: 1, count: 32))
    let peer = Base64URL.encode([UInt8](repeating: 2, count: 32))
    func makeController(url: URL? = nil) throws -> DeviceBindingController {
        try DeviceBindingController(store: DeviceBindingStore(url: url ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("bindings.json"), ownFingerprint: own), alias: "Receiver", deviceType: "iphone")
    }
    func start(_ controller: DeviceBindingController) throws -> [String: Any] {
        let response = controller.handle(request("POST", "start", body: ["version": 1, "requestId": UUID().uuidString.lowercased(), "alias": "Sender", "deviceType": "mac"]), fingerprint: peer, connectionID: "owner")
        XCTAssertEqual(response.status, 202)
        return try XCTUnwrap(JSONWire.object(response.body))
    }
    func request(_ method: String, _ route: String, token: String? = nil, body: [String: Any] = [:]) -> HTTPRequest {
        var headers = ["host": "receiver", "X-LimLink-App": "limlink"]
        headers["X-LimLink-Pair-Token"] = token
        return HTTPRequest(method: method, target: "/limlink/v1/pair/" + route, headers: headers, body: JSONWire.data(body))
    }
    func testOnlyRecipientAcceptanceCanCompleteAndWrongOwnerCannotPoll() throws {
        let controller = try makeController(), body = try start(controller)
        let id = try XCTUnwrap(body["pairId"] as? String), token = try XCTUnwrap(body["token"] as? String)
        let complete = request("POST", id + "/complete", token: token)
        XCTAssertEqual(controller.handle(complete, fingerprint: peer, connectionID: "owner").status, 409)
        XCTAssertTrue(controller.store.all.isEmpty)
        XCTAssertEqual(controller.handle(request("GET", id, token: token), fingerprint: peer, connectionID: "sibling").status, 403)
        XCTAssertEqual(controller.handle(request("GET", id, token: "wrong"), fingerprint: peer, connectionID: "owner").status, 403)
        controller.decide(pairID: id, accept: true)
        XCTAssertTrue(controller.store.all.isEmpty)
        XCTAssertEqual(controller.handle(complete, fingerprint: peer, connectionID: "owner").status, 200)
        XCTAssertTrue(controller.permits(peer: peer, bindingID: id))
        XCTAssertFalse(controller.permits(peer: peer, bindingID: nil))
        XCTAssertFalse(controller.permits(peer: own, bindingID: id))
        XCTAssertEqual(controller.handle(complete, fingerprint: peer, connectionID: "owner").status, 200)
        XCTAssertEqual(controller.handle(request("POST", id + "/revoke"), fingerprint: peer, connectionID: "other").status, 200)
        XCTAssertFalse(controller.permits(peer: peer, bindingID: id))
        XCTAssertEqual(controller.handle(complete, fingerprint: peer, connectionID: "owner").status, 409)
    }
    func testDisconnectAndRejectCannotGrantPermission() throws {
        for reject in [false, true] {
            let controller = try makeController(), body = try start(controller)
            let id = try XCTUnwrap(body["pairId"] as? String), token = try XCTUnwrap(body["token"] as? String)
            controller.decide(pairID: id, accept: !reject)
            if !reject { controller.disconnect("owner") }
            XCTAssertEqual(controller.handle(request("POST", id + "/complete", token: token), fingerprint: peer, connectionID: "owner").status, 409)
            XCTAssertTrue(controller.store.all.isEmpty)
        }
    }
    func testLocalUnbindCancelsUnfinishedReplacementBindingForSamePeer() throws {
        for acceptReplacement in [false, true] {
            let controller = try makeController()
            let old = DeviceBindingRecord(ownFingerprint: own, peerFingerprint: peer, bindingID: "2744e85e-3e5c-4d9a-90a7-58e2a92b2781", alias: "Sender", deviceType: "mac")
            try controller.store.put(old)
            let replacement = try start(controller)
            let id = try XCTUnwrap(replacement["pairId"] as? String), token = try XCTUnwrap(replacement["token"] as? String)
            if acceptReplacement { controller.decide(pairID: id, accept: true) }

            try controller.unbind(old)
            XCTAssertNil(controller.pending)
            controller.decide(pairID: id, accept: true)
            let complete = request("POST", id + "/complete", token: token)
            XCTAssertEqual(controller.handle(complete, fingerprint: peer, connectionID: "owner").status, 409)
            XCTAssertTrue(controller.store.all.isEmpty, "An earlier binding attempt must not restore local permission after unbind")
            let state = controller.handle(request("GET", id, token: token), fingerprint: peer, connectionID: "owner")
            XCTAssertEqual(JSONWire.string(try XCTUnwrap(JSONWire.object(state.body)), "state"), "cancelled")
        }
    }

    func testRemoteOldRevokeDoesNotCancelAcceptedReplacementBinding() throws {
        let controller = try makeController()
        let old = DeviceBindingRecord(ownFingerprint: own, peerFingerprint: peer, bindingID: "2744e85e-3e5c-4d9a-90a7-58e2a92b2781", alias: "Sender", deviceType: "mac")
        try controller.store.put(old)
        let replacement = try start(controller)
        let id = try XCTUnwrap(replacement["pairId"] as? String), token = try XCTUnwrap(replacement["token"] as? String)
        controller.decide(pairID: id, accept: true)

        XCTAssertEqual(controller.handle(request("POST", old.bindingID + "/revoke"), fingerprint: peer, connectionID: "other").status, 200)
        XCTAssertEqual(controller.handle(request("POST", id + "/complete", token: token), fingerprint: peer, connectionID: "owner").status, 200)
        XCTAssertEqual(controller.store.record(for: peer)?.bindingID, id, "A replay of an old remote revoke must not cancel newly consented binding")
    }

    func testLocalUnbindFromStaleRowRemovesAlreadyCompletedReplacement() throws {
        let controller = try makeController()
        let old = DeviceBindingRecord(ownFingerprint: own, peerFingerprint: peer, bindingID: "2744e85e-3e5c-4d9a-90a7-58e2a92b2781", alias: "Sender", deviceType: "mac")
        try controller.store.put(old)
        let replacement = try start(controller)
        let id = try XCTUnwrap(replacement["pairId"] as? String), token = try XCTUnwrap(replacement["token"] as? String)
        controller.decide(pairID: id, accept: true)
        let complete = request("POST", id + "/complete", token: token)
        XCTAssertEqual(controller.handle(complete, fingerprint: peer, connectionID: "owner").status, 200)
        XCTAssertEqual(controller.store.record(for: peer)?.bindingID, id)

        // The UI may still have the old row while the completion update is queued.
        try controller.unbind(old)
        XCTAssertNil(controller.store.record(for: peer))
        XCTAssertFalse(controller.permits(peer: peer, bindingID: id))
        XCTAssertEqual(controller.handle(complete, fingerprint: peer, connectionID: "owner").status, 409)
        XCTAssertTrue(controller.store.all.isEmpty)
    }

    func testOldStoreRollbackCannotOverwriteReplacementSavedByAnotherRuntime() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("bindings.json")
        let old = DeviceBindingRecord(ownFingerprint: own, peerFingerprint: peer, bindingID: UUID().uuidString.lowercased(), alias: "Old runtime", deviceType: "mac")
        let newer = DeviceBindingRecord(ownFingerprint: own, peerFingerprint: peer, bindingID: UUID().uuidString.lowercased(), alias: "New runtime", deviceType: "mac")
        let previous = try DeviceBindingStore(url: url, ownFingerprint: own)
        try previous.put(old)
        let current = try DeviceBindingStore(url: url, ownFingerprint: own)
        try current.put(newer)
        XCTAssertThrowsError(try previous.put(old, isCurrent: { false })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        try previous.remove(peer: peer, bindingID: old.bindingID)
        XCTAssertEqual(try DeviceBindingStore(url: url, ownFingerprint: own).record(for: peer), newer)
        XCTAssertEqual(previous.record(for: peer), newer)
        try current.remove(peer: peer)
        XCTAssertNil(previous.record(for: peer), "Every authorization read must observe a newer runtime's revocation")
    }

    func testStorageFailureDoesNotReportCompleted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocked".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = try makeController(url: url.appendingPathComponent("bindings.json")), body = try start(controller)
        let id = try XCTUnwrap(body["pairId"] as? String), token = try XCTUnwrap(body["token"] as? String)
        controller.decide(pairID: id, accept: true)
        XCTAssertEqual(controller.handle(request("POST", id + "/complete", token: token), fingerprint: peer, connectionID: "owner").status, 500)
        XCTAssertTrue(controller.store.all.isEmpty)
    }
    func testReloadKeepsRenameButOwnKeyChangeCannotAuthorize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("bindings.json")
        let controller = try makeController(url: url), body = try start(controller)
        let id = try XCTUnwrap(body["pairId"] as? String), token = try XCTUnwrap(body["token"] as? String)
        controller.decide(pairID: id, accept: true)
        XCTAssertEqual(controller.handle(request("POST", id + "/complete", token: token), fingerprint: peer, connectionID: "owner").status, 200)
        let reloaded = try DeviceBindingStore(url: url, ownFingerprint: own)
        XCTAssertEqual(reloaded.record(for: peer)?.bindingID, id)
        let newKey = Base64URL.encode([UInt8](repeating: 3, count: 32))
        XCTAssertTrue(try DeviceBindingStore(url: url, ownFingerprint: newKey).all.isEmpty)
    }
}

final class BindingConnectionAuthorizationTests: XCTestCase {
    func testCrossAppTransfersNeverUseBindingPermission() throws {
        let own = OpaqueToken.encode([UInt8](repeating: 14, count: 32)), peer = OpaqueToken.encode([UInt8](repeating: 15, count: 32))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DeviceBindingStore(url: directory.appendingPathComponent("bindings"), ownFingerprint: own)
        let id = "23bd2c63-731a-4e5d-b212-741a0c4679f8"
        try store.put(DeviceBindingRecord(ownFingerprint: own, peerFingerprint: peer, bindingID: id, alias: "Sender", deviceType: "iphone"))
        let controller = DeviceBindingController(store: store, alias: "Receiver", deviceType: "mac")
        for (host, helloHeader, helloApp, offerApp) in [
            ("casecheck", "limlink", "limlink", "limlink"),
            ("limlink", "casecheck", "limlink", "casecheck"),
            ("limlink", "limlink", "casecheck", "limlink"),
            ("limlink", "limlink", "limlink", "casecheck")
        ] {
            let service = SingleFileService(configuration: try .make(app: host, deviceName: "Receiver", deviceType: .mac), trustedFingerprints: [peer], deviceBinding: controller)
            let hello = HTTPRequest(method: "POST", target: "/limlink/v1/hello", headers: ["host": "receiver", "X-LimLink-App": helloHeader], body: JSONWire.data(["proto": ["1.0"], "alias": "Sender", "app": helloApp, "devType": "iphone", "port": 52470, "bindingId": id]))
            let response = service.step(hello, peerIsLocal: false, fingerprint: peer, connectionID: "owner").response
            if host != "limlink" || helloHeader != "limlink" || helloApp != "limlink" {
                XCTAssertNil(JSONWire.object(response.body)?["bindingId"])
                XCTAssertFalse((JSONWire.object(response.body)?["caps"] as? [String] ?? []).contains("binding-v1"))
            }
            let created = service.step(WireApp.request(method: "POST", path: "/limlink/v1/sessions", app: offerApp, hostHeader: "receiver", body: JSONWire.data(["clientSessionKey": "one", "transport": "lan", "entries": [["id": "f", "kind": "file", "relativePath": "empty.txt", "size": 0]]]), json: true), peerIsLocal: false, fingerprint: peer, connectionID: "owner")
            XCTAssertEqual(created.response.status, 202, "Cross-app transfer remains available with manual consent")
            let sessionID = try XCTUnwrap(JSONWire.string(try XCTUnwrap(JSONWire.object(created.response.body)), "sessionId"))
            let pending = try XCTUnwrap(service.step(WireApp.request(method: "GET", path: "/limlink/v1/sessions/\(sessionID)?wait=25", app: offerApp, hostHeader: "receiver", body: [], json: false), peerIsLocal: false, fingerprint: peer, connectionID: "owner").pending)
            XCTAssertNil(pending.bindingID, "Other apps must never inherit automatic consent")
        }
        let otherAppHello = WireApp.helloRequest(app: "casecheck", alias: "Sender", devType: "mac", port: 52470, hostHeader: "receiver", bindingID: id)
        XCTAssertNil(JSONWire.object(otherAppHello.body)?["bindingId"])
        XCTAssertFalse((JSONWire.object(otherAppHello.body)?["caps"] as? [String] ?? []).contains("binding-v1"))
    }

    func testEachOfferUsesThisConnectionHelloAndRevocationRechecksStore() throws {
        let own = OpaqueToken.encode([UInt8](repeating: 4, count: 32)), peer = OpaqueToken.encode([UInt8](repeating: 5, count: 32))
        let store = try DeviceBindingStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("bindings"), ownFingerprint: own)
        let id = "23bd2c63-731a-4e5d-b212-741a0c4679f8"
        let controller = DeviceBindingController(store: store, alias: "Receiver", deviceType: "mac")
        let record = DeviceBindingRecord(ownFingerprint: own, peerFingerprint: peer, bindingID: id, alias: "Sender", deviceType: "iphone")
        try store.put(record)
        let service = SingleFileService(configuration: try .make(deviceName: "Receiver", deviceType: .mac), trustedFingerprints: [peer], deviceBinding: controller)
        func hello(_ binding: String?, _ connection: String) -> HTTPResponse {
            var object: [String: Any] = ["alias": "Sender", "app": "limlink", "devType": "iphone", "port": 52470, "proto": ["1.0"]]
            object["bindingId"] = binding
            return service.step(WireApp.request(method: "POST", path: "/limlink/v1/hello", app: "limlink", hostHeader: "receiver", body: JSONWire.data(object), json: true), peerIsLocal: false, fingerprint: peer, connectionID: connection).response
        }
        func offer(_ key: String, _ connection: String) -> PendingSession? {
            let created = service.step(WireApp.request(method: "POST", path: "/limlink/v1/sessions", app: "limlink", hostHeader: "receiver", body: JSONWire.data(["clientSessionKey": key, "transport": "lan", "entries": [["id": "f", "kind": "file", "relativePath": "empty.txt", "size": 0]]]), json: true), peerIsLocal: false, fingerprint: peer, connectionID: connection)
            XCTAssertEqual(created.response.status, 202)
            guard let object = JSONWire.object(created.response.body), let sessionID = JSONWire.string(object, "sessionId") else {
                XCTFail("Creating an offer must return its session ID")
                return nil
            }
            // Consent is requested when the sender polls the created session.
            return service.step(WireApp.request(method: "GET", path: "/limlink/v1/sessions/\(sessionID)?wait=25", app: "limlink", hostHeader: "receiver", body: [], json: false), peerIsLocal: false, fingerprint: peer, connectionID: connection).pending
        }
        XCTAssertEqual(JSONWire.object(hello(id, "matched").body)?["bindingId"] as? String, id)
        let approved = try XCTUnwrap(offer("first", "matched"))
        XCTAssertTrue(controller.permits(peer: approved.fingerprint, bindingID: approved.bindingID))
        _ = hello(nil, "legacy")
        let legacy = try XCTUnwrap(offer("second", "legacy"))
        XCTAssertFalse(controller.permits(peer: legacy.fingerprint, bindingID: legacy.bindingID))
        _ = hello("23bd2c63-731a-4e5d-b212-741a0c4679f9", "wrong")
        let wrong = try XCTUnwrap(offer("third", "wrong"))
        XCTAssertFalse(controller.permits(peer: wrong.fingerprint, bindingID: wrong.bindingID))
        try controller.unbind(record)
        let subsequent = try XCTUnwrap(offer("fourth", "matched"))
        XCTAssertEqual(subsequent.bindingID, id)
        XCTAssertFalse(controller.permits(peer: subsequent.fingerprint, bindingID: subsequent.bindingID))
        XCTAssertNil(JSONWire.object(hello(id, "matched").body)?["bindingId"])
    }
    func testDeadlineCannotBeExtendedByPollingAndOldRevokeCannotRemoveNewBinding() throws {
        let clock = BindingTestClock()
        let own = OpaqueToken.encode([UInt8](repeating: 6, count: 32)), peer = OpaqueToken.encode([UInt8](repeating: 7, count: 32))
        let store = try DeviceBindingStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("bindings"), ownFingerprint: own)
        let controller = DeviceBindingController(store: store, alias: "Receiver", deviceType: "mac", now: { clock.time })
        func request(_ route: String, token: String? = nil, start: Bool = false) -> HTTPRequest {
            var headers = ["host": "receiver", "X-LimLink-App": "limlink"]; headers["X-LimLink-Pair-Token"] = token
            return HTTPRequest(method: start || route.contains("/") ? "POST" : "GET", target: "/limlink/v1/pair/" + route, headers: headers, body: JSONWire.data(start ? ["version": 1, "requestId": UUID().uuidString.lowercased(), "alias": "Sender", "deviceType": "iphone"] : [:]))
        }
        let start = controller.handle(request("start", start: true), fingerprint: peer, connectionID: "owner")
        let object = try XCTUnwrap(JSONWire.object(start.body)), id = try XCTUnwrap(object["pairId"] as? String), token = try XCTUnwrap(object["token"] as? String)
        clock.time = 119
        XCTAssertEqual(controller.handle(request(id, token: token), fingerprint: peer, connectionID: "owner").status, 200)
        controller.decide(pairID: id, accept: true)
        clock.time = 120
        XCTAssertEqual(controller.handle(request(id + "/complete", token: token), fingerprint: peer, connectionID: "owner").status, 410)
        XCTAssertTrue(store.all.isEmpty)
        let newID = "8e01e49b-1392-454a-b9d7-3c515cb1fdb8"
        try store.put(DeviceBindingRecord(ownFingerprint: own, peerFingerprint: peer, bindingID: newID, alias: "Sender renamed", deviceType: "iphone"))
        XCTAssertEqual(controller.handle(request(id + "/revoke"), fingerprint: peer, connectionID: "new").status, 200)
        XCTAssertEqual(store.record(for: peer)?.bindingID, newID)
    }
    private final class BindingTestClock: @unchecked Sendable {
        private let lock = NSLock(); private var value: TimeInterval = 0
        var time: TimeInterval { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
    }
}

final class DeviceBindingMutualTLSTests: XCTestCase, @unchecked Sendable {
    func testOversizedControlClosesBeforeReadingItsBody() async throws {
        let server = try KeychainDeviceIdentity.ephemeral(), client = try KeychainDeviceIdentity.ephemeral()
        defer { try? server.store.delete(); try? client.store.delete() }
        let config = try LimLinkConfiguration.make(deviceName: "Receiver", deviceType: .mac)
        let service = SingleFileService(configuration: config)
        let listener = try await LimLinkListener.start(configuration: config, identity: server.material, trust: .acceptAndReport, scope: .loopback, advertise: nil)
        defer { listener.stop() }
        let closed = expectation(description: "oversized pairing content-length closes without waiting for body")
        let serving = Task {
            let inbound = try await listener.nextConnection()
            await service.serve(inbound, requestLimits: HTTPRequestLimits(maximumBodyBytes: 1_048_576))
            closed.fulfill()
        }
        let connection = try await LimLinkConnection.connect(host: "127.0.0.1", port: listener.port, identity: client.material, trust: .allowListed([server.material.fingerprint]), scope: .loopback)
        try await connection.send(Array("POST /limlink/v1/pair/start HTTP/1.1\r\nHost: limlink\r\nX-LimLink-App: limlink\r\nContent-Length: 16385\r\n\r\n".utf8))
        await fulfillment(of: [closed], timeout: 2)
        connection.cancel()
        try await serving.value
    }

    func testProductionPinnedClientWaitsForActualTLSRecipientThenBothStoresAndHelloMatch() async throws {
        let server = try KeychainDeviceIdentity.ephemeral(), client = try KeychainDeviceIdentity.ephemeral()
        defer { try? server.store.delete(); try? client.store.delete() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let serverStore = try DeviceBindingStore(url: directory.appendingPathComponent("server.json"), ownFingerprint: server.material.fingerprint.base64URL)
        let clientStore = try DeviceBindingStore(url: directory.appendingPathComponent("client.json"), ownFingerprint: client.material.fingerprint.base64URL)
        let controller = DeviceBindingController(store: serverStore, alias: "Receiver", deviceType: "mac")
        let config = try LimLinkConfiguration.make(deviceName: "Receiver", deviceType: .mac)
        let service = SingleFileService(configuration: config, deviceBinding: controller)
        let listener = try await LimLinkListener.start(configuration: config, identity: server.material, trust: .acceptAndReport, scope: .loopback, advertise: nil)
        defer { listener.stop() }
        let requested = expectation(description: "recipient must explicitly accept")
        controller.onChange = { request in if request != nil { requested.fulfill() } }
        let serving = Task {
            let inbound = try await listener.nextConnection()
            XCTAssertEqual(inbound.peerFingerprint, client.material.fingerprint)
            XCTAssertTrue(inbound.verifyObservation.sawCertificate)
            await service.serve(inbound, requestLimits: HTTPRequestLimits(maximumHeaderBytes: 16_384, maximumBodyBytes: 16_384))
        }
        let connection = try await LimLinkConnection.connect(host: "127.0.0.1", port: listener.port, identity: client.material, trust: .allowListed([server.material.fingerprint]), scope: .loopback)
        let binding = Task { try await DeviceBindingClient.bind(connection: connection, selectedFingerprint: server.material.fingerprint.base64URL, store: clientStore, alias: "Sender", deviceType: "mac") }
        await fulfillment(of: [requested], timeout: 10)
        XCTAssertTrue(serverStore.all.isEmpty)
        XCTAssertTrue(clientStore.all.isEmpty)
        let incoming = try XCTUnwrap(controller.pending)
        XCTAssertEqual(incoming.fingerprint, client.material.fingerprint.base64URL)
        controller.decide(pairID: incoming.id, accept: true)
        let record = try await binding.value
        connection.cancel()
        try await serving.value
        XCTAssertEqual(record.bindingID, incoming.id)
        XCTAssertEqual(serverStore.record(for: client.material.fingerprint.base64URL)?.bindingID, record.bindingID)
        XCTAssertEqual(clientStore.record(for: server.material.fingerprint.base64URL)?.bindingID, record.bindingID)
        let helloServing = Task {
            let inbound = try await listener.nextConnection()
            await service.serve(inbound)
        }
        let fileConnection = try await LimLinkConnection.connect(host: "127.0.0.1", port: listener.port, identity: client.material, trust: .allowListed([server.material.fingerprint]), scope: .loopback)
        let hello = try await FramedExchange.transact(fileConnection, WireApp.helloRequest(app: "limlink", alias: "Renamed sender", devType: "mac", port: Int(listener.port), hostHeader: "receiver", bindingID: record.bindingID))
        XCTAssertEqual(JSONWire.object(hello.body)?["bindingId"] as? String, record.bindingID)
        fileConnection.cancel()
        try await helloServing.value
    }
}
