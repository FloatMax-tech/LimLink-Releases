import Foundation

public enum ReceiverPhase: Equatable, Sendable {
    case pending
    case accepted
    case paused
    case expired
    case completed
    case verifyFailed
    case rejected
    case cancelled
}

public enum TransferHoldParty: String, Equatable, Sendable {
    case sender
    case receiver
}

public struct TransferHold: Equatable, Sendable {
    public var by: TransferHoldParty
    /// Nil holds the whole session. A value holds one file.
    public var fileID: String?
    public var reason: String
    /// Optional object from the pause, cancel, or skip body, copied through unchanged.
    public var detail: [String: String]?
    public var since: String

    public init(by: TransferHoldParty, fileID: String?, reason: String, detail: [String: String]?, since: String) {
        self.by = by
        self.fileID = fileID
        self.reason = reason
        self.detail = detail
        self.since = since
    }
}

public struct ReceiverSession: Equatable, Sendable {
    public var sessionID: String
    public var clientKey: String
    public var fileID: String
    public var relativePath: String
    public var size: Int
    public var token: String
    public var committed: [UInt8]
    /// Flushed prefix. Pause, background, and expiry report this length, not an unflushed tail.
    public var halfFile: [UInt8]
    public var holds: [TransferHold]
    public var pausedSince: Date?
    public var disconnectedSince: Date?
    /// Seconds already spent in `transferring`, not counting the open segment.
    public var transferAccumulated: TimeInterval
    public var transferringSince: Date?
    public var mismatches: Int
    public var phase: ReceiverPhase
    public var finalName: String
    /// Bytes the user may see. Nil until SHA-256 matches and the name is final.
    public var published: [UInt8]?
    /// Disk-backed sessions keep all payload arrays empty and track only this durable length.
    public var isDiskBacked: Bool = false
    public var fileURL: URL? = nil
    public var publishedFileURL: URL? = nil
    var diskByteCount: Int = 0

    public var committedByteCount: Int { isDiskBacked ? diskByteCount : halfFile.count }
    public var publishedByteCount: Int { phase == .completed ? committedByteCount : 0 }
}

public enum ReceiverStep: Equatable, Sendable {
    case response(HTTPResponse)
    case awaitDecision(sessionID: String)
}

public struct SingleFileReceiver {
    public var host: HostAppIdentity
    public var alias: String
    public var devType: String
    public var port: Int
    public var trustedFingerprints: Set<String>
    public var sessionIDs: [String]
    public var tokens: [String]
    public var now: String
    public var durationMs: Int
    /// Nil preserves unbounded retention. A value caps all retained sessions before creation.
    public var maximumRetainedSessions: Int?
    /// Pause retention is measured on this clock. Tests move it with `advanceClock(to:)`.
    public private(set) var clock: Date
    /// A paused session that is not resumed within this interval becomes expired.
    public static let pauseRetention: TimeInterval = 30 * 60
    public private(set) var sessions: [String: ReceiverSession] = [:]
    /// Local only. An invite ticket is rejected until step 4 replaces the check.
    public private(set) var diagnostics: [DiagnosticNote] = []
    private struct SessionOwner: Hashable {
        var fingerprint: String
        var connectionScope: String?
    }
    private struct SessionKey: Hashable {
        var owner: SessionOwner
        var clientKey: String
    }
    private var owners: [String: SessionOwner] = [:]
    private var keys: [SessionKey: String] = [:]
    private var pendingPublications: Set<String> = []
    private let storageDirectory: URL?
    private let maximumFileBytes: Int?
    private var diskFiles: [String: DiskReceiveFile] = [:]

    public init(
        host: HostAppIdentity,
        alias: String,
        devType: String = "iphone",
        port: Int = 52470,
        trustedFingerprints: Set<String> = [],
        sessionIDs: [String],
        tokens: [String],
        now: String = "2026-10-08T03:00:00Z",
        durationMs: Int = 0,
        maximumRetainedSessions: Int? = nil,
        storageDirectory: URL? = nil,
        maximumFileBytes: Int? = nil
    ) {
        self.host = host
        self.alias = alias
        self.devType = devType
        self.port = port
        self.trustedFingerprints = trustedFingerprints
        self.sessionIDs = sessionIDs
        self.tokens = tokens
        self.now = now
        self.durationMs = durationMs
        self.maximumRetainedSessions = maximumRetainedSessions.map { max(0, $0) }
        self.storageDirectory = storageDirectory
        self.maximumFileBytes = maximumFileBytes.map { max(0, min($0, FileTransferLimits.maximumFileBytes)) }
            ?? (storageDirectory == nil ? nil : FileTransferLimits.maximumFileBytes)
        self.clock = DiagnosticTimestamps.parse(now) ?? Date(timeIntervalSince1970: 0)
    }

