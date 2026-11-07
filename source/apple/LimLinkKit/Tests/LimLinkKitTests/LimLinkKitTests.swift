import Foundation
import Network
import Security
import XCTest
@testable import LimLinkKit
@testable import LimLinkCoreLogic

/// One class so XCTest runs the port-sensitive cases serially.
final class LimLinkKitIntegrationTests: XCTestCase {
    func testKeychainIdentityRoundTrip() throws {
        let ephemeral = try testIdentity(deviceType: .mac)
        defer { try? ephemeral.store.delete() }
        let again = try ephemeral.store.loadOrCreate()
        XCTAssertEqual(again.fingerprint, ephemeral.material.fingerprint)
        XCTAssertEqual(ephemeral.material.commonName, "limlink")
        XCTAssertEqual(ephemeral.material.fingerprint.base64URL.count, 43)
        let reset = try ephemeral.store.reset()
        XCTAssertNotEqual(reset.fingerprint, ephemeral.material.fingerprint)
        try ephemeral.store.delete()
        let recreated = try ephemeral.store.loadOrCreate()
        XCTAssertNotEqual(recreated.fingerprint, reset.fingerprint)
        try ephemeral.store.delete()
    }

    func testReceiverRejectsInvalidManifestBeforeOfferingFile() throws {
        var receiver = try offerReceiver()
        let invalidPath = receiver.handle(fileManifest(name: "folder/escape.txt", size: 3), peerAddressIsLocal: false, clientFingerprint: "peer")
        XCTAssertEqual(try receiverResponse(invalidPath).status, 400)
        XCTAssertEqual(WireApp.decodeError(try receiverResponse(invalidPath).body)?.code, .pathInvalid)
        let negativeSize = receiver.handle(fileManifest(name: "note.txt", size: -1), peerAddressIsLocal: false, clientFingerprint: "peer")
        XCTAssertEqual(try receiverResponse(negativeSize).status, 400)
        XCTAssertTrue(receiver.sessions.isEmpty)
    }

