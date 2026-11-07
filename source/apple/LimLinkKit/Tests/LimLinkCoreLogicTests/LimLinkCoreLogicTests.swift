import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class LimLinkCoreLogicTests: XCTestCase {
    func testSHA256KnownAnswers() {
        XCTAssertEqual(
            SHA256.hex(SHA256.hash([])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hex(SHA256.hash(Array("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSASVector() throws {
        let fpA = [UInt8](repeating: 0x01, count: 32)
        let fpB = [UInt8](repeating: 0x02, count: 32)
        let nonceA = [UInt8](repeating: 0x03, count: 32)
        let nonceB = [UInt8](repeating: 0x04, count: 32)
        XCTAssertEqual(
            SHA256.hex(SAS.commit(nonceA: nonceA)),
            "648aa5c579fb30f38af744d97d6ec840c7a91277a499a0d780f3e7314eca090b"
        )
        let commit = Fingerprint(spkiDER: nonceA)
        XCTAssertEqual(commit.base64URL, "ZIqlxXn7MPOK90TZfW7IQMepEnekmaDXgPPnMU7KCQs")
        XCTAssertEqual(commit.base64URL.count, 43)
        XCTAssertEqual(
            try SAS.sha256Hex(fpA: fpA, fpB: fpB, nonceA: nonceA, nonceB: nonceB),
            "50cde9ddb28a54e2ca71689387ea9c3ddf31971dcefce8f92a5d3097a5f76ec7"
        )
        XCTAssertEqual(try SAS.compute(fpA: fpA, fpB: fpB, nonceA: nonceA, nonceB: nonceB), "672029")
        XCTAssertThrowsError(try SAS.compute(fpA: [0], fpB: fpB, nonceA: nonceA, nonceB: nonceB))
    }

    func testFingerprintFormatting() throws {
        let digest = [UInt8](repeating: 0x01, count: 32)
        let fingerprint = try Fingerprint(rawSHA256: digest)
        XCTAssertEqual(fingerprint.base64URL.count, 43)
        XCTAssertFalse(fingerprint.base64URL.contains("="))
        XCTAssertEqual(fingerprint.displayGrouped.count, 19)
        XCTAssertEqual(fingerprint.displayGrouped, String(fingerprint.base64URL.prefix(16)).chunkedDisplay())
        XCTAssertFalse(fingerprint.displayGrouped.contains("."))
        XCTAssertThrowsError(try Fingerprint(rawSHA256: [0, 1, 2]))
        XCTAssertEqual(Fingerprint(base64URL: fingerprint.base64URL), fingerprint)
    }

    func testCertificateRoundTrip() throws {
        var point = [UInt8](repeating: 0x11, count: 65)
        point[0] = 0x04
        for index in 33..<65 { point[index] = 0x22 }
        let calendar = utcCalendar()
        let notBefore = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5)))
        let notAfter = try XCTUnwrap(calendar.date(from: DateComponents(year: 2034, month: 6, day: 7, hour: 8, minute: 9, second: 10)))
        let draft = try CertificateBuilder.draft(
            uncompressedPoint: point,
            serialNumber: [0x01],
            notBefore: notBefore,
            notAfter: notAfter
        )
        let der = draft.finalize(signatureDER: [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02])
        let parsed = try X509Parser.parseCertificate(der)
        XCTAssertEqual(parsed.commonNames, ["limlink"])
        XCTAssertEqual(parsed.spki, draft.spki)
        XCTAssertEqual(parsed.fingerprint, Fingerprint(spkiDER: draft.spki))
        XCTAssertEqual(parsed.fingerprint.base64URL.count, 43)
        let marker = Array("limlink".utf8)
        XCTAssertEqual(countOccurrences(of: marker, in: der), 2)
        let again = try CertificateBuilder.draft(
            uncompressedPoint: point,
            serialNumber: [0x01],
            notBefore: notBefore,
            notAfter: notAfter
        )
        XCTAssertEqual(again.finalize(signatureDER: [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]), der)
        XCTAssertThrowsError(try CertificateBuilder.subjectPublicKeyInfo(uncompressedPoint: [0x04, 0x01]))
    }

    func testTXTRoundTripAndApp() throws {
        let txt = ServiceTXT(
            fingerprint: "fp-value",
            deviceType: "iphone",
            capabilities: ["send"],
            inviting: false,
            app: "limlink"
        )
        let wire = try txt.encodeWire()
        XCTAssertLessThan(wire.count, 400)
        let fields = try TXTFields.decodeWire(wire)
        XCTAssertEqual(fields.fingerprint, "fp-value")
        XCTAssertEqual(fields.deviceType, "iphone")
        XCTAssertEqual(fields.capabilities, "send")
        XCTAssertEqual(fields.app, "limlink")
        XCTAssertEqual(fields.normalizedApp, "limlink")
        XCTAssertFalse(fields.inviting)
        XCTAssertFalse(String(bytes: wire, encoding: .utf8)!.contains("inv="))

        let inviting = ServiceTXT(fingerprint: "f", deviceType: "mac", inviting: true, app: "LimLink")
        let invitingFields = try TXTFields.decodeWire(try inviting.encodeWire())
        XCTAssertTrue(invitingFields.inviting)
        XCTAssertEqual(invitingFields.normalizedApp, "limlink")

        let missing = try TXTFields.decodeWire(Array("pv=1".utf8).lengthPrefixed())
        XCTAssertNil(missing.app)
        XCTAssertEqual(missing.normalizedApp, LimLinkProtocol.defaultApp)

        let invZero = try TXTFields.decodeWire(Array("inv=0".utf8).lengthPrefixed())
        XCTAssertFalse(invZero.inviting)

        let duplicate = [UInt8](Array("a=1".utf8).lengthPrefixed() + Array("A=2".utf8).lengthPrefixed())
        XCTAssertEqual(try TXTFields.decodeWire(duplicate).entries["a"], "2")

        let chinese = Array("note=文件".utf8).lengthPrefixed()
        XCTAssertEqual(try TXTFields.decodeWire(chinese).entries["note"], "文件")

        let tooLong = Array(("k=" + String(repeating: "x", count: 254)).utf8)
        XCTAssertThrowsError(try TXTFields(entries: ["k": String(repeating: "x", count: 254)]).encodeWire())
        XCTAssertGreaterThan(tooLong.count, 255)
        XCTAssertThrowsError(try TXTFields.decodeWire([0x02, 0x61]))
    }

    func testBonjourInstanceName() throws {
        XCTAssertEqual(try bonjourInstanceName("客厅的 iPad"), "客厅的 iPad")
        XCTAssertThrowsError(try bonjourInstanceName(""))
        let exact = String(repeating: "a", count: 63)
        XCTAssertEqual(try bonjourInstanceName(exact), exact)
        XCTAssertEqual(try bonjourInstanceName(exact + "b"), exact)
        let emojis = String(repeating: "😀", count: 16)
        XCTAssertEqual(Array(emojis.utf8).count, 64)
        let truncated = try bonjourInstanceName(emojis)
        XCTAssertEqual(truncated, String(repeating: "😀", count: 15))
        XCTAssertEqual(Array(truncated.utf8).count, 60)
    }

    func testPortPolicy() {
        XCTAssertEqual(MainPortPolicy.candidates().count, 11)
        let free = MainPortPolicy.select(occupied: [])
        XCTAssertEqual(free.choice, .specified(52470))
        XCTAssertEqual(free.diagnostic, .primary)
        let fallback = MainPortPolicy.select(occupied: [52470])
        XCTAssertEqual(fallback.choice, .specified(52471))
        XCTAssertEqual(fallback.diagnostic, .fallback(port: 52471, offset: 1))
        let occupied = Set<UInt16>(52470...52479)
        let assigned = MainPortPolicy.select(occupied: occupied)
        XCTAssertEqual(assigned.choice, .systemAssigned)
        XCTAssertEqual(assigned.diagnostic, .systemAssigned)
    }

    func testAppGate() throws {
        let host = try HostAppIdentity(app: "CaseCheck")
        XCTAssertEqual(host.app, "casecheck")
        XCTAssertEqual(host.allowedPeers, ["casecheck", "limlink"])
        XCTAssertTrue(host.allows(peerApp: "CASECHECK"))
        XCTAssertTrue(host.allows(peerApp: "limlink"))
        XCTAssertTrue(host.allows(peerApp: nil))
        XCTAssertEqual(HostAppIdentity.observe(nil), .implicitLimlink)
        XCTAssertEqual(HostAppIdentity.observe("").effectiveIdentifier, "limlink")

        guard case .allowed(let missing) = AppGate.admit(headerValue: nil, host: host) else {
            return XCTFail("missing header is limlink, which is in the group")
        }
        XCTAssertEqual(missing, "limlink")
        let mismatch = AppGate.admit(headerValue: "nope", host: host)
        guard case .mismatch(let error) = mismatch else {
            return XCTFail("expected mismatch")
        }
        XCTAssertEqual(error.code, .appMismatch)
        XCTAssertEqual(error.httpStatus, 403)
        XCTAssertFalse(error.retryable)
        XCTAssertEqual(error.detail["app"], "casecheck")
        XCTAssertNil(error.detail["reason"])

        let custom = try HostAppIdentity(app: "limlink", allowedPeers: ["limlink", "Other"])
        XCTAssertEqual(custom.allowedPeers, ["limlink"])
        XCTAssertThrowsError(try HostAppIdentity(app: "limlink", allowedPeers: [])) { thrown in
            XCTAssertEqual(thrown as? AppIdentifierError, .allowListExcludesSelf)
        }
        XCTAssertThrowsError(try HostAppIdentity(app: "limlink", allowedPeers: ["casecheck"])) { thrown in
            XCTAssertEqual(thrown as? AppIdentifierError, .allowListExcludesSelf)
        }
        XCTAssertEqual(AppGate.decide(peerApp: "other", peerAddressIsLocal: false, host: host), .appNotInInteropGroup)
        XCTAssertEqual(AppGate.headerName, "X-LimLink-App")
        XCTAssertThrowsError(try HostAppIdentity(app: ""))
        XCTAssertThrowsError(try HostAppIdentity(app: String(repeating: "a", count: 17)))
        XCTAssertThrowsError(try HostAppIdentity(app: "bad_app"))
        XCTAssertThrowsError(try HostAppIdentity(app: "unknown-app")) { thrown in
            XCTAssertEqual(thrown as? AppIdentifierError, .notInRegistry)
        }
    }

    func testDiscoveryPartition() throws {
        let host = try HostAppIdentity(app: "limlink")
        let same = DiscoveredService(instanceName: "a", fields: TXTFields(entries: ["fp": "self-peer", "app": "LimLink"]))
        let other = DiscoveredService(instanceName: "b", fields: TXTFields(entries: ["fp": "other", "app": "side"]))
        let missing = DiscoveredService(instanceName: "c", fields: TXTFields(entries: ["fp": "missing-app"]))
        let myself = DiscoveredService(instanceName: "me", fields: TXTFields(entries: ["fp": "mine", "app": "limlink"]))
        let noFingerprint = DiscoveredService(instanceName: "anon", fields: TXTFields(entries: ["app": "limlink"]))
        let partition = partitionDiscoveredServices(
            [same, other, missing, myself, noFingerprint],
            host: host,
            selfFingerprint: "mine"
        )
        XCTAssertEqual(partition.visible.map(\.instanceName), ["a", "c", "anon"])
        XCTAssertEqual(partition.diagnosticOnly.map(\.instanceName), ["b"])
        XCTAssertEqual(partition.visible[1].app, "limlink")
        XCTAssertEqual(other.app, "side")
    }

    func testTrustIgnoresApp() throws {
        let fingerprint = try Fingerprint(rawSHA256: [UInt8](repeating: 0x11, count: 32))
        let trust = ExplicitFingerprintTrust(fingerprints: [fingerprint])
        XCTAssertTrue(trust.trusts(fingerprint))
        let host = try HostAppIdentity(app: "limlink")
        XCTAssertFalse(host.allows(peerApp: "other"))
        XCTAssertEqual(decideTLSTrust(peer: fingerprint, policy: .allowListed([fingerprint])), .accept(fingerprint))
        XCTAssertEqual(decideTLSTrust(peer: nil, policy: .acceptAndReport), .reject)
        let other = try Fingerprint(rawSHA256: [UInt8](repeating: 0x22, count: 32))
        XCTAssertEqual(decideTLSTrust(peer: other, policy: .allowListed([fingerprint])), .reject)
        XCTAssertEqual(decideTLSTrust(peer: other, policy: .acceptAndReport), .accept(other))
    }

    func testTLSDecisions() {
        XCTAssertFalse(verifyBlockShouldRejectVersion(0))
        XCTAssertFalse(verifyBlockShouldRejectVersion(LimLinkProtocol.tls13WireVersion))
        XCTAssertTrue(verifyBlockShouldRejectVersion(0x0303))
        XCTAssertEqual(classifyNegotiatedTLSVersion(0x0304), .tls13)
        XCTAssertEqual(classifyNegotiatedTLSVersion(0), .unavailable)
        XCTAssertTrue(PostHandshakeCheck(versionRaw: 0x0304, earlyDataAccepted: false, alpn: nil).accept)
        XCTAssertTrue(PostHandshakeCheck(versionRaw: 0x0304, earlyDataAccepted: false, alpn: "http/1.1").accept)
        XCTAssertFalse(PostHandshakeCheck(versionRaw: 0x0304, earlyDataAccepted: true, alpn: nil).accept)
        XCTAssertFalse(PostHandshakeCheck(versionRaw: 0x0304, earlyDataAccepted: false, alpn: "h2").accept)
        XCTAssertFalse(PostHandshakeCheck(versionRaw: 0, earlyDataAccepted: false, alpn: nil).accept)
        XCTAssertFalse(PostHandshakeCheck(versionRaw: 0x0303, earlyDataAccepted: false, alpn: "http/1.1").accept)
    }

    func testProtocolErrorsAndInviteMapping() {
        let mismatch = ProtocolError.appMismatch(localApp: "limlink")
        XCTAssertEqual(mismatch.code.rawValue, "E_APP_MISMATCH")
        XCTAssertEqual(mismatch.httpStatus, 403)
        XCTAssertFalse(mismatch.retryable)
        XCTAssertEqual(ProtocolErrorCode.busy.specification.retryable, true)
        XCTAssertEqual(ProtocolErrorCode.checksumMismatch.specification.httpStatus, 422)
        XCTAssertNil(ProtocolErrorCode.portUnavailable.specification.httpStatus)
        XCTAssertTrue(ProtocolError(code: .portUnavailable, httpStatus: nil, retryable: false).isLocalOnly)

        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .codeFormat).httpStatus, nil)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .codeFormat).code, .badRequest)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .suiteUnsupported).code, .inviteSuiteUnsupported)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .expired).httpStatus, 410)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .exhausted).code, .inviteExhausted)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .busy).code, .inviteBusy)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .notActive).httpStatus, 404)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .unknownAttempt).code, .inviteFailed)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .invalidPeerMessage).code, .inviteFailed)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .confirmMismatch).code, .inviteFailed)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .tagMismatch).code, .inviteCodeWrong)
        XCTAssertEqual(InviteCoreErrorMapping.protocolError(for: .ticketMismatch).code, .inviteTicketInvalid)
        for failure in [InviteCoreFailure.badState, .rng, .nullArg, .bufferLen, .panic] {
            let mapped = InviteCoreErrorMapping.protocolError(for: failure)
            XCTAssertEqual(mapped.code, .internal)
            XCTAssertEqual(mapped.httpStatus, 500)
            XCTAssertEqual(mapped.detail["core"], failure.rawValue)
        }
    }

    func testPairingCoreIsUnavailable() async {
        do {
            _ = try await UnavailablePairingCore().coreInfo()
            XCTFail("expected PairingCoreUnavailable")
        } catch is PairingCoreUnavailable {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}

private func countOccurrences(of needle: [UInt8], in haystack: [UInt8]) -> Int {
    guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
    var count = 0
    for index in 0...(haystack.count - needle.count) where Array(haystack[index..<(index + needle.count)]) == needle {
        count += 1
    }
    return count
}

private extension String {
    func chunkedDisplay() -> String {
        var groups: [String] = []
        var rest = Substring(self)
        while !rest.isEmpty {
            let take = rest.prefix(4)
            groups.append(String(take))
            rest = rest.dropFirst(take.count)
        }
        return groups.joined(separator: "-")
    }
}

private extension Array where Element == UInt8 {
    func lengthPrefixed() -> [UInt8] {
        [UInt8(count)] + self
    }
}