    /// Moves the retention clock. At `pauseRetention` a paused session expires and the flushed prefix stays.
    public mutating func advanceClock(to date: Date) {
        clock = date
        expirePausedSessions()
    }

    /// Applies one lifecycle directive to every session this receiver is transferring.
    public mutating func apply(_ directive: LifecycleDirective) {
        if directive.flushHalfFile {
            checkpointActive()
        }
        if let reason = directive.pauseReason {
            for sid in sessions.keys {
                placeHold(sid, by: .receiver, fileID: nil, reason: reason, detail: directive.detail)
            }
        }
        if directive.resumeLocalHold {
            for sid in sessions.keys {
                liftHold(sid, by: .receiver, fileID: nil)
            }
        }
    }

    @discardableResult
    public mutating func decide(sessionID: String, accept: Bool) -> Bool {
        guard var session = sessions[sessionID], session.phase == .pending else { return false }
        session.phase = accept ? .accepted : .rejected
        if accept {
            session.transferringSince = clock
        } else {
            clearPayload(&session)
        }
        sessions[sessionID] = session
        return true
    }

    /// Explicitly releases one session and its idempotency key. The host opts out of its resumption.
    @discardableResult
    public mutating func discardSession(sessionID: String) -> Bool {
        guard sessions.removeValue(forKey: sessionID) != nil else { return false }
        diskFiles.removeValue(forKey: sessionID)
        owners.removeValue(forKey: sessionID)
        pendingPublications.remove(sessionID)
        keys = keys.filter { $0.value != sessionID }
        return true
    }

    /// Nil scope permits resumption by the same TLS identity. A scope binds the session to one connection.
    public func ownsSession(sessionID: String, clientFingerprint: String, connectionScope: String? = nil) -> Bool {
        sessions[sessionID] != nil && owners[sessionID] == SessionOwner(fingerprint: clientFingerprint, connectionScope: connectionScope)
    }

    /// Records the exact safe basename returned by a host's durable save of a verified file.
    @discardableResult
    public mutating func updatePublishedFileName(sessionID: String, fileName: String) -> Bool {
        guard var session = sessions[sessionID], session.phase == .completed, session.published != nil || session.publishedFileURL != nil,
              case .success(let safeName) = SinglePath.landingName(fileName), safeName == fileName else { return false }
        session.finalName = fileName
        sessions[sessionID] = session
        pendingPublications.remove(sessionID)
        // The host has durably saved or moved the file; only the original staging path is ours.
        diskFiles.removeValue(forKey: sessionID)
        return true
    }

    /// A PUT body that ended before it finished. Only `flushed` counts. `tail` is dropped.
    public mutating func incomingBodyCutOff(sessionID: String, fileID: String, flushed: [UInt8], tail: [UInt8]) {
        guard var session = sessions[sessionID], session.fileID == fileID, session.phase == .accepted else { return }
        let room = session.size - session.committedByteCount
        guard room > 0 else { return }
        let keptCount = min(flushed.count, room)
        guard !session.isDiskBacked || keptCount <= FileTransferLimits.maximumChunkBytes else { return }
        let kept = Array(flushed.prefix(keptCount))
        if session.isDiskBacked {
            do {
                guard let file = diskFiles[sessionID] else { throw POSIXError(.ENOENT) }
                try file.append(kept, offset: session.committedByteCount)
                session.diskByteCount += kept.count
            } catch {
                clearPayload(&session)
                session.phase = .cancelled
            }
        } else {
            session.committed.append(contentsOf: kept)
            session.halfFile = session.committed
        }
        session.published = nil
        _ = tail
        sessions[sessionID] = session
    }

    /// Closes the transferring segment so disconnected time is not part of `durationMs`.
    public mutating func noteDisconnected(sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        closeTransferSegment(&session)
        if session.disconnectedSince == nil {
            session.disconnectedSince = clock
        }
        sessions[sessionID] = session
    }