    func testReceiverOffersValidatedNameAndExactSizeBeforeRejecting() throws {
        var receiver = try offerReceiver()
        let created = receiver.handle(fileManifest(name: "CON.txt", size: 4_294_967_297), peerAddressIsLocal: false, clientFingerprint: "peer")
        XCTAssertEqual(try receiverResponse(created).status, 202)
        XCTAssertEqual(receiver.sessions["session"]?.finalName, "CON_.txt")
        XCTAssertEqual(receiver.sessions["session"]?.size, 4_294_967_297)
        let waiting = receiver.handle(sessionPoll("session"), peerAddressIsLocal: false, clientFingerprint: "peer")
        XCTAssertEqual(waiting, .awaitDecision(sessionID: "session"))
        XCTAssertNil(receiver.sessions["session"]?.published)
        receiver.decide(sessionID: "session", accept: false)
        let rejected = try receiverResponse(receiver.handle(sessionPoll("session"), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(rejected.status, 403)
        XCTAssertEqual(WireApp.decodeError(rejected.body)?.code, .rejected)
        let complete = try receiverResponse(receiver.handle(
            fileComplete("session", digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            peerAddressIsLocal: false,
            clientFingerprint: "peer"
        ))
        XCTAssertEqual(complete.status, 409)
        XCTAssertNil(receiver.sessions["session"]?.published)
    }

    func testReceiverRequiresAcceptanceAndVerificationForEmptyFile() throws {
        var receiver = try offerReceiver()
        let created = receiver.handle(fileManifest(name: "empty.txt", size: 0), peerAddressIsLocal: false, clientFingerprint: "peer")
        XCTAssertEqual(try receiverResponse(created).status, 202)
        XCTAssertEqual(receiver.sessions["session"]?.size, 0)
        XCTAssertEqual(receiver.handle(sessionPoll("session"), peerAddressIsLocal: false, clientFingerprint: "peer"), .awaitDecision(sessionID: "session"))
        let digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let premature = try receiverResponse(receiver.handle(fileComplete("session", digest: digest), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(premature.status, 409)
        XCTAssertNil(receiver.sessions["session"]?.published)
        receiver.decide(sessionID: "session", accept: true)
        let upload = try receiverResponse(receiver.handle(fileUpload("session", bytes: [], token: "test-token"), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(upload.status, 200)
        XCTAssertNil(receiver.sessions["session"]?.published)
        let complete = try receiverResponse(receiver.handle(fileComplete("session", digest: digest), peerAddressIsLocal: false, clientFingerprint: "peer"))
        XCTAssertEqual(complete.status, 200)
        XCTAssertEqual(receiver.sessions["session"]?.published, [])
        XCTAssertEqual(receiver.sessions["session"]?.finalName, "empty.txt")
    }

    func testSingleFilePendingMetadataAndRejectionOnLoopback() async throws {
        let observations = ServiceObservations()
        let published = XCTestExpectation(description: "rejected file is never published")
        published.isInverted = true
        try await withSingleFileService(
            observations: observations,
            onPublished: { _, _ in published.fulfill() }
        ) { service, outbound in
            // TLS admission does not replace the separate host trust decision.
            let untrusted = try await FramedExchange.transact(outbound, fileManifest(name: "CON.txt", size: 3))
            XCTAssertEqual(untrusted.status, 401)
            XCTAssertEqual(WireApp.decodeError(untrusted.body)?.code, .notPaired)
            XCTAssertTrue(observations.pending.isEmpty)

            service.trust(observations.localFingerprint)
            let created = try await FramedExchange.transact(outbound, fileManifest(name: "CON.txt", size: 3))
            XCTAssertEqual(created.status, 202)
            let sessionID = try XCTUnwrap(JSONWire.object(created.body).flatMap { JSONWire.string($0, "sessionId") })
            XCTAssertTrue(observations.pending.isEmpty)

            let waiting = try await FramedExchange.transact(outbound, sessionPoll(sessionID))
            XCTAssertEqual(waiting.status, 202)
            let offer = try XCTUnwrap(observations.pending.last)
            XCTAssertEqual(offer.sessionID, sessionID)
            XCTAssertEqual(offer.fingerprint, observations.localFingerprint)
            XCTAssertEqual(offer.fileName, "CON_.txt")
            XCTAssertEqual(offer.size, 3)
            XCTAssertTrue(observations.published.isEmpty)

            service.decide(sessionID: offer.sessionID, accept: false)
            let rejected = try await FramedExchange.transact(outbound, sessionPoll(sessionID))
            XCTAssertEqual(rejected.status, 403)
            XCTAssertEqual(WireApp.decodeError(rejected.body)?.code, .rejected)
            let upload = try await FramedExchange.transact(outbound, fileUpload(sessionID, bytes: Array("abc".utf8), token: "not-issued"))
            XCTAssertEqual(upload.status, 409)
            XCTAssertEqual(WireApp.decodeError(upload.body)?.code, .invalidState)
            let complete = try await FramedExchange.transact(outbound, fileComplete(sessionID, digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
            XCTAssertEqual(complete.status, 409)
            XCTAssertEqual(WireApp.decodeError(complete.body)?.code, .invalidState)
        }
        await fulfillment(of: [published], timeout: 0.1)
        XCTAssertTrue(observations.published.isEmpty)
    }

    func testSingleFileZeroByteOfferRequiresAcceptanceOnLoopback() async throws {
        let observations = ServiceObservations()
        let published = XCTestExpectation(description: "accepted empty file is published")
        try await withSingleFileService(
            observations: observations,
            onPublished: { _, _ in published.fulfill() }
        ) { service, outbound in
            service.trust(observations.localFingerprint)
            let created = try await FramedExchange.transact(outbound, fileManifest(name: "empty.txt", size: 0))
            XCTAssertEqual(created.status, 202)
            let sessionID = try XCTUnwrap(JSONWire.object(created.body).flatMap { JSONWire.string($0, "sessionId") })
            let waiting = try await FramedExchange.transact(outbound, sessionPoll(sessionID))
            XCTAssertEqual(waiting.status, 202)
            let offer = try XCTUnwrap(observations.pending.last)
            XCTAssertEqual(offer.fileName, "empty.txt")
            XCTAssertEqual(offer.size, 0)
            XCTAssertTrue(observations.published.isEmpty)

            service.decide(sessionID: sessionID, accept: true)
            let accepted = try await FramedExchange.transact(outbound, sessionPoll(sessionID))
            XCTAssertEqual(accepted.status, 200)
            let object = try XCTUnwrap(JSONWire.object(accepted.body))
            let files = try XCTUnwrap(object["files"] as? [String: Any])
            let file = try XCTUnwrap(files["file-1"] as? [String: Any])
            let token = try XCTUnwrap(JSONWire.string(file, "token"))
            let upload = try await FramedExchange.transact(outbound, fileUpload(sessionID, bytes: [], token: token))
            XCTAssertEqual(upload.status, 200)
            XCTAssertTrue(observations.published.isEmpty)
            let complete = try await FramedExchange.transact(outbound, fileComplete(sessionID, digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
            XCTAssertEqual(complete.status, 200)
            XCTAssertEqual(JSONWire.object(complete.body).flatMap { JSONWire.string($0, "finalName") }, "empty.txt")
        }
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(observations.published.count, 1)
        XCTAssertEqual(observations.published.first?.name, "empty.txt")
        XCTAssertEqual(observations.published.first?.bytes, [])
    }

    func testPublicationOverrideAcknowledgesDurableSavedNameOnLoopback() async throws {
        let defaults = ServiceObservations()
        let overrides = ServiceObservations()
        try await withSingleFileService(
            observations: defaults,
            discardSessionsOnDisconnect: true,
            onPendingOverride: { overrides.record($0) },
            onPublicationOverride: { file in
                try await Task.sleep(for: .milliseconds(40))
                overrides.record(file)
                return "empty (1).txt"
            },
            onPublished: { _, _ in XCTFail("constructor callback should be overridden") }
        ) { service, outbound in
            service.trust(defaults.localFingerprint)
            let created = try await FramedExchange.transact(outbound, fileManifest(name: "empty.txt", size: 0))
            let sid = try XCTUnwrap(JSONWire.object(created.body).flatMap { JSONWire.string($0, "sessionId") })
            _ = try await FramedExchange.transact(outbound, sessionPoll(sid))
            XCTAssertTrue(defaults.pending.isEmpty)
            XCTAssertEqual(overrides.pending.last?.sessionID, sid)
            XCTAssertTrue(service.decide(sessionID: sid, accept: true))
            let complete = try await FramedExchange.transact(outbound, fileComplete(sid, digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
            XCTAssertEqual(complete.status, 200)
            XCTAssertEqual(JSONWire.object(complete.body).flatMap { JSONWire.string($0, "finalName") }, "empty (1).txt")
            XCTAssertEqual(overrides.publications.last?.sessionID, sid)
            XCTAssertEqual(overrides.publications.last?.fingerprint, defaults.localFingerprint)
            XCTAssertEqual(overrides.publications.last?.fileName, "empty.txt")
            XCTAssertEqual(overrides.publications.last?.size, 0)
            XCTAssertEqual(overrides.publications.last?.bytes, [])
            XCTAssertTrue(defaults.published.isEmpty)
        }
    }

    func testPublicationSaveFailureIsNotAcknowledgedOnLoopback() async throws {
        let observations = ServiceObservations()
        try await withSingleFileService(
            observations: observations,
            discardSessionsOnDisconnect: true,
            onPublicationOverride: { _ in throw TestSaveFailure.failed },
            onPublished: { _, _ in XCTFail("failed durable save was published") }
        ) { service, outbound in
            service.trust(observations.localFingerprint)
            let created = try await FramedExchange.transact(outbound, fileManifest(name: "empty.txt", size: 0))
            let sid = try XCTUnwrap(JSONWire.object(created.body).flatMap { JSONWire.string($0, "sessionId") })
            XCTAssertTrue(service.decide(sessionID: sid, accept: true))
            let complete = try await FramedExchange.transact(outbound, fileComplete(sid, digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
            XCTAssertEqual(complete.status, 500)
            XCTAssertEqual(WireApp.decodeError(complete.body)?.code, .writeFailed)
            XCTAssertTrue(observations.published.isEmpty)
        }
    }

    func testDisconnectCleanupDiscardsUnpolledOwnedSessionsOnlyOnLoopback() async throws {
        let first = ServiceObservations()
        let second = ServiceObservations()
        var retainedSessionID = ""
        let service = try await withSingleFileService(
            observations: first,
            maximumRetainedSessions: 2,
            discardSessionsOnDisconnect: true,
            onPublished: { _, _ in }
        ) { service, outbound in
            service.trust(first.localFingerprint)
            let owned = try await FramedExchange.transact(outbound, fileManifest(name: "owned.txt", size: 1))
            XCTAssertEqual(owned.status, 202)
            _ = try await withSingleFileService(observations: second, existingService: service, onPublished: { _, _ in }) { _, other in
                service.trust(second.localFingerprint)
                let created = try await FramedExchange.transact(other, fileManifest(name: "retained.txt", size: 1))
                XCTAssertEqual(created.status, 202)
                retainedSessionID = try XCTUnwrap(JSONWire.object(created.body).flatMap { JSONWire.string($0, "sessionId") })
            }
        }
        let third = ServiceObservations()
        try await withSingleFileService(observations: third, existingService: service, discardSessionsOnDisconnect: true, onPublished: { _, _ in }) { _, outbound in
            service.trust(third.localFingerprint)
            let retained = try await FramedExchange.transact(outbound, sessionPoll(retainedSessionID))
            XCTAssertEqual(retained.status, 404)
            XCTAssertEqual(WireApp.decodeError(retained.body)?.code, .sessionNotFound)
            let created = try await FramedExchange.transact(outbound, fileManifest(name: "new.txt", size: 1))
            XCTAssertEqual(created.status, 202)
            let full = try await FramedExchange.transact(outbound, fileManifest(name: "overflow.txt", size: 1))
            XCTAssertEqual(full.status, 409)
            XCTAssertEqual(WireApp.decodeError(full.body)?.code, .busy)
        }
    }

    func testSingleFileHelloOnLoopback() async throws {
        let server = try testIdentity(deviceType: .iphone)
        let client = try testIdentity(deviceType: .iphone)
        defer {
            try? server.store.delete()
            try? client.store.delete()
        }
        let configuration = try LimLinkConfiguration.make(deviceName: "limlink-server", deviceType: .iphone)
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: server.material,
            trust: .allowListed([client.material.fingerprint]),
            scope: .loopback,
            advertise: nil
        )
        defer { listener.stop() }
        let service = SingleFileService(configuration: configuration)
        let serve = Task {
            let inbound = try await listener.nextConnection()
            await service.serve(inbound)
        }
        let outbound = try await LimLinkConnection.connect(
            host: "127.0.0.1",
            port: listener.port,
            identity: client.material,
            trust: .allowListed([server.material.fingerprint]),
            scope: .loopback
        )
        let request = WireApp.helloRequest(
            app: configuration.hostApp.app,
            alias: "甲",
            devType: "iphone",
            port: Int(listener.port),
            hostHeader: "127.0.0.1"
        )
        let response = try await FramedExchange.transact(outbound, request)
        outbound.cancel()
        try await serve.value
        XCTAssertEqual(response.status, 200)
        let hello = try XCTUnwrap(WireApp.decodeHello(response.body))
        XCTAssertTrue(hello.appPresent)
        XCTAssertEqual(hello.app, "limlink")
    }

    func testLoopbackMutualTLS13() async throws {
        note("LIMLINK_ALLOW_FAST_OPEN_DEFAULT \(TLSParametersProbe.allowFastOpenDefault())")
        let server = try testIdentity()
        let client = try testIdentity()
        defer {
            try? server.store.delete()
            try? client.store.delete()
        }
        let configuration = try LimLinkConfiguration.make(deviceName: "limlink-server", deviceType: .mac)
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: server.material,
            trust: .allowListed([client.material.fingerprint]),
            scope: .loopback,
            advertise: nil
        )
        defer { listener.stop() }
        let outbound = try await LimLinkConnection.connect(
            host: "127.0.0.1",
            port: listener.port,
            identity: client.material,
            trust: .allowListed([server.material.fingerprint]),
            scope: .loopback
        )
        defer { outbound.cancel() }
        let inbound = try await listener.nextConnection()
        defer { inbound.cancel() }

        XCTAssertEqual(outbound.negotiatedVersionRaw, LimLinkProtocol.tls13WireVersion)
        XCTAssertEqual(inbound.negotiatedVersionRaw, LimLinkProtocol.tls13WireVersion)
        XCTAssertFalse(outbound.earlyDataAccepted)
        XCTAssertFalse(inbound.earlyDataAccepted)
        XCTAssertEqual(inbound.peerFingerprint, client.material.fingerprint)
        XCTAssertEqual(outbound.peerFingerprint, server.material.fingerprint)
        XCTAssertTrue(outbound.negotiatedALPN == nil || outbound.negotiatedALPN == LimLinkProtocol.alpnHTTP11)
        XCTAssertTrue(inbound.negotiatedALPN == nil || inbound.negotiatedALPN == LimLinkProtocol.alpnHTTP11)

        let clientVerify = outbound.verifyObservation
        let serverVerify = inbound.verifyObservation
        note("LIMLINK_VERIFY_BLOCK_VERSION client=\(clientVerify.negotiatedVersionRaw) available=\(clientVerify.versionWasAvailable) server=\(serverVerify.negotiatedVersionRaw) available=\(serverVerify.versionWasAvailable)")
        note("LIMLINK_EARLY_DATA_ACCEPTED client=\(outbound.earlyDataAccepted) server=\(inbound.earlyDataAccepted)")
        note("LIMLINK_SERVER_SAW_CLIENT_CERT \(serverVerify.sawCertificate) fp=\(inbound.peerFingerprint.base64URL)")
        if clientVerify.versionWasAvailable {
            XCTAssertEqual(clientVerify.negotiatedVersionRaw, LimLinkProtocol.tls13WireVersion)
        }
        if serverVerify.versionWasAvailable {
            XCTAssertEqual(serverVerify.negotiatedVersionRaw, LimLinkProtocol.tls13WireVersion)
        }
    }

    func testUnknownFingerprintRejected() async throws {
        let server = try testIdentity()
        let client = try testIdentity()
        defer {
            try? server.store.delete()
            try? client.store.delete()
        }
        let configuration = try LimLinkConfiguration.make(deviceName: "limlink-server", deviceType: .mac)
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: server.material,
            trust: .allowListed([client.material.fingerprint]),
            scope: .loopback,
            advertise: nil
        )
        defer { listener.stop() }
        let unknown = try Fingerprint(rawSHA256: [UInt8](repeating: 0xab, count: 32))
        do {
            _ = try await LimLinkConnection.connect(
                host: "127.0.0.1",
                port: listener.port,
                identity: client.material,
                trust: .allowListed([unknown]),
                scope: .loopback,
                timeout: .seconds(15)
            )
            XCTFail("unknown fingerprint was accepted")
        } catch {
            note("LIMLINK_UNKNOWN_FINGERPRINT \(error)")
        }
    }

    func testTLS12ClientRejected() async throws {
        let server = try testIdentity()
        let client = try testIdentity()
        defer {
            try? server.store.delete()
            try? client.store.delete()
        }
        let configuration = try LimLinkConfiguration.make(deviceName: "limlink-server", deviceType: .mac)
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: server.material,
            trust: .acceptAndReport,
            scope: .loopback,
            advertise: nil
        )
        defer { listener.stop() }
        do {
            _ = try await LimLinkConnection.connect(
                host: "127.0.0.1",
                port: listener.port,
                identity: client.material,
                trust: .allowListed([server.material.fingerprint]),
                cap: .only12,
                scope: .loopback,
                timeout: .seconds(15)
            )
            XCTFail("TLS 1.2 client completed a handshake")
        } catch {
            note("LIMLINK_TLS12_REJECTED \(error)")
        }
    }

    func testSecondConnectionStillPresentsCertificate() async throws {
        let server = try testIdentity()
        let client = try testIdentity()
        defer {
            try? server.store.delete()
            try? client.store.delete()
        }
        let configuration = try LimLinkConfiguration.make(deviceName: "limlink-server", deviceType: .mac)
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: server.material,
            trust: .allowListed([client.material.fingerprint]),
            scope: .loopback,
            advertise: nil
        )
        defer { listener.stop() }
        let first = try await LimLinkConnection.connect(
            host: "127.0.0.1",
            port: listener.port,
            identity: client.material,
            trust: .allowListed([server.material.fingerprint]),
            scope: .loopback
        )
        let firstInbound = try await listener.nextConnection()
        first.cancel()
        firstInbound.cancel()
        let second = try await LimLinkConnection.connect(
            host: "127.0.0.1",
            port: listener.port,
            identity: client.material,
            trust: .allowListed([server.material.fingerprint]),
            scope: .loopback
        )
        defer { second.cancel() }
        let secondInbound = try await listener.nextConnection()
        defer { secondInbound.cancel() }
        XCTAssertEqual(secondInbound.peerFingerprint, client.material.fingerprint)
        XCTAssertTrue(secondInbound.verifyObservation.sawCertificate)
        note("LIMLINK_SECOND_CONNECTION_SAW_CERT \(secondInbound.verifyObservation.sawCertificate)")
    }

    func testPortFallbackWhenPrimaryIsTaken() async throws {
        let occupier = try await occupyPort(LimLinkProtocol.primaryPort)
        defer { occupier.cancel() }
        let identity = try testIdentity()
        defer { try? identity.store.delete() }
        let configuration = try LimLinkConfiguration.make(deviceName: "limlink-server", deviceType: .mac)
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: identity.material,
            trust: .acceptAndReport,
            scope: .loopback,
            advertise: nil
        )
        defer { listener.stop() }
        note("LIMLINK_PORT_FALLBACK \(listener.port) \(listener.portDiagnostic)")
        XCTAssertNotEqual(listener.port, LimLinkProtocol.primaryPort)
        XCTAssertEqual(listener.portDiagnostic, .fallback(port: listener.port, offset: Int(listener.port - LimLinkProtocol.primaryPort)))
    }

    func testBonjourBrowseIsOptIn() async throws {
        guard ProcessInfo.processInfo.environment[LimLinkBonjourProbe.optInEnvironmentVariable] == "1" else {
            throw XCTSkip(
                "\(LimLinkBonjourProbe.optInEnvironmentVariable) is unset. GitHub macOS runners cannot approve the Local Network prompt, so this browse is not part of CI."
            )
        }
        let identity = try testIdentity()
        defer { try? identity.store.delete() }
        let configuration = try LimLinkConfiguration.make(deviceName: "limlink-bonjour", deviceType: .mac)
        let instance = "llk-\(UUID().uuidString.prefix(8))"
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: identity.material,
            trust: .acceptAndReport,
            scope: .localNetwork,
            advertise: BonjourAdvertisement(instanceName: instance)
        )
        defer { listener.stop() }
        let browser = LimLinkBrowser(host: configuration.hostApp, selfFingerprint: nil)
        browser.start()
        defer { browser.stop() }
        let fingerprint = identity.material.fingerprint.base64URL
        let partition = try await browser.waitFor(timeout: .seconds(8)) { snapshot in
            snapshot.visible.contains { service in
                service.instanceName == instance && service.fields.fingerprint == fingerprint
            }
        }
        let match = try XCTUnwrap(partition.visible.first { $0.instanceName == instance })
        XCTAssertEqual(match.fields.fingerprint, fingerprint)
        XCTAssertEqual(match.app, configuration.hostApp.app)
        XCTAssertEqual(match.fields.protocolVersions, "1")
        XCTAssertEqual(match.fields.deviceType, DeviceType.mac.rawValue)
        XCTAssertFalse(match.fields.inviting)
        note("LIMLINK_BONJOUR_OK instance=\(instance)")
    }

    /// One run, several listeners. Each attempt has a 2s cap and is cancelled before the next.
    func testListenerStartLadder() async throws {
        let identity = try testIdentity()
        defer { try? identity.store.delete() }
        var ladder: [String] = []

        ladder.append(await probeListener(name: "a-tcp-any", parameters: .tcp, port: .any))

        let localOnly = NWParameters.tcp
        localOnly.acceptLocalOnly = true
        ladder.append(await probeListener(name: "b-acceptLocalOnly", parameters: localOnly, port: .any))

        ladder.append(await probeListener(
            name: "c-tls13-minmax",
            parameters: tlsProbeParameters(identity: nil, acceptLocalOnly: true, fullOptions: false),
            port: .any
        ))
        ladder.append(await probeListener(
            name: "c-tls13-options",
            parameters: tlsProbeParameters(identity: nil, acceptLocalOnly: true, fullOptions: true),
            port: .any
        ))
        ladder.append(await probeListener(
            name: "c-tls13-identity",
            parameters: tlsProbeParameters(identity: identity.material, acceptLocalOnly: true, fullOptions: true),
            port: .any
        ))

        guard let primary = NWEndpoint.Port(rawValue: LimLinkProtocol.primaryPort) else {
            XCTFail("primary port \(LimLinkProtocol.primaryPort) was rejected")
            return
        }
        let fixed = await probeListener(
            name: "d-port-52470",
            parameters: tlsProbeParameters(identity: identity.material, acceptLocalOnly: true, fullOptions: true),
            port: primary
        )
        ladder.append(fixed)
        if fixed.contains(" result=ready") {
            let skipped = "LIMLINK_LISTENER_STEP name=d-fallback result=skipped reason=primary-ready"
            ladder.append(skipped)
            note(skipped)
        } else {
            ladder.append(await probeListener(
                name: "d-fallback-any",
                parameters: tlsProbeParameters(identity: identity.material, acceptLocalOnly: true, fullOptions: true),
                port: .any
            ))
        }

        ladder.append(await productionStep(name: "e-loopback", identity: identity.material, scope: .loopback))
        ladder.append(await productionStep(name: "e-production", identity: identity.material, scope: .localNetwork))

        let zero = NWEndpoint.Port(rawValue: 0)
        note("LIMLINK_PORT_ZERO nil=\(zero == nil) equalsAny=\(zero == .any) anyRaw=\(NWEndpoint.Port.any.rawValue)")
        if let zero, zero != .any {
            _ = await probeListener(name: "bad-port-rawValue-0", parameters: .tcp, port: zero)
        }

        if let endpointPort = NWEndpoint.Port(rawValue: LimLinkProtocol.primaryPort) {
            let conflicted = NWParameters.tcp
            conflicted.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
            _ = await probeListener(name: "bad-requiredLocalEndpoint-and-on", parameters: conflicted, port: endpointPort)
        }

        for (label, kind) in [
            ("wifi", NWInterface.InterfaceType.wifi),
            ("wiredEthernet", .wiredEthernet),
            ("loopback", .loopback),
            ("cellular", .cellular),
        ] {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = kind
            _ = await probeListener(name: "requiredInterfaceType-\(label)", parameters: parameters, port: .any)
        }

        let prohibited = NWParameters.tcp
        prohibited.prohibitedInterfaceTypes = [.wifi, .cellular]
        _ = await probeListener(name: "prohibitedInterfaceTypes-wifi-cellular", parameters: prohibited, port: .any)

        let validBonjour = NWParameters.tcp
        validBonjour.acceptLocalOnly = true
        _ = await probeListener(
            name: "bonjour-valid-type",
            parameters: validBonjour,
            port: .any,
            service: NWListener.Service(name: "limlink-probe", type: LimLinkProtocol.serviceType, txtRecord: NWTXTRecord())
        )
        note("LIMLINK_LISTENER_STEP name=bonjour-malformed begin type=limlink")
        let malformedBonjour = NWParameters.tcp
        malformedBonjour.acceptLocalOnly = true
        _ = await probeListener(
            name: "bonjour-malformed-type",
            parameters: malformedBonjour,
            port: .any,
            service: NWListener.Service(name: "limlink-probe", type: "limlink", txtRecord: NWTXTRecord())
        )

        let failed = ladder.filter { !$0.contains(" result=ready") && !$0.contains(" result=skipped") }
        if !failed.isEmpty {
            XCTFail("listener ladder failed:\n" + failed.joined(separator: "\n"))
        }
    }

    func testPartialDirectoryIsPrivateAndExcludedFromBackup() throws {
        let url = try PartialFileMaintenance.privatePartialURL()
        XCTAssertTrue(url.path.contains("Application Support"))
        XCTAssertTrue(url.path.contains("LimLink/Partial") || url.path.contains("LimLink\\Partial"))
        XCTAssertFalse(PartialFiles.isFilesVisiblePath(url.path))
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}

/// Only skip when an unhosted simulator actually reports missing Keychain access.
/// Listener failures are always test failures, including on CI.
private func testIdentity(deviceType: DeviceType = .mac) throws -> (material: IdentityMaterial, store: KeychainDeviceIdentity) {
    do {
        return try KeychainDeviceIdentity.ephemeral(deviceType: deviceType)
    } catch {
        #if os(iOS) && targetEnvironment(simulator)
        if let failure = error as? TransportFailure,
           failure == .keychain(errSecMissingEntitlement) || failure == .identityKey(errSecMissingEntitlement) {
            throw XCTSkip("The simulator test host lacks Keychain entitlements (errSecMissingEntitlement); run identity and TLS coverage on a signed host or macOS.")
        }
        #endif
        throw error
    }
}

private func note(_ line: String) {
    fputs(line + "\n", stderr)
}

/// Set by the Apple workflow only after listener tests are known not to run on the runner.


private func tlsProbeParameters(
    identity: IdentityMaterial?,
    acceptLocalOnly: Bool,
    fullOptions: Bool
) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
    if fullOptions {
        sec_protocol_options_set_tls_renegotiation_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        sec_protocol_options_set_tls_ocsp_enabled(options, false)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_add_tls_application_protocol(options, LimLinkProtocol.alpnHTTP11)
        if let identity {
            sec_protocol_options_set_local_identity(options, identity.secIdentity)
        }
    }
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.allowFastOpen = false
    parameters.includePeerToPeer = false
    parameters.acceptLocalOnly = acceptLocalOnly
    return parameters
}

private func productionStep(name: String, identity: IdentityMaterial, scope: TransportScope) async -> String {
    do {
        let configuration = try LimLinkConfiguration.make(deviceName: "limlink-probe", deviceType: .mac)
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: identity,
            trust: .acceptAndReport,
            scope: scope,
            advertise: nil,
            timeout: .seconds(2)
        )
        let line = "LIMLINK_LISTENER_STEP name=\(name) result=ready port=\(listener.port) diagnostic=\(listener.portDiagnostic)"
        note(line)
        listener.stop()
        return line
    } catch {
        let line = "LIMLINK_LISTENER_STEP name=\(name) result=fail error=\(error)"
        note(line)
        return line
    }
}

private func probeListener(
    name: String,
    parameters: NWParameters,
    port: NWEndpoint.Port,
    service: NWListener.Service? = nil
) async -> String {
    let summary = listenerSetupSummary(parameters: parameters, port: port)
    let listener: NWListener
    do {
        listener = try NWListener(using: parameters, on: port)
    } catch {
        let line = "LIMLINK_LISTENER_STEP name=\(name) result=initFail \(summary) error=\(error)"
        note(line)
        return line
    }
    if let service {
        listener.service = service
    }
    let queue = DispatchQueue(label: "limlink.probe.\(name)")
    let outcome: String = await withCheckedContinuation { continuation in
        let box = ProbeBox(continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.resume("ready")
            case .failed(let error):
                box.resume("fail error=\(error)")
            case .cancelled:
                box.resume("cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            box.resume("timeout")
        }
    }
    let bound = listener.port?.rawValue ?? 0
    listener.cancel()
    let described = outcome == "ready" ? "ready port=\(bound)" : outcome
    let line = "LIMLINK_LISTENER_STEP name=\(name) result=\(described) \(summary)"
    note(line)
    return line
}

private func occupyPort(_ port: UInt16) async throws -> NWListener {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = false
    parameters.acceptLocalOnly = true
    guard let nwPort = NWEndpoint.Port(rawValue: port), nwPort.rawValue != 0 else {
        throw TransportFailure.posix(0)
    }
    let summary = listenerSetupSummary(parameters: parameters, port: nwPort)
    let listener: NWListener
    do {
        listener = try NWListener(using: parameters, on: nwPort)
    } catch {
        fputs("LIMLINK_OCCUPY_INIT_FAIL \(summary) error=\(error)\n", stderr)
        throw error
    }
    let queue = DispatchQueue(label: "limlink.occupy")
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let box = ResumeBox(continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.resume(with: .success(()))
            case .failed(let error):
                fputs("LIMLINK_OCCUPY_FAIL \(summary) error=\(error)\n", stderr)
                box.resume(with: .failure(TransportFailure(nw: error)))
            case .cancelled:
                box.resume(with: .failure(TransportFailure.cancelled))
            default:
                break
            }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
    }
    return listener
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    func resume(_ value: String) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func resume(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Keeps observations thread safe without replacing the service or receiver.
private final class ServiceObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingStorage: [PendingSession] = []
    private var publishedStorage: [(name: String, bytes: [UInt8])] = []
    private var localFingerprintStorage = ""
    private var publicationStorage: [PublishedFile] = []

    var pending: [PendingSession] {
        lock.lock()
        defer { lock.unlock() }
        return pendingStorage
    }

    var published: [(name: String, bytes: [UInt8])] {
        lock.lock()
        defer { lock.unlock() }
        return publishedStorage
    }

    var publications: [PublishedFile] {
        lock.lock()
        defer { lock.unlock() }
        return publicationStorage
    }

    func record(_ file: PublishedFile) {
        lock.lock()
        publicationStorage.append(file)
        lock.unlock()
    }

    var localFingerprint: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return localFingerprintStorage
        }
        set {
            lock.lock()
            localFingerprintStorage = newValue
            lock.unlock()
        }
    }

    func record(_ offer: PendingSession) {
        lock.lock()
        pendingStorage.append(offer)
        lock.unlock()
    }

    func record(name: String, bytes: [UInt8]) {
        lock.lock()
        publishedStorage.append((name, bytes))
        lock.unlock()
    }
}

@discardableResult
private func withSingleFileService(
    observations: ServiceObservations,
    existingService: SingleFileService? = nil,
    maximumRetainedSessions: Int? = nil,
    discardSessionsOnDisconnect: Bool = false,
    onPendingOverride: (@Sendable (PendingSession) -> Void)? = nil,
    onPublicationOverride: (@Sendable (PublishedFile) async throws -> String)? = nil,
    onPublished: @escaping @Sendable (String, [UInt8]) -> Void,
    body: (SingleFileService, LimLinkConnection) async throws -> Void
) async throws -> SingleFileService {
    let server = try testIdentity(deviceType: .iphone)
    let client = try testIdentity(deviceType: .iphone)
    defer {
        try? server.store.delete()
        try? client.store.delete()
    }
    observations.localFingerprint = client.material.fingerprint.base64URL
    let configuration = try LimLinkConfiguration.make(deviceName: "offer-server", deviceType: .iphone)
    let listener = try await LimLinkListener.start(
        configuration: configuration,
        identity: server.material,
        trust: .allowListed([client.material.fingerprint]),
        scope: .loopback,
        advertise: nil,
        timeout: .seconds(2)
    )
    defer { listener.stop() }
    let service = existingService ?? SingleFileService(
        configuration: configuration,
        maximumRetainedSessions: maximumRetainedSessions,
        onPending: { observations.record($0) },
        onPublished: { name, bytes in
            observations.record(name: name, bytes: bytes)
            onPublished(name, bytes)
        }
    )
    let serve = Task {
        let inbound = try await listener.nextConnection()
        defer { inbound.cancel() }
        await service.serve(inbound, discardSessionsOnDisconnect: discardSessionsOnDisconnect, onPending: onPendingOverride, onPublished: onPublicationOverride)
    }
    defer { serve.cancel() }
    let outbound = try await LimLinkConnection.connect(
        host: "127.0.0.1",
        port: listener.port,
        identity: client.material,
        trust: .allowListed([server.material.fingerprint]),
        scope: .loopback,
        timeout: .seconds(2)
    )
    defer { outbound.cancel() }
    try await body(service, outbound)
    outbound.cancel()
    try await serve.value
    return service
}

private enum TestSaveFailure: Error { case failed }

private func fileManifest(name: String, size: Int) -> HTTPRequest {
    WireApp.request(
        method: "POST",
        path: "/limlink/v1/sessions",
        app: "limlink",
        hostHeader: "127.0.0.1",
        body: JSONWire.data([
            "clientSessionKey": UUID().uuidString,
            "transport": "lan",
            "entries": [["id": "file-1", "kind": "file", "relativePath": name, "size": size]],
        ]),
        json: true
    )
}

private func sessionPoll(_ sessionID: String) -> HTTPRequest {
    WireApp.request(method: "GET", path: "/limlink/v1/sessions/\(sessionID)?wait=25", app: "limlink", hostHeader: "127.0.0.1", body: [], json: false)
}

private func fileUpload(_ sessionID: String, bytes: [UInt8], token: String) -> HTTPRequest {
    WireApp.request(
        method: "PUT",
        path: "/limlink/v1/sessions/\(sessionID)/files/file-1",
        app: "limlink",
        hostHeader: "127.0.0.1",
        body: bytes,
        json: false,
        extra: ["content-type": "application/octet-stream", "x-limlink-token": token, "x-limlink-offset": "0"]
    )
}

private func fileComplete(_ sessionID: String, digest: String) -> HTTPRequest {
    WireApp.request(
        method: "POST",
        path: "/limlink/v1/sessions/\(sessionID)/files/file-1/complete",
        app: "limlink",
        hostHeader: "127.0.0.1",
        body: JSONWire.data(["sha256": digest]),
        json: true
    )
}

private func offerReceiver() throws -> SingleFileReceiver {
    SingleFileReceiver(
        host: try HostAppIdentity(app: "limlink"),
        alias: "receiver",
        trustedFingerprints: ["peer"],
        sessionIDs: ["session"],
        tokens: ["test-token"]
    )
}

private func receiverResponse(_ step: ReceiverStep) throws -> HTTPResponse {
    let value: HTTPResponse?
    if case .response(let response) = step {
        value = response
    } else {
        value = nil
    }
    return try XCTUnwrap(value, "expected an HTTP response")
}
