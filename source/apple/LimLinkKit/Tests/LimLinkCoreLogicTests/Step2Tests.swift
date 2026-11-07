import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class Step2Tests: XCTestCase {
    func testAllowListThenSameDeviceAndOutOfGroupOnLocalAddress() throws {
        let host = try HostAppIdentity(app: "limlink")
        XCTAssertEqual(
            AppGate.decide(peerApp: "casecheck", peerAddressIsLocal: true, host: host),
            .sameDeviceOtherApp
        )
        let sameDevice = AppGate.wireError(for: .sameDeviceOtherApp, host: host)
        XCTAssertEqual(sameDevice?.detail["reason"], "same_device")
        XCTAssertEqual(sameDevice?.detail["app"], "limlink")

        XCTAssertEqual(
            AppGate.decide(peerApp: "casecheck", peerAddressIsLocal: false, host: host),
            .proceed(app: "casecheck")
        )
        XCTAssertEqual(
            AppGate.decide(peerApp: "limlink", peerAddressIsLocal: true, host: host),
            .proceed(app: "limlink")
        )

        XCTAssertEqual(
            AppGate.decide(peerApp: "other", peerAddressIsLocal: true, host: host),
            .appNotInInteropGroup
        )
        let plain = AppGate.admit(headerValue: "other", host: host, peerAddressIsLocal: true)
        guard case .mismatch(let error) = plain else { return XCTFail("expected mismatch") }
        XCTAssertEqual(error.code, .appMismatch)
        XCTAssertNil(error.detail["reason"])
        XCTAssertEqual(TransferHostErrorMapping.classify(error), .appNotInInteropGroup)
        XCTAssertEqual(
            TransferHostErrorMapping.classify(ProtocolError.appMismatchSameDevice(localApp: "limlink")),
            .sameDeviceOtherApp
        )
        XCTAssertEqual(
            TransferHostErrorMapping.classify(ProtocolError(code: .inviteTicketInvalid, httpStatus: 403, retryable: false)),
            .inviteTicketInvalid
        )

        let other = DiscoveredService(
            instanceName: "外来",
            fields: TXTFields(entries: ["fp": "fp-other", "app": "other"]),
            addresses: ["127.0.0.1"]
        )
        let peer = DiscoveredService(
            instanceName: "本机 CaseCheck",
            fields: TXTFields(entries: ["fp": "fp-cc", "app": "casecheck"]),
            addresses: ["127.0.0.1"]
        )
        let partition = partitionDiscoveredServices([other, peer], host: host, selfFingerprint: nil, localAddresses: [])
        XCTAssertEqual(partition.diagnosticOnly.map(\.instanceName), ["外来"])
        XCTAssertTrue(partition.visible.isEmpty)
        XCTAssertFalse(partition.helloTargets.contains { $0.instanceName == "本机 CaseCheck" })
        XCTAssertFalse(partition.diagnosticOnly.contains { $0.instanceName == "本机 CaseCheck" })
    }

    func testTxtPrefilterIsOneWayAndManualPathStillHellos() throws {
        let host = try HostAppIdentity(app: "limlink")
        let blocked = TxtPrefilter.decide(
            peerApp: "other",
            addresses: ["10.0.0.8"],
            localAddresses: [],
            host: host,
            path: .browse
        )
        XCTAssertEqual(blocked.placement, .diagnosticOnly)
        XCTAssertFalse(blocked.sendHello)

        let manual = TxtPrefilter.decide(
            peerApp: "other",
            addresses: ["10.0.0.8"],
            localAddresses: [],
            host: host,
            path: .manual
        )
        XCTAssertTrue(manual.sendHello)

        let listed = DiscoveredService(instanceName: "甲", fields: TXTFields(entries: ["fp": "1", "app": "limlink"]))
        let foreign = DiscoveredService(instanceName: "乙", fields: TXTFields(entries: ["fp": "2", "app": "side"]))
        let first = partitionDiscoveredServices([listed, foreign], host: host, selfFingerprint: nil)
        XCTAssertEqual(first.helloTargets.map(\.instanceName), ["甲"])
        XCTAssertEqual(first.diagnosticOnly.map(\.instanceName), ["乙"])

        let changed = DiscoveredService(instanceName: "甲", fields: TXTFields(entries: ["fp": "1", "app": "side"]))
        let second = partitionDiscoveredServices([changed, foreign], host: host, selfFingerprint: nil)
        XCTAssertTrue(second.helloTargets.isEmpty)
        XCTAssertEqual(Set(second.diagnosticOnly.map(\.instanceName)), ["甲", "乙"])
    }

    func testBackgroundDropIsSilentAndTapReturnsTypedError() throws {
        let host = try HostAppIdentity(app: "limlink")
        let clock = try XCTUnwrap(DiagnosticClock(rfc3339: "2026-10-08T04:00:00Z"))
        let background = TlsRecheckEngine.evaluate(
            deviceName: "客厅的 iPad",
            ip: "10.0.0.8",
            txtAppRaw: "limlink",
            txtAppPresent: true,
            tlsAppRaw: "other",
            tlsAppPresent: true,
            peerAddressIsLocal: true,
            intent: .backgroundRefresh,
            timestamp: DiagnosticTimestamps.format(clock.now),
            host: host
        )
        XCTAssertNil(background.hostError)
        XCTAssertEqual(background.listPlacement, .diagnosticOnly)
        XCTAssertEqual(background.logEntry?.deviceName, "客厅的 iPad")
        XCTAssertEqual(background.logEntry?.ip, "10.0.0.8")
        XCTAssertEqual(background.logEntry?.txtApp, "limlink")
        XCTAssertEqual(background.logEntry?.tlsApp, "other")

        let tapped = TlsRecheckEngine.evaluate(
            deviceName: "客厅的 iPad",
            ip: "127.0.0.1",
            txtAppRaw: "limlink",
            txtAppPresent: true,
            tlsAppRaw: "casecheck",
            tlsAppPresent: true,
            peerAddressIsLocal: true,
            intent: .userTap,
            timestamp: "2026-10-08T04:00:00Z",
            host: host
        )
        XCTAssertEqual(tapped.hostError, .sameDeviceOtherApp)
        XCTAssertEqual(tapped.listPlacement, .hidden)

        let groupMate = TlsRecheckEngine.evaluate(
            deviceName: "周的 MacBook",
            ip: "10.0.0.9",
            txtAppRaw: "limlink",
            txtAppPresent: true,
            tlsAppRaw: "casecheck",
            tlsAppPresent: true,
            peerAddressIsLocal: false,
            intent: .backgroundRefresh,
            timestamp: "2026-10-08T04:00:00Z",
            host: host
        )
        XCTAssertEqual(groupMate.disposition, .proceed(app: "casecheck"))
        XCTAssertNil(groupMate.hostError)
        XCTAssertEqual(groupMate.logEntry?.txtApp, "limlink")
        XCTAssertEqual(groupMate.logEntry?.tlsApp, "casecheck")
        let fields = PeerFields(app: "casecheck", alias: "周的 MacBook")
        XCTAssertEqual(fields.app, "casecheck")
        XCTAssertEqual(fields.alias, "周的 MacBook")
        XCTAssertFalse(String(describing: fields).contains("CaseCheck周"))
    }

    func testOutboundAppIsAlwaysPresentAndMissingMeansLimlink() throws {
        let hello = WireApp.helloRequest(app: "casecheck", alias: "昵称", devType: "iphone", port: 52470, hostHeader: "10.0.0.2")
        XCTAssertEqual(hello.value(for: "X-LimLink-App"), "casecheck")
        let helloBody = try XCTUnwrap(JSONWire.object(hello.body))
        XCTAssertEqual(JSONWire.string(helloBody, "app"), "casecheck")

        let response = WireApp.helloResponse(app: "casecheck", alias: "昵称", devType: "iphone", port: 52470, trusted: false, busy: false)
        let responseBody = try XCTUnwrap(JSONWire.object(response.body))
        XCTAssertEqual(JSONWire.string(responseBody, "app"), "casecheck")

        let invite = WireApp.inviteHelloResponse(
            app: "limlink",
            inviteSessionId: "s",
            nonceS: "n",
            alias: "甲",
            inviteAgeSec: 3,
            suite: "CPACE-RISTR255-SHA512"
        )
        let inviteBody = try XCTUnwrap(JSONWire.object(invite.body))
        XCTAssertEqual(JSONWire.string(inviteBody, "app"), "limlink")
        let decoded = try XCTUnwrap(WireApp.decodeInviteHello(invite.body))
        XCTAssertTrue(decoded.appPresent)

        let absent = try XCTUnwrap(WireApp.decodeInviteHello(Array(#"{"inviteSessionId":"s","alias":"甲"}"#.utf8)))
        XCTAssertFalse(absent.appPresent)
        XCTAssertEqual(HostAppIdentity.observe(absent.appPresent ? absent.app : nil).effectiveIdentifier, "limlink")

        let announce = WireApp.multicastAnnounce(
            app: "limlink",
            fingerprint: "fp",
            alias: "甲",
            devType: "iphone",
            port: 52470,
            nonce: "n"
        )
        let announceBody = try XCTUnwrap(JSONWire.object(announce))
        XCTAssertEqual(JSONWire.string(announceBody, "app"), "limlink")

        let stealth = try TXTFields.decodeWire(try StealthInviteTXT.encode(app: "limlink"))
        XCTAssertEqual(stealth.app, "limlink")
        XCTAssertTrue(stealth.inviting)
        XCTAssertNil(stealth.fingerprint)

        let host = try HostAppIdentity(app: "limlink")
        let draft = InviteCandidateDraft(id: "1", alias: "乙", txtAppRaw: "other", txtAppPresent: true)
        XCTAssertFalse(InviteCandidateBoard.shouldSendInviteHello(draft, host: host, localAddresses: []))
        let allowed = InviteCandidateDraft(id: "2", alias: "甲", txtAppRaw: "limlink", txtAppPresent: true)
        XCTAssertTrue(InviteCandidateBoard.shouldSendInviteHello(allowed, host: host, localAddresses: []))
        let final = InviteCandidateBoard.applyInviteHello(
            allowed,
            response: InviteHelloBody(inviteSessionId: "s", alias: "甲", app: "casecheck", appPresent: true),
            host: host,
            localAddresses: [],
            intent: .userTap,
            timestamp: "2026-10-08T04:00:00Z",
            ip: "10.0.0.4"
        )
        XCTAssertEqual(final.disposition, .proceed(app: "casecheck"))
        XCTAssertEqual(final.logEntry?.tlsApp, "casecheck")
    }

    func testDiagnosticsLogExpiryCapAndClear() async throws {
        let early = try XCTUnwrap(DiagnosticClock(rfc3339: "2026-09-08T00:00:00Z"))
        let justInside = try XCTUnwrap(DiagnosticClock(rfc3339: "2026-10-07T23:59:59Z"))
        let due = try XCTUnwrap(DiagnosticClock(rfc3339: "2026-10-08T00:00:00Z"))
        var log = LocalDiagnosticLog()
        log.record(entry("old", "2026-09-08T00:00:00Z"), clock: early)
        log.record(entry("fresh", "2026-10-07T00:00:00Z"), clock: justInside)
        XCTAssertEqual(log.entries(clock: justInside).map(\.deviceName), ["old", "fresh"])
        XCTAssertEqual(log.entries(clock: due).map(\.deviceName), ["fresh"])

        var capped = LocalDiagnosticLog()
        let now = try XCTUnwrap(DiagnosticClock(rfc3339: "2026-10-08T04:00:00Z"))
        for index in 0..<101 {
            capped.record(entry("n\(index)", "2026-10-08T04:00:00Z"), clock: now)
        }
        let names = capped.entries(clock: now).map(\.deviceName)
        XCTAssertEqual(names.count, 100)
        XCTAssertEqual(names.first, "n1")
        XCTAssertEqual(names.last, "n100")
        LimLink.clearDiagnosticsLog(&capped)
        XCTAssertTrue(capped.entries(clock: now).isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try DiagnosticLogFile(directory: directory)
        try store.record(entry("disk-old", "2026-09-01T00:00:00Z"), clock: early)
        try store.record(entry("disk-new", "2026-10-08T00:00:00Z"), clock: due)
        let loaded = try store.load(clock: due)
        XCTAssertEqual(loaded.entries.map(\.deviceName), ["disk-new"])
        let raw = try Data(contentsOf: store.fileURL)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("http"))
        try await LimLink.clearDiagnosticsLog(at: directory)
        XCTAssertTrue(try store.load(clock: due).entries.isEmpty)
    }

    func testTxtChangedRefiltersFilteredPeersAndDoesNotConnect() throws {
        let host = try HostAppIdentity(app: "limlink")
        let visible = DiscoveredService(instanceName: "甲", fields: TXTFields(entries: ["fp": "fp-a", "app": "limlink"]))
        let parked = DiscoveredService(instanceName: "乙", fields: TXTFields(entries: ["fp": "fp-b", "app": "side"]))
        var roster = TxtBrowseRoster(services: [visible, parked])
        let broughtBack = DiscoveredService(instanceName: "乙", fields: TXTFields(entries: ["fp": "fp-b", "app": "casecheck"]))
        let back = roster.applyChanges(
            [.changed(old: parked, new: broughtBack)],
            host: host,
            selfFingerprint: nil
        )
        XCTAssertFalse(back.connects)
        XCTAssertEqual(Set(back.partition.visible.map(\.instanceName)), ["甲", "乙"])

        let dropped = DiscoveredService(instanceName: "甲", fields: TXTFields(entries: ["fp": "fp-a", "app": "other"]))
        let again = roster.applyChanges(
            [.changed(old: visible, new: dropped)],
            host: host,
            selfFingerprint: nil
        )
        XCTAssertFalse(again.connects)
        XCTAssertEqual(again.partition.helloTargets.map(\.instanceName), ["乙"])
        XCTAssertEqual(again.partition.diagnosticOnly.map(\.instanceName), ["甲"])
        XCTAssertFalse(again.connects)
    }

    func testHttpSha256AndHalfFile() throws {
        let payload = Array("abc".utf8)
        let digest = FileDigest.sha256Hex(payload)
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try FileDigest.parse(digest.uppercased()).get(), digest)
        XCTAssertEqual(FileDigest.parse("abc").getFailure()?.code, .badRequest)
        XCTAssertEqual(FileDigest.sha256Hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let request = WireApp.request(
            method: "PUT",
            path: "/limlink/v1/sessions/sid/files/fid",
            app: "limlink",
            hostHeader: "127.0.0.1",
            body: payload,
            json: false,
            extra: [
                "content-type": "application/octet-stream",
                "x-limlink-token": "tok",
                "x-limlink-offset": "0",
            ]
        )
        let encoded = HTTPCodec.encode(request)
        let (parsed, consumed) = try HTTPCodec.parseRequest(encoded)
        XCTAssertEqual(consumed, encoded.count)
        XCTAssertEqual(parsed.method, "PUT")
        XCTAssertEqual(parsed.value(for: "x-limlink-app"), "limlink")
        XCTAssertEqual(parsed.body, payload)

        let host = try HostAppIdentity(app: "limlink")
        var receiver = SingleFileReceiver(
            host: host,
            alias: "甲",
            trustedFingerprints: ["fp-client"],
            sessionIDs: ["sid"],
            tokens: ["tok"]
        )
        let created = receiver.handle(manifest(name: "CON.txt", bytes: payload), peerAddressIsLocal: false, clientFingerprint: "fp-client")
        guard case .response(let createdResponse) = created else { return XCTFail("create") }
        XCTAssertEqual(createdResponse.status, 202)
        receiver.decide(sessionID: "sid", accept: true)
        guard case .response(let accepted) = receiver.handle(
            HTTPRequest(method: "GET", target: "/limlink/v1/sessions/sid?wait=25", headers: ["x-limlink-app": "limlink"], body: []),
            peerAddressIsLocal: false,
            clientFingerprint: "fp-client"
        ) else { return XCTFail("poll") }
        XCTAssertEqual(accepted.status, 200)

        let put = receiver.handle(request, peerAddressIsLocal: false, clientFingerprint: "fp-client")
        guard case .response(let putResponse) = put else { return XCTFail("put") }
        XCTAssertEqual(putResponse.status, 200)
        XCTAssertNil(receiver.sessions["sid"]?.published)

        let bad = receiver.handle(completeBody("0000000000000000000000000000000000000000000000000000000000000000"), peerAddressIsLocal: false, clientFingerprint: "fp-client")
        guard case .response(let badResponse) = bad else { return XCTFail("bad hash") }
        XCTAssertEqual(badResponse.status, 422)
        XCTAssertNil(receiver.sessions["sid"]?.published)
        XCTAssertEqual(receiver.sessions["sid"]?.committed.count, 0)

        let retry = receiver.handle(request, peerAddressIsLocal: false, clientFingerprint: "fp-client")
        guard case .response(let retryResponse) = retry else { return XCTFail("retry") }
        XCTAssertEqual(retryResponse.status, 200)
        let good = receiver.handle(completeBody(digest), peerAddressIsLocal: false, clientFingerprint: "fp-client")
        guard case .response(let goodResponse) = good else { return XCTFail("good hash") }
        XCTAssertEqual(goodResponse.status, 200)
        XCTAssertEqual(receiver.sessions["sid"]?.published, payload)
        XCTAssertEqual(receiver.sessions["sid"]?.finalName, "CON_.txt")
        XCTAssertEqual(HalfFilePaths.partFileName("CON_.txt"), "CON_.txt.limlink-part")

        let localOther = receiver.handle(
            HTTPRequest(method: "POST", target: "/limlink/v1/sessions", headers: ["x-limlink-app": "casecheck"], body: []),
            peerAddressIsLocal: true,
            clientFingerprint: "fp-client"
        )
        guard case .response(let localResponse) = localOther else { return XCTFail("same device") }
        let localError = try XCTUnwrap(WireApp.decodeError(localResponse.body))
        XCTAssertEqual(localError.detail["reason"], "same_device")
    }

    func testSingleFileClientRoundTripAndChecksumRetry() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = SingleFileReceiver(
            host: host,
            alias: "乙",
            devType: "iphone",
            trustedFingerprints: ["fp-client"],
            sessionIDs: ["sid"],
            tokens: ["tok"]
        )
        var client = SingleFileClient(
            local: host,
            localAlias: "甲",
            peerHost: "10.0.0.8",
            txtAppRaw: "limlink",
            txtAppPresent: true,
            deviceName: "乙",
            intent: .userTap,
            timestamp: "2026-10-08T04:00:00Z",
            fileID: "fid",
            relativePath: "note.txt",
            bytes: Array("abc".utf8),
            clientSessionKey: "key-1"
        )
        var tick = client.start()
        while let request = tick.request {
            let step = receiver.handle(request, peerAddressIsLocal: false, clientFingerprint: "fp-client")
            let response: HTTPResponse
            switch step {
            case .response(let value):
                response = value
            case .awaitDecision(let sid):
                receiver.decide(sessionID: sid, accept: true)
                response = receiver.pollResponse(sessionID: sid)
            }
            tick = client.receive(response)
        }
        XCTAssertEqual(tick.status, .completed(finalName: "note.txt"))
        XCTAssertEqual(receiver.sessions["sid"]?.published, Array("abc".utf8))

        var retry = client
        var again = retry.start()
        again = retry.receive(WireApp.helloResponse(app: "limlink", alias: "乙", devType: "iphone", port: 52470, trusted: true, busy: false))
        again = retry.receive(HTTPResponse(status: 202, body: JSONWire.data(["sessionId": "sid", "state": "pending"])))
        again = retry.receive(HTTPResponse(status: 200, body: JSONWire.data([
            "state": "accepted",
            "files": ["fid": ["token": "tok", "offset": 0, "finalName": "note.txt"]],
        ])))
        again = retry.receive(HTTPResponse(status: 200, body: JSONWire.data(["committedBytes": 3])))
        let mismatch = WireApp.errorResponse(ProtocolError(code: .checksumMismatch, httpStatus: 422, retryable: true))
        again = retry.receive(mismatch)
        XCTAssertEqual(again.request?.method, "PUT")
        XCTAssertEqual(again.request?.value(for: "x-limlink-offset"), "0")
        again = retry.receive(HTTPResponse(status: 200, body: JSONWire.data(["committedBytes": 3])))
        again = retry.receive(HTTPResponse(status: 200, body: JSONWire.data(["verified": true, "finalName": "note.txt"])))
        let finish = receiver.handle(try XCTUnwrap(again.request), peerAddressIsLocal: false, clientFingerprint: "fp-client")
        guard case .response(let finalReport) = finish else {
            return XCTFail("The completed receiver must provide its final report")
        }
        again = retry.receive(finalReport)
        XCTAssertEqual(again.status, .completed(finalName: "note.txt"))
        XCTAssertNil(again.request)
    }

    func testFileNameCollisionAndExecutableWarning() {
        XCTAssertEqual(FileNameSafety.uniqueName("01.pdf", existing: ["01.pdf", "01 (1).pdf"]), "01 (2).pdf")
        XCTAssertEqual(FileNameSafety.uniqueName("A.PDF", existing: ["a.pdf"]), "A (1).PDF")
        XCTAssertTrue(FileNameSafety.warnsExecutable("Report.EXE"))
        XCTAssertTrue(FileNameSafety.warnsExecutable("run.sh"))
        XCTAssertFalse(FileNameSafety.warnsExecutable("archive.tar.gz"))
        XCTAssertFalse(FileNameSafety.warnsExecutable("notes.txt"))
    }

    func testSessionStaysPendingUntilTheHostDecides() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = SingleFileReceiver(
            host: host,
            alias: "甲",
            trustedFingerprints: ["fp-client"],
            sessionIDs: ["sid"],
            tokens: ["tok"]
        )
        let created = receiver.handle(manifest(name: "note.txt", bytes: Array("abc".utf8)), peerAddressIsLocal: false, clientFingerprint: "fp-client")
        guard case .response(let createdResponse) = created else { return XCTFail("create") }
        XCTAssertEqual(createdResponse.status, 202)
        let poll = HTTPRequest(method: "GET", target: "/limlink/v1/sessions/sid?wait=25", headers: ["x-limlink-app": "limlink"], body: [])
        guard case .awaitDecision = receiver.handle(poll, peerAddressIsLocal: false, clientFingerprint: "fp-client") else {
            return XCTFail("first poll")
        }
        guard case .awaitDecision = receiver.handle(poll, peerAddressIsLocal: false, clientFingerprint: "fp-client") else {
            return XCTFail("second poll")
        }
        receiver.decide(sessionID: "sid", accept: true)
        guard case .response(let accepted) = receiver.handle(poll, peerAddressIsLocal: false, clientFingerprint: "fp-client") else {
            return XCTFail("accepted")
        }
        XCTAssertEqual(accepted.status, 200)
    }

    func testInviteTicketOnManifestIsRejectedUntilVerificationExists() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = SingleFileReceiver(
            host: host,
            alias: "甲",
            trustedFingerprints: ["fp-client"],
            sessionIDs: ["sid"],
            tokens: ["tok"],
            now: "2026-10-08T04:00:00Z"
        )
        let first = receiver.handle(ticketManifest("ticket-a"), peerAddressIsLocal: false, clientFingerprint: "fp-client")
        let second = receiver.handle(ticketManifest("ticket-b"), peerAddressIsLocal: false, clientFingerprint: "fp-client")
        for step in [first, second] {
            guard case .response(let response) = step else { return XCTFail("ticket") }
            XCTAssertEqual(response.status, 403)
            let error = try XCTUnwrap(WireApp.decodeError(response.body))
            XCTAssertEqual(error.code, .inviteTicketInvalid)
            XCTAssertNotEqual(error.code, .notImplemented)
        }
        XCTAssertTrue(receiver.sessions.isEmpty)
        XCTAssertEqual(receiver.diagnostics.map(\.message), [
            DiagnosticNote.ticketVerificationUnimplemented,
            DiagnosticNote.ticketVerificationUnimplemented,
        ])
        XCTAssertEqual(receiver.diagnostics.map(\.timestamp), ["2026-10-08T04:00:00Z", "2026-10-08T04:00:00Z"])
    }

    func testIdentityChangeRequiresNameAndApp() throws {
        let trusted = [TrustedPeerIdentity(fingerprint: "fp-old", name: "客厅", app: "limlink")]
        XCTAssertEqual(
            IdentityChangeCheck.evaluate(observedName: "客厅", observedApp: "limlink", observedFingerprint: "fp-new", trusted: trusted),
            .changed(trustedFingerprint: "fp-old")
        )
        XCTAssertEqual(
            IdentityChangeCheck.evaluate(observedName: "客厅", observedApp: "casecheck", observedFingerprint: "fp-new", trusted: trusted),
            .notThisCase
        )
    }

    private func entry(_ name: String, _ timestamp: String) -> AppMismatchLogEntry {
        AppMismatchLogEntry(deviceName: name, ip: "10.0.0.1", txtApp: "limlink", tlsApp: "casecheck", timestamp: timestamp)
    }

    private func manifest(name: String, bytes: [UInt8]) -> HTTPRequest {
        let body = JSONWire.data([
            "clientSessionKey": "key-1",
            "transport": "lan",
            "totalEntries": 1,
            "totalBytes": bytes.count,
            "entries": [[
                "id": "fid",
                "kind": "file",
                "relativePath": name,
                "size": bytes.count,
            ]],
        ])
        return WireApp.request(method: "POST", path: "/limlink/v1/sessions", app: "limlink", hostHeader: "127.0.0.1", body: body, json: true)
    }

    private func ticketManifest(_ ticket: String) -> HTTPRequest {
        let body = JSONWire.data([
            "clientSessionKey": "key-ticket",
            "transport": "lan",
            "inviteTicket": ticket,
            "totalEntries": 1,
            "totalBytes": 3,
            "entries": [[
                "id": "fid",
                "kind": "file",
                "relativePath": "note.txt",
                "size": 3,
            ]],
        ])
        return WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions",
            app: "limlink",
            hostHeader: "127.0.0.1",
            body: body,
            json: true
        )
    }

    private func completeBody(_ sha: String) -> HTTPRequest {
        WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions/sid/files/fid/complete",
            app: "limlink",
            hostHeader: "127.0.0.1",
            body: JSONWire.data(["sha256": sha]),
            json: true
        )
    }
}

private extension Result where Failure == ProtocolError {
    func getFailure() -> ProtocolError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