    /// A durable publication holds session routes until the host records the saved name or discards the session.
    public mutating func handle(
        _ request: HTTPRequest,
        peerAddressIsLocal: Bool,
        clientFingerprint: String,
        connectionScope: String? = nil,
        deferPublication: Bool = false,
        decisionElapsedSec: Int = 0
    ) -> ReceiverStep {
        let route = Route(method: request.method, target: request.target)
        if route.kind == .hello {
            let body = WireApp.helloResponse(
                app: host.app,
                alias: alias,
                devType: devType,
                port: port,
                trusted: trustedFingerprints.contains(clientFingerprint),
                busy: false
            )
            return .response(body)
        }
        if route.kind == .inviteHello {
            let body = WireApp.inviteHelloResponse(
                app: host.app,
                inviteSessionId: sessionIDs.first ?? "invite-session",
                nonceS: "bm9uY2U",
                alias: alias,
                inviteAgeSec: 0,
                suite: "CPACE-RISTR255-SHA512"
            )
            return .response(body)
        }
        switch AppGate.admit(
            headerValue: request.value(for: LimLinkProtocol.appHeader),
            host: host,
            peerAddressIsLocal: peerAddressIsLocal
        ) {
        case .mismatch(let error):
            return .response(WireApp.errorResponse(error))
        case .allowed:
            break
        }
        guard trustedFingerprints.contains(clientFingerprint) else {
            return .response(WireApp.errorResponse(ProtocolError(code: .notPaired, httpStatus: 401, retryable: false)))
        }
        let owner = SessionOwner(fingerprint: clientFingerprint, connectionScope: connectionScope)
        if let sessionID = route.sessionID {
            guard ownsSession(sessionID: sessionID, clientFingerprint: clientFingerprint, connectionScope: connectionScope) else {
                return .response(WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false)))
            }
            guard !pendingPublications.contains(sessionID) else {
                return .response(WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: true)))
            }
        }
        switch route.kind {
        case .create:
            return .response(create(request, owner: owner))
        case .poll(let sid):
            return poll(sid, elapsed: decisionElapsedSec)
        case .progress(let sid, let fid):
            return .response(progress(sid: sid, fid: fid))
        case .pause(let sid):
            return .response(pause(request, sid: sid, by: .sender))
        case .resume(let sid):
            return .response(resume(request, sid: sid, by: .sender))
        case .cancel(let sid):
            return .response(cancel(request, sid: sid))
        case .skip(let sid, let fid):
            return .response(skip(request, sid: sid, fid: fid))
        case .put(let sid, let fid):
            return .response(put(request, sid: sid, fid: fid))
        case .complete(let sid, let fid):
            return .response(complete(request, sid: sid, fid: fid, deferPublication: deferPublication))
        case .finish(let sid):
            return .response(finish(sid))
        default:
            return .response(WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false)))
        }
    }

    public func pollResponse(sessionID: String, decisionElapsedSec: Int = 0) -> HTTPResponse {
        guard !pendingPublications.contains(sessionID) else {
            return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: true))
        }
        switch poll(sessionID, elapsed: decisionElapsedSec) {
        case .response(let response):
            return response
        case .awaitDecision:
            return HTTPResponse(status: 202, body: JSONWire.data(["sessionId": sessionID, "state": "pending"]))
        }
    }

    private mutating func create(_ request: HTTPRequest, owner: SessionOwner) -> HTTPResponse {
        guard let object = JSONWire.object(request.body) else {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        if object["inviteTicket"] != nil || object["inviteSessionId"] != nil {
            // TODO(protocol §15.10): TicketMismatch and TicketUsed both map to E_INVITE_TICKET_INVALID.
            // Step 4 replaces this unconditional reject with the real check. The wire code stays.
            diagnostics.append(DiagnosticNote(
                message: DiagnosticNote.ticketVerificationUnimplemented,
                timestamp: now
            ))
            return WireApp.errorResponse(ProtocolError(
                code: .inviteTicketInvalid,
                httpStatus: 403,
                retryable: false
            ))
        }
        guard let key = JSONWire.string(object, "clientSessionKey"),
              let transport = JSONWire.string(object, "transport"),
              let entries = object["entries"] as? [[String: Any]] else {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        if transport == "remote-link" {
            return WireApp.errorResponse(ProtocolError(code: .notImplemented, httpStatus: 501, retryable: false))
        }
        guard transport == "lan" else {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        let scopedKey = SessionKey(owner: owner, clientKey: key)
        if let existing = keys[scopedKey], sessions[existing] != nil {
            return HTTPResponse(status: 202, body: JSONWire.data(["sessionId": existing, "state": "pending"]))
        }
        if let maximumRetainedSessions, sessions.count >= maximumRetainedSessions {
            return WireApp.errorResponse(ProtocolError(code: .busy, httpStatus: 409, retryable: true))
        }
        // TODO(protocol §5.3): a session with more than one entry is specified. This milestone accepts one file.
        guard entries.count == 1, let entry = entries.first else {
            return WireApp.errorResponse(ProtocolError(code: .notImplemented, httpStatus: 501, retryable: false))
        }
        guard JSONWire.string(entry, "kind") == "file",
              let fileID = JSONWire.string(entry, "id"),
              let relative = JSONWire.string(entry, "relativePath"),
              let size = JSONWire.int(entry, "size"), size >= 0 else {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        if let maximumFileBytes, size > maximumFileBytes {
            return WireApp.errorResponse(ProtocolError(code: .fileTooLarge, httpStatus: 413, retryable: false))
        }
        let landing: String
        switch SinglePath.landingName(relative) {
        case .success(let name):
            landing = name
        case .failure(let error):
            return WireApp.errorResponse(error)
        }
        guard let sessionID = sessionIDs.first, let token = tokens.first else {
            return WireApp.errorResponse(ProtocolError(code: .internal, httpStatus: 500, retryable: true))
        }
        let diskFile: DiskReceiveFile?
        do {
            diskFile = try storageDirectory.map { try DiskReceiveFile(directory: $0) }
        } catch {
            return WireApp.errorResponse(ProtocolError(code: .writeFailed, httpStatus: 500, retryable: true))
        }
        sessionIDs.removeFirst()
        tokens.removeFirst()
        var session = ReceiverSession(
            sessionID: sessionID,
            clientKey: key,
            fileID: fileID,
            relativePath: relative,
            size: size,
            token: token,
            committed: [],
            halfFile: [],
            holds: [],
            pausedSince: nil,
            disconnectedSince: nil,
            transferAccumulated: 0,
            transferringSince: nil,
            mismatches: 0,
            phase: .pending,
            finalName: landing,
            published: nil
        )
        if let diskFile {
            session.isDiskBacked = true
            session.fileURL = diskFile.url
            diskFiles[sessionID] = diskFile
        }
        sessions[sessionID] = session
        owners[sessionID] = owner
        keys[scopedKey] = sessionID
        return HTTPResponse(status: 202, body: JSONWire.data(["sessionId": sessionID, "state": "pending"]))
    }

    private func poll(_ sid: String, elapsed: Int) -> ReceiverStep {
        guard let session = sessions[sid] else {
            return .response(WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false)))
        }
        switch session.phase {
        case .pending:
            if elapsed >= 120 {
                return .response(WireApp.errorResponse(ProtocolError(code: .decisionTimeout, httpStatus: 408, retryable: true)))
            }
            // TODO(protocol §5.2): the JSON body when `wait` elapses before a decision is not specified. The caller holds the poll.
            return .awaitDecision(sessionID: sid)
        case .rejected:
            return .response(WireApp.errorResponse(ProtocolError(code: .rejected, httpStatus: 403, retryable: false)))
        case .paused:
            // The sender learns a receiver hold from this poll and stops PUT. It does not dial a new call of its own.
            return .response(controlResponse(session))
        case .expired:
            return .response(WireApp.errorResponse(ProtocolError(code: .sessionExpired, httpStatus: 410, retryable: false)))
        case .cancelled:
            return .response(WireApp.errorResponse(ProtocolError(code: .sessionCancelled, httpStatus: 410, retryable: false)))
        case .accepted, .completed, .verifyFailed:
            let files: [String: Any] = [
                session.fileID: [
                    "accept": session.phase != .rejected,
                    "token": session.token,
                    "offset": session.committedByteCount,
                    "finalName": session.finalName,
                    "state": stateName(session.phase),
                ],
            ]
            return .response(HTTPResponse(status: 200, body: JSONWire.data([
                "state": "accepted",
                "files": files,
            ])))
        }
    }

    private mutating func put(_ request: HTTPRequest, sid: String, fid: String) -> HTTPResponse {
        guard var session = sessions[sid], session.fileID == fid else {
            return WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false))
        }
        if let blocked = transferBlocked(session) {
            return blocked
        }
        guard session.phase == .accepted else {
            return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))
        }
        guard request.value(for: "x-limlink-token") == session.token else {
            return WireApp.errorResponse(ProtocolError(code: .tokenInvalid, httpStatus: 403, retryable: false))
        }
        guard request.value(for: "content-type") == "application/octet-stream" else {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        if let encoding = request.value(for: "content-encoding"), encoding != "identity" {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        let offset = Int(request.value(for: "x-limlink-offset") ?? "") ?? -1
        guard offset == session.committedByteCount else {
            return WireApp.errorResponse(.offsetMismatch(committedBytes: session.committedByteCount))
        }
        let remaining = session.size - offset
        guard request.body.count <= remaining, remaining == 0 || !request.body.isEmpty else {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        guard request.body.count <= FileTransferLimits.maximumChunkBytes else {
            return WireApp.errorResponse(ProtocolError(code: .fileTooLarge, httpStatus: 413, retryable: false))
        }
        if session.isDiskBacked {
            do {
                guard let file = diskFiles[sid] else { throw POSIXError(.ENOENT) }
                try file.append(request.body, offset: offset)
                session.diskByteCount += request.body.count
            } catch {
                clearPayload(&session)
                session.phase = .cancelled
                sessions[sid] = session
                return WireApp.errorResponse(ProtocolError(code: .writeFailed, httpStatus: 500, retryable: true))
            }
        } else {
            session.committed.append(contentsOf: request.body)
            session.halfFile = session.committed
        }
        session.published = nil
        sessions[sid] = session
        return HTTPResponse(status: 200, body: JSONWire.data(["committedBytes": session.committedByteCount]))
    }

    private mutating func complete(_ request: HTTPRequest, sid: String, fid: String, deferPublication: Bool) -> HTTPResponse {
        guard var session = sessions[sid], session.fileID == fid else {
            return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))
        }
        if let blocked = transferBlocked(session) {
            return blocked
        }
        guard session.phase == .accepted else {
            return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))
        }
        guard let object = JSONWire.object(request.body), let claimed = JSONWire.string(object, "sha256") else {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        switch FileDigest.parse(claimed) {
        case .failure(let error):
            return WireApp.errorResponse(error)
        case .success(let expected):
            let actual: String
            do {
                if session.isDiskBacked {
                    guard let file = diskFiles[sid] else { throw POSIXError(.ENOENT) }
                    actual = try FileDigest.sha256Hex(fileURL: file.url)
                } else {
                    actual = FileDigest.sha256Hex(session.committed)
                }
            } catch {
                clearPayload(&session)
                session.phase = .cancelled
                sessions[sid] = session
                return WireApp.errorResponse(ProtocolError(code: .writeFailed, httpStatus: 500, retryable: true))
            }
            guard actual == expected, session.committedByteCount == session.size else {
                session.mismatches += 1
                if session.mismatches >= 2 {
                    session.phase = .verifyFailed
                    clearPayload(&session)
                } else {
                    do {
                        try diskFiles[sid]?.reset()
                        session.committed = []
                        session.halfFile = []
                        session.diskByteCount = 0
                        session.published = nil
                        session.publishedFileURL = nil
                    } catch {
                        clearPayload(&session)
                        session.phase = .cancelled
                        sessions[sid] = session
                        return WireApp.errorResponse(ProtocolError(code: .writeFailed, httpStatus: 500, retryable: true))
                    }
                }
                sessions[sid] = session
                return WireApp.errorResponse(ProtocolError(code: .checksumMismatch, httpStatus: 422, retryable: true))
            }
            session.phase = .completed
            if session.isDiskBacked {
                session.publishedFileURL = session.fileURL
            } else {
                session.published = session.committed
            }
            sessions[sid] = session
            if deferPublication {
                pendingPublications.insert(sid)
            }
            return HTTPResponse(status: 200, body: JSONWire.data([
                "verified": true,
                "finalName": session.finalName,
            ]))
        }
    }

    private mutating func finish(_ sid: String) -> HTTPResponse {
        guard let session = sessions[sid] else {
            return WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false))
        }
        guard session.phase == .completed || session.phase == .verifyFailed || session.phase == .rejected || session.phase == .cancelled else {
            return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))
        }
        var mutable = session
        closeTransferSegment(&mutable)
        sessions[sid] = mutable
        let durationMs = Int((mutable.transferAccumulated * 1000).rounded())
        let fileState: String
        let match: Any
        switch session.phase {
        case .completed:
            fileState = "completed"
            match = true
        case .verifyFailed:
            fileState = "verify_failed"
            match = false
        case .cancelled:
            fileState = "cancelled"
            match = NSNull()
        default:
            fileState = "rejected"
            match = NSNull()
        }
        // Disk-backed sessions sync every bounded PUT; legacy memory sessions retain their completed prefix.
        let files: [[String: Any]] = [[
            "id": session.fileID,
            "relativePath": session.relativePath,
            "finalName": session.finalName,
            "renamed": session.finalName != session.relativePath,
            "state": fileState,
            "size": session.size,
            "bytesReceived": session.publishedByteCount,
            "sha256Match": match,
            "errorCode": session.phase == .completed ? NSNull() : "E_CHECKSUM_MISMATCH",
        ]]
        return HTTPResponse(status: 200, body: JSONWire.data([
            "sessionId": sid,
            "state": "finished",
            "startedAt": now,
            "finishedAt": now,
            "durationMs": durationMs,
            "totals": [
                "files": 1,
                "completed": session.phase == .completed ? 1 : 0,
                "failed": 0,
                "verifyFailed": session.phase == .verifyFailed ? 1 : 0,
                "rejected": session.phase == .rejected ? 1 : 0,
                "cancelled": 0,
                "bytesPlanned": session.size,
                "bytesReceived": session.publishedByteCount,
            ],
            "files": files,
        ]))
    }

    private func progress(sid: String, fid: String) -> HTTPResponse {
        guard let session = sessions[sid], session.fileID == fid else {
            return WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false))
        }
        if session.phase == .expired {
            return WireApp.errorResponse(ProtocolError(code: .sessionExpired, httpStatus: 410, retryable: false))
        }
        return HTTPResponse(status: 200, body: JSONWire.data([
            "state": progressState(session.phase),
            "committedBytes": session.committedByteCount,
        ]))
    }

    private mutating func pause(_ request: HTTPRequest, sid: String, by party: TransferHoldParty) -> HTTPResponse {
        let fields: ControlFields
        switch controlFields(request, sid: sid, reasonRequired: true) {
        case .fields(let value):
            fields = value
        case .rejected(let response):
            return response
        }
        guard var session = sessions[sid] else {
            return WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false))
        }
        if session.phase == .expired {
            return WireApp.errorResponse(ProtocolError(code: .sessionExpired, httpStatus: 410, retryable: false))
        }
        if session.phase != .accepted && session.phase != .paused {
            return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))
        }
        if let fileID = fields.fileID, fileID != session.fileID {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        placeHold(sid, by: party, fileID: fields.fileID, reason: fields.reason ?? "user", detail: fields.detail)
        session = sessions[sid] ?? session
        return controlResponse(session)
    }

    private mutating func resume(_ request: HTTPRequest, sid: String, by party: TransferHoldParty) -> HTTPResponse {
        let fields: ControlFields
        switch controlFields(request, sid: sid, reasonRequired: false) {
        case .fields(let value):
            fields = value
        case .rejected(let response):
            return response
        }
        guard var session = sessions[sid] else {
            return WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false))
        }
        if session.phase == .expired {
            return WireApp.errorResponse(ProtocolError(code: .sessionExpired, httpStatus: 410, retryable: false))
        }
        if session.phase != .accepted && session.phase != .paused {
            return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))
        }
        if let fileID = fields.fileID, fileID != session.fileID {
            return WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        liftHold(sid, by: party, fileID: fields.fileID)
        session = sessions[sid] ?? session
        return controlResponse(session)
    }

    private mutating func cancel(_ request: HTTPRequest, sid: String) -> HTTPResponse {
        switch controlFields(request, sid: sid, reasonRequired: true) {
        case .rejected(let response):
            return response
        case .fields(let fields):
            guard var session = sessions[sid] else {
                return WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false))
            }
            guard session.phase == .accepted || session.phase == .paused || session.phase == .pending else {
                return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))
            }
            closeTransferSegment(&session)
            clearPayload(&session)
            session.phase = .cancelled
            if let detail = fields.detail {
                session.holds = [TransferHold(by: .sender, fileID: nil, reason: fields.reason ?? "user", detail: detail, since: DiagnosticTimestamps.format(clock))]
            }
            sessions[sid] = session
            return controlResponse(session)
        }
    }

    private mutating func skip(_ request: HTTPRequest, sid: String, fid: String) -> HTTPResponse {
        switch controlFields(request, sid: sid, reasonRequired: true) {
        case .rejected(let response):
            return response
        case .fields(let fields):
            guard var session = sessions[sid], session.fileID == fid else {
                return WireApp.errorResponse(ProtocolError(code: .sessionNotFound, httpStatus: 404, retryable: false))
            }
            guard session.phase == .accepted || session.phase == .paused else {
                return WireApp.errorResponse(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))
            }
            closeTransferSegment(&session)
            clearPayload(&session)
            session.phase = .cancelled
            if let detail = fields.detail {
                session.holds = [TransferHold(by: .sender, fileID: fid, reason: fields.reason ?? "user", detail: detail, since: DiagnosticTimestamps.format(clock))]
            }
            sessions[sid] = session
            return controlResponse(session)
        }
    }

    private func controlFields(_ request: HTTPRequest, sid: String, reasonRequired: Bool) -> ControlParse {
        guard let object = JSONWire.object(request.body),
              let bodySID = JSONWire.string(object, "sessionId"),
              bodySID == sid else {
            return .rejected(WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false)))
        }
        let reason = JSONWire.string(object, "reason")
        if reasonRequired, reason == nil {
            return .rejected(WireApp.errorResponse(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false)))
        }
        // TODO(protocol §6.3): trust_revoked is a cancel. It is stored as a hold until cancel is specified for this call.
        return .fields(ControlFields(
            fileID: JSONWire.string(object, "fileId"),
            reason: reason,
            detail: Self.detailObject(object["detail"])
        ))
    }

    /// `pause`, `cancel`, and `skip` all use this. The object is copied as string fields.
    private static func detailObject(_ value: Any?) -> [String: String]? {
        guard let raw = value as? [String: Any] else { return nil }
        var detail: [String: String] = [:]
        for (key, item) in raw {
            if let text = item as? String {
                detail[key] = text
            }
        }
        return detail
    }

    private mutating func placeHold(
        _ sid: String,
        by party: TransferHoldParty,
        fileID: String?,
        reason: String,
        detail: [String: String]?
    ) {
        guard var session = sessions[sid] else { return }
        guard session.phase == .accepted || session.phase == .paused else { return }
        session.halfFile = session.committed
        closeTransferSegment(&session)
        session.holds.removeAll { $0.by == party && $0.fileID == fileID }
        session.holds.append(TransferHold(
            by: party,
            fileID: fileID,
            reason: reason,
            detail: detail,
            since: DiagnosticTimestamps.format(clock)
        ))
        if session.phase != .paused {
            session.pausedSince = clock
            session.phase = .paused
        }
        sessions[sid] = session
    }

    private mutating func liftHold(_ sid: String, by party: TransferHoldParty, fileID: String?) {
        guard var session = sessions[sid], session.phase == .paused || session.phase == .accepted else { return }
        session.holds.removeAll { hold in
            guard hold.by == party else { return false }
            if fileID == nil { return true }
            return hold.fileID == nil || hold.fileID == fileID
        }
        if session.holds.isEmpty, session.phase == .paused {
            session.phase = .accepted
            session.pausedSince = nil
            session.disconnectedSince = nil
            session.transferringSince = clock
        }
        sessions[sid] = session
    }

    private mutating func closeTransferSegment(_ session: inout ReceiverSession) {
        guard let since = session.transferringSince else { return }
        let elapsed = clock.timeIntervalSince(since)
        if elapsed > 0 {
            session.transferAccumulated += elapsed
        }
        session.transferringSince = nil
    }

    private mutating func checkpointActive() {
        for sid in sessions.keys {
            guard var session = sessions[sid] else { continue }
            guard session.phase == .accepted || session.phase == .paused else { continue }
            session.halfFile = session.committed
            sessions[sid] = session
        }
    }

    private mutating func expirePausedSessions() {
        // Expired sessions refuse resume. The flushed prefix stays for §7.3 until 24 hours after its last write.
        for sid in sessions.keys {
            guard var session = sessions[sid], session.phase == .paused, let since = session.pausedSince else { continue }
            if clock.timeIntervalSince(since) >= Self.pauseRetention {
                session.phase = .expired
                sessions[sid] = session
            }
        }
    }

    private mutating func clearPayload(_ session: inout ReceiverSession) {
        diskFiles.removeValue(forKey: session.sessionID)
        session.committed = []
        session.halfFile = []
        session.published = nil
        session.fileURL = nil
        session.publishedFileURL = nil
        session.diskByteCount = 0
    }

    private func transferBlocked(_ session: ReceiverSession) -> HTTPResponse? {
        switch session.phase {
        case .paused:
            return WireApp.errorResponse(ProtocolError(code: .sessionPaused, httpStatus: 409, retryable: true))
        case .expired:
            return WireApp.errorResponse(ProtocolError(code: .sessionExpired, httpStatus: 410, retryable: false))
        default:
            return nil
        }
    }

    private func controlResponse(_ session: ReceiverSession) -> HTTPResponse {
        let state = session.phase == .paused ? "paused" : progressState(session.phase)
        let holds: [[String: Any]] = session.holds.map { hold in
            var item: [String: Any] = [
                "by": hold.by.rawValue,
                "reason": hold.reason,
                "since": hold.since,
            ]
            if let fileID = hold.fileID {
                item["fileId"] = fileID
            }
            if let detail = hold.detail {
                item["detail"] = detail
            }
            return item
        }
        let files: [String: Any] = [
            session.fileID: [
                "state": progressState(session.phase),
                "committedBytes": session.committedByteCount,
            ],
        ]
        return HTTPResponse(status: 200, body: JSONWire.data([
            "state": state,
            "holds": holds,
            "files": files,
        ]))
    }

    private func progressState(_ phase: ReceiverPhase) -> String {
        switch phase {
        case .pending: return "pending"
        case .accepted: return "transferring"
        case .paused: return "paused"
        case .expired: return "expired"
        case .completed: return "completed"
        case .verifyFailed: return "verify_failed"
        case .rejected: return "rejected"
        case .cancelled: return "cancelled"
        }
    }

    private func stateName(_ phase: ReceiverPhase) -> String {
        switch phase {
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .paused: return "paused"
        case .expired: return "expired"
        case .completed: return "completed"
        case .verifyFailed: return "verify_failed"
        case .rejected: return "rejected"
        case .cancelled: return "cancelled"
        }
    }
}

