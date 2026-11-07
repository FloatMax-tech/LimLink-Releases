import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class Step25Tests: XCTestCase {
    func testPauseThenResumeFromOffset() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = makeReceiver(host)
        try accept(&receiver, bytes: Array("abc".utf8), size: 3)
        receiver.incomingBodyCutOff(
            sessionID: "sid",
            fileID: "fid",
            flushed: Array("a".utf8),
            tail: Array("!".utf8)
        )
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("a".utf8))

        var client = makeClient(host, bytes: Array("abc".utf8))
        var tick = client.start()
        tick = try driveUntilPut(&client, &receiver, tick, offset: "1")
        XCTAssertEqual(tick.request?.body, Array("bc".utf8))

        tick = client.pause(reason: "user", detail: ["note": "hold"])
        let pauseBody = try XCTUnwrap(JSONWire.object(tick.request?.body ?? []))
        XCTAssertEqual(JSONWire.string(pauseBody, "reason"), "user")
        XCTAssertNil(pauseBody["systemReason"])
        let sentDetail = try XCTUnwrap(pauseBody["detail"] as? [String: Any])
        XCTAssertEqual(sentDetail["note"] as? String, "hold")
        tick = try step(&client, &receiver, tick)
        guard case .paused(let committed) = tick.status else {
            return XCTFail("paused status \(tick.status)")
        }
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .paused)
        XCTAssertEqual(receiver.sessions["sid"]?.holds.first?.detail, ["note": "hold"])
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("a".utf8))

        let blocked = try respond(&receiver, put(offset: 1, body: Array("bc".utf8)))
        XCTAssertEqual(blocked.status, 409)
        XCTAssertEqual(try XCTUnwrap(WireApp.decodeError(blocked.body)).code, .sessionPaused)

        tick = client.resume()
        tick = try step(&client, &receiver, tick)
        XCTAssertEqual(tick.request?.method, "PUT")
        XCTAssertEqual(tick.request?.value(for: "x-limlink-offset"), "1")
        XCTAssertEqual(tick.request?.body, Array("bc".utf8))
        while tick.request != nil {
            tick = try step(&client, &receiver, tick)
        }
        XCTAssertEqual(tick.status, .completed(finalName: "note.txt"))
        XCTAssertEqual(receiver.sessions["sid"]?.published, Array("abc".utf8))
    }

    func testPauseDetailRoundTripAndSleepDetail() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = makeReceiver(host)
        try accept(&receiver, bytes: Array("ab".utf8), size: 2)
        let response = try respond(&receiver, control("pause", reason: "system", detail: [
            "systemReason": "sleep",
            "note": "lid",
        ]))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(detail(in: response.body), ["systemReason": "sleep", "note": "lid"])
        XCTAssertEqual(receiver.sessions["sid"]?.holds.first?.detail?["systemReason"], "sleep")

        let skipped = try respond(&receiver, skip(detail: ["code": "user"]))
        XCTAssertEqual(skipped.status, 200)
        XCTAssertEqual(detail(in: skipped.body)?["code"], "user")
    }

    func testBackgroundThenForegroundEventSequence() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = makeReceiver(host)
        try accept(&receiver, bytes: Array("ab".utf8), size: 3)
        receiver.incomingBodyCutOff(sessionID: "sid", fileID: "fid", flushed: Array("ab".utf8), tail: [0])

        var ios = TransferLifecycle(platform: .iOS)
        var backgroundTask = BackgroundTaskSession()
        XCTAssertEqual(ios.handle(.transferStarted), LifecycleDirective())
        XCTAssertEqual(ios.handle(.willSleep), LifecycleDirective())
        let background = ios.handle(.didEnterBackground)
        XCTAssertEqual(background.pauseReason, "app_background")
        XCTAssertNil(background.detail)
        XCTAssertNil(background.pauseToSend?.detail)
        XCTAssertEqual(background.backgroundTask, .begin)
        backgroundTask.apply(background.backgroundTask)
        XCTAssertTrue(backgroundTask.isOpen)
        backgroundTask.apply(.none)
        XCTAssertTrue(backgroundTask.isOpen)
        receiver.apply(background)
        XCTAssertEqual(receiver.sessions["sid"]?.holds.first?.reason, "app_background")
        XCTAssertNil(receiver.sessions["sid"]?.holds.first?.detail)

        let foreground = ios.handle(.willEnterForeground)
        XCTAssertEqual(foreground.resumeLocalHold, true)
        XCTAssertEqual(foreground.backgroundTask, .end)
        backgroundTask.apply(foreground.backgroundTask)
        XCTAssertFalse(backgroundTask.isOpen)
        receiver.apply(foreground)
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .accepted)
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("ab".utf8))

        var mac = TransferLifecycle(platform: .macOS)
        XCTAssertEqual(mac.handle(.didEnterBackground), LifecycleDirective())
        XCTAssertEqual(mac.handle(.transferStarted).activity, .begin)
        let sleep = mac.handle(.willSleep)
        XCTAssertEqual(sleep.detail, ["systemReason": "sleep"])
        XCTAssertEqual(sleep.activity, .end)
        receiver.apply(sleep)
        XCTAssertEqual(receiver.sessions["sid"]?.holds.first?.detail, ["systemReason": "sleep"])
        let wake = mac.handle(.didWake)
        XCTAssertTrue(wake.afterWake)
        XCTAssertTrue(wake.resumeLocalHold)
        XCTAssertEqual(wake.activity, .begin)
        XCTAssertEqual(WakeResume.plan(afterWake: true, transportFailedBeforeResponse: true), .waitForPathThenSend)
        XCTAssertEqual(WakeResume.plan(afterWake: false, transportFailedBeforeResponse: true), .fail)
        XCTAssertEqual(WakeResume.plan(afterWake: true, transportFailedBeforeResponse: false), .send)
        receiver.apply(wake)
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .accepted)
    }

    func testBackgroundKilledDoesNotSendPause() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = makeReceiver(host)
        try accept(&receiver, bytes: [], size: 3)
        receiver.incomingBodyCutOff(sessionID: "sid", fileID: "fid", flushed: Array("ab".utf8), tail: [9])
        var killed = TransferLifecycle(platform: .iOS)
        _ = killed.handle(.transferStarted)
        let hardStop = killed.handle(.backgroundTimeExpired)
        XCTAssertNil(hardStop.pauseReason)
        XCTAssertNil(hardStop.pauseToSend)
        XCTAssertTrue(hardStop.flushHalfFile)
        XCTAssertEqual(hardStop.backgroundTask, .end)
        receiver.apply(hardStop)
        XCTAssertTrue(receiver.sessions["sid"]?.holds.isEmpty == true)
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("ab".utf8))
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .accepted)
    }

    func testExpiryBeforeResumeLeavesAValidHalfFile() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = makeReceiver(host)
        try accept(&receiver, bytes: Array("ab".utf8), size: 3)
        receiver.incomingBodyCutOff(sessionID: "sid", fileID: "fid", flushed: Array("ab".utf8), tail: [1])
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("ab".utf8))

        var ios = TransferLifecycle(platform: .iOS)
        _ = ios.handle(.transferStarted)
        receiver.apply(ios.handle(.didEnterBackground))
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .paused)

        let pausedAt = receiver.clock
        receiver.advanceClock(to: pausedAt.addingTimeInterval(SingleFileReceiver.pauseRetention - 1))
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .paused)
        receiver.advanceClock(to: pausedAt.addingTimeInterval(SingleFileReceiver.pauseRetention))
        XCTAssertEqual(receiver.sessions["sid"]?.phase, .expired)
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("ab".utf8))

        let resume = try respond(&receiver, control("resume", reason: nil, detail: nil))
        XCTAssertEqual(resume.status, 410)
        XCTAssertEqual(try XCTUnwrap(WireApp.decodeError(resume.body)).code, .sessionExpired)
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("ab".utf8))
    }

    func testShortPutCommitsChunkAndTruncationKeepsOnlyFlushedBytes() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = makeReceiver(host)
        try accept(&receiver, bytes: [], size: 3)
        let short = try respond(&receiver, put(offset: 0, body: Array("a".utf8)))
        XCTAssertEqual(short.status, 200)
        XCTAssertEqual(JSONWire.object(short.body)?["committedBytes"] as? Int, 1)
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("a".utf8))

        receiver.incomingBodyCutOff(sessionID: "sid", fileID: "fid", flushed: Array("b".utf8), tail: Array("ZZ".utf8))
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, Array("ab".utf8))
        XCTAssertEqual(receiver.sessions["sid"]?.committed, Array("ab".utf8))
    }

    func testFinishFilesAreAnArrayAndDurationSkipsPause() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = makeReceiver(host)
        try accept(&receiver, bytes: Array("abc".utf8), size: 3)
        let started = receiver.clock
        _ = try respond(&receiver, put(offset: 0, body: Array("abc".utf8)))
        receiver.advanceClock(to: started.addingTimeInterval(10))
        _ = try respond(&receiver, control("pause", reason: "user", detail: nil))
        receiver.advanceClock(to: started.addingTimeInterval(40))
        _ = try respond(&receiver, control("resume", reason: nil, detail: nil))
        receiver.advanceClock(to: started.addingTimeInterval(45))
        let digest = FileDigest.sha256Hex(Array("abc".utf8))
        _ = try respond(&receiver, completeBody(digest))
        let finished = try respond(&receiver, HTTPRequest(
            method: "POST",
            target: "/limlink/v1/sessions/sid/finish",
            headers: ["x-limlink-app": "limlink"],
            body: []
        ))
        let body = try XCTUnwrap(JSONWire.object(finished.body))
        XCTAssertEqual(JSONWire.int(body, "durationMs"), 15000)
        let files = try XCTUnwrap(body["files"] as? [Any])
        XCTAssertEqual(files.count, 1)
        let first = try XCTUnwrap(files.first as? [String: Any])
        XCTAssertEqual(first["id"] as? String, "fid")
    }

    func testShaMismatchAfterResumeRetriesOnceFromZero() throws {
        let host = try HostAppIdentity(app: "limlink")
        var receiver = makeReceiver(host)
        let payload = Array("abc".utf8)
        var client = makeClient(host, bytes: payload)
        var tick = client.start()
        tick = try driveUntilPut(&client, &receiver, tick, offset: "0")
        XCTAssertEqual(tick.request?.body, payload)
        tick = try step(&client, &receiver, tick)
        XCTAssertEqual(receiver.sessions["sid"]?.halfFile, payload)

        tick = client.pause(reason: "user")
        tick = try step(&client, &receiver, tick)
        guard case .paused = tick.status else { return XCTFail("pause") }
        tick = client.resume()
        tick = try step(&client, &receiver, tick)

        while let request = tick.request, request.target.hasSuffix("/complete") == false {
            tick = try step(&client, &receiver, tick)
        }
        let bad = try respond(&receiver, completeBody(String(repeating: "0", count: 64)))
        XCTAssertEqual(bad.status, 422)
        XCTAssertEqual(receiver.sessions["sid"]?.committed, [])
        XCTAssertEqual(receiver.sessions["sid"]?.mismatches, 1)

        tick = client.receive(bad)
        XCTAssertEqual(tick.request?.method, "PUT")
        XCTAssertEqual(tick.request?.value(for: "x-limlink-offset"), "0")
        XCTAssertEqual(tick.request?.body, payload)

        while let request = tick.request, request.target.hasSuffix("/complete") == false {
            tick = try step(&client, &receiver, tick)
        }
        tick = try step(&client, &receiver, tick)
        tick = try step(&client, &receiver, tick)
        XCTAssertEqual(tick.status, .completed(finalName: "note.txt"))
        XCTAssertEqual(receiver.sessions["sid"]?.published, payload)
        XCTAssertEqual(receiver.sessions["sid"]?.mismatches, 1)
    }

    private var lastResumeBody: [UInt8] = []

    private func makeReceiver(_ host: HostAppIdentity) -> SingleFileReceiver {
        SingleFileReceiver(
            host: host,
            alias: "乙",
            devType: "iphone",
            trustedFingerprints: ["fp-client"],
            sessionIDs: ["sid"],
            tokens: ["tok"]
        )
    }

    private func makeClient(_ host: HostAppIdentity, bytes: [UInt8]) -> SingleFileClient {
        SingleFileClient(
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
            bytes: bytes,
            clientSessionKey: "key-1"
        )
    }

    private func accept(_ receiver: inout SingleFileReceiver, bytes: [UInt8], size: Int) throws {
        _ = bytes
        let body = JSONWire.data([
            "clientSessionKey": "key-1",
            "transport": "lan",
            "totalEntries": 1,
            "totalBytes": size,
            "entries": [[
                "id": "fid",
                "kind": "file",
                "relativePath": "note.txt",
                "size": size,
            ]],
        ])
        let created = receiver.handle(
            WireApp.request(method: "POST", path: "/limlink/v1/sessions", app: "limlink", hostHeader: "10.0.0.8", body: body, json: true),
            peerAddressIsLocal: false,
            clientFingerprint: "fp-client"
        )
        guard case .response(let response) = created else {
            XCTFail("create")
            return
        }
        XCTAssertEqual(response.status, 202)
        receiver.decide(sessionID: "sid", accept: true)
    }

    private func put(offset: Int, body: [UInt8]) -> HTTPRequest {
        WireApp.request(
            method: "PUT",
            path: "/limlink/v1/sessions/sid/files/fid",
            app: "limlink",
            hostHeader: "10.0.0.8",
            body: body,
            json: false,
            extra: [
                "content-type": "application/octet-stream",
                "x-limlink-token": "tok",
                "x-limlink-offset": String(offset),
            ]
        )
    }

    private func control(_ action: String, reason: String?, detail: [String: String]?) -> HTTPRequest {
        var body: [String: Any] = ["sessionId": "sid"]
        if let reason {
            body["reason"] = reason
        }
        if let detail {
            body["detail"] = detail
        }
        return WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions/sid/\(action)",
            app: "limlink",
            hostHeader: "10.0.0.8",
            body: JSONWire.data(body),
            json: true
        )
    }

    private func skip(detail: [String: String]) -> HTTPRequest {
        WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions/sid/files/fid/skip",
            app: "limlink",
            hostHeader: "10.0.0.8",
            body: JSONWire.data([
                "sessionId": "sid",
                "reason": "user",
                "detail": detail,
            ]),
            json: true
        )
    }

    private func detail(in body: [UInt8]) -> [String: String]? {
        guard let object = JSONWire.object(body),
              let holds = object["holds"] as? [Any],
              let first = holds.first as? [String: Any],
              let raw = first["detail"] as? [String: Any] else { return nil }
        var detail: [String: String] = [:]
        for (key, value) in raw {
            if let text = value as? String {
                detail[key] = text
            }
        }
        return detail
    }

    private func completeBody(_ sha: String) -> HTTPRequest {
        WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions/sid/files/fid/complete",
            app: "limlink",
            hostHeader: "10.0.0.8",
            body: JSONWire.data(["sha256": sha]),
            json: true
        )
    }

    private func respond(_ receiver: inout SingleFileReceiver, _ request: HTTPRequest) throws -> HTTPResponse {
        let step = receiver.handle(request, peerAddressIsLocal: false, clientFingerprint: "fp-client")
        switch step {
        case .response(let response):
            if request.target.hasSuffix("/resume") {
                lastResumeBody = response.body
            }
            return response
        case .awaitDecision(let sid):
            receiver.decide(sessionID: sid, accept: true)
            return receiver.pollResponse(sessionID: sid)
        }
    }

    private func step(
        _ client: inout SingleFileClient,
        _ receiver: inout SingleFileReceiver,
        _ tick: SingleFileClientTick
    ) throws -> SingleFileClientTick {
        let request = try XCTUnwrap(tick.request)
        let response = try respond(&receiver, request)
        return client.receive(response)
    }

    private func driveUntilPut(
        _ client: inout SingleFileClient,
        _ receiver: inout SingleFileReceiver,
        _ tick: SingleFileClientTick,
        offset: String
    ) throws -> SingleFileClientTick {
        var tick = tick
        while let request = tick.request {
            if request.method == "PUT", request.value(for: "x-limlink-offset") == offset {
                return tick
            }
            tick = try step(&client, &receiver, tick)
        }
        XCTFail("put \(offset) did not start")
        return tick
    }
}