private struct ControlFields {
    var fileID: String?
    var reason: String?
    var detail: [String: String]?
}

private enum ControlParse {
    case fields(ControlFields)
    case rejected(HTTPResponse)
}

enum SinglePath {
    static func landingName(_ relativePath: String) -> Result<String, ProtocolError> {
        let bad = relativePath.isEmpty
            || relativePath.contains("/")
            || relativePath.contains("\\")
            || relativePath == "."
            || relativePath == ".."
            || relativePath.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        if bad {
            return .failure(ProtocolError(code: .pathInvalid, httpStatus: 400, retryable: false, detail: ["entryId": relativePath]))
        }
        let illegal: Set<Character> = ["<", ">", ":", "\"", "|", "?", "*"]
        var name = String(relativePath.map { illegal.contains($0) ? "_" : $0 })
        while let last = name.last, last == "." || last == " " {
            name.removeLast()
        }
        guard !name.isEmpty else {
            return .failure(ProtocolError(code: .pathInvalid, httpStatus: 400, retryable: false))
        }
        let stem: String
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[dot...])
        } else {
            stem = name
            ext = ""
        }
        let upper = stem.uppercased()
        let reserved: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        let numbered = upper.range(of: #"^(COM|LPT)[1-9]$"#, options: .regularExpression) != nil
        if reserved.contains(upper) || numbered {
            name = stem + "_" + ext
        }
        return .success(name)
    }
}

private struct Route {
    enum Kind: Equatable {
        case hello
        case inviteHello
        case create
        case poll(String)
        case progress(String, String)
        case pause(String)
        case resume(String)
        case cancel(String)
        case skip(String, String)
        case put(String, String)
        case complete(String, String)
        case finish(String)
        case other
    }

    var kind: Kind

    var sessionID: String? {
        switch kind {
        case .poll(let sid), .progress(let sid, _), .pause(let sid), .resume(let sid),
             .cancel(let sid), .skip(let sid, _), .put(let sid, _), .complete(let sid, _), .finish(let sid):
            return sid
        case .hello, .inviteHello, .create, .other:
            return nil
        }
    }

    init(method: String, target: String) {
        let path = target.split(separator: "?", omittingEmptySubsequences: false).first.map(String.init) ?? target
        let parts = path.split(separator: "/").map(String.init)
        if parts == ["limlink", "v1", "hello"] {
            kind = .hello
        } else if parts == ["limlink", "v1", "invite", "hello"] {
            kind = .inviteHello
        } else if parts == ["limlink", "v1", "sessions"] {
            kind = .create
        } else if parts.count == 4, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions" {
            kind = .poll(parts[3])
        } else if parts.count == 5, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions", parts[4] == "pause", method == "POST" {
            kind = .pause(parts[3])
        } else if parts.count == 5, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions", parts[4] == "resume", method == "POST" {
            kind = .resume(parts[3])
        } else if parts.count == 5, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions", parts[4] == "cancel", method == "POST" {
            kind = .cancel(parts[3])
        } else if parts.count == 5, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions", parts[4] == "finish" {
            kind = .finish(parts[3])
        } else if parts.count == 6, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions", parts[4] == "files", method == "GET" {
            kind = .progress(parts[3], parts[5])
        } else if parts.count == 6, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions", parts[4] == "files", method == "PUT" {
            kind = .put(parts[3], parts[5])
        } else if parts.count == 7, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions", parts[4] == "files", parts[6] == "complete" {
            kind = .complete(parts[3], parts[5])
        } else if parts.count == 7, parts[0] == "limlink", parts[1] == "v1", parts[2] == "sessions", parts[4] == "files", parts[6] == "skip", method == "POST" {
            kind = .skip(parts[3], parts[5])
        } else {
            kind = .other
        }
    }
}
