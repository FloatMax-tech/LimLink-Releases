import Foundation

public enum SingleFileClientStatus: Equatable, Sendable {
    case inProgress
    case paused(committedBytes: Int)
    case completed(finalName: String)
    case failed(TransferHostError)
}

public struct SingleFileClientTick: Equatable, Sendable {
    public var request: HTTPRequest?
    public var status: SingleFileClientStatus
    public var logEntry: AppMismatchLogEntry?
    public var bytesSent: Int
    public var bytesTotal: Int

    public init(
        request: HTTPRequest?,
        status: SingleFileClientStatus,
        logEntry: AppMismatchLogEntry? = nil,
        bytesSent: Int,
        bytesTotal: Int
    ) {
        self.request = request
        self.status = status
        self.logEntry = logEntry
        self.bytesSent = bytesSent
        self.bytesTotal = bytesTotal
    }
}

/// Sender for one file. The host writes each `request` and feeds the response back.
/// A checksum mismatch is retried once from offset 0 (protocol §5.5).
public struct SingleFileClient: Sendable {
    public var local: HostAppIdentity
    public var localAlias: String
    public var localDevType: String
    public var localPort: Int
    public var peerHost: String
    public var peerAddressIsLocal: Bool
    public var txtAppRaw: String?
    public var txtAppPresent: Bool
    public var deviceName: String
    public var intent: TlsCheckIntent
    public var timestamp: String
    public var fileID: String
    public var relativePath: String
    public var source: TransferSource
    /// The original bytes for memory sources. File-backed sources are never materialized here.
    public var bytes: [UInt8] {
        get { source.inMemoryBytes ?? [] }
        set { source = TransferSource(bytes: newValue) }
    }
    public var clientSessionKey: String
    public var bindingID: String? = nil

    private var phase: Phase
    private var sessionID: String?
    private var token: String?
    private var offset: Int
    private var checksumRetries: Int
    private var expectedPutEnd: Int?
    /// True after this sender POSTed pause, until that hold is lifted.
    public private(set) var placedLocalHold: Bool

    public init(
        local: HostAppIdentity,
        localAlias: String,
        localDevType: String = "iphone",
        localPort: Int = 52470,
        peerHost: String,
        peerAddressIsLocal: Bool = false,
        txtAppRaw: String? = nil,
        txtAppPresent: Bool = false,
        deviceName: String,
        intent: TlsCheckIntent,
        timestamp: String,
        fileID: String,
        relativePath: String,
        bytes: [UInt8],
        clientSessionKey: String
    ) {
        self.init(
            local: local, localAlias: localAlias, localDevType: localDevType, localPort: localPort,
            peerHost: peerHost, peerAddressIsLocal: peerAddressIsLocal,
            txtAppRaw: txtAppRaw, txtAppPresent: txtAppPresent, deviceName: deviceName,
            intent: intent, timestamp: timestamp, fileID: fileID, relativePath: relativePath,
            source: TransferSource(bytes: bytes), clientSessionKey: clientSessionKey
        )
    }

    public init(
        local: HostAppIdentity,
        localAlias: String,
        localDevType: String = "iphone",
        localPort: Int = 52470,
        peerHost: String,
        peerAddressIsLocal: Bool = false,
        txtAppRaw: String? = nil,
        txtAppPresent: Bool = false,
        deviceName: String,
        intent: TlsCheckIntent,
        timestamp: String,
        fileID: String,
        relativePath: String,
        source: TransferSource,
        clientSessionKey: String
    ) {
        self.local = local
        self.localAlias = localAlias
        self.localDevType = localDevType
        self.localPort = localPort
        self.peerHost = peerHost
        self.peerAddressIsLocal = peerAddressIsLocal
        self.txtAppRaw = txtAppRaw
        self.txtAppPresent = txtAppPresent
        self.deviceName = deviceName
        self.intent = intent
        self.timestamp = timestamp
        self.fileID = fileID
        self.relativePath = relativePath
        self.source = source
        self.clientSessionKey = clientSessionKey
        self.phase = .expectHello
        self.offset = 0
        self.checksumRetries = 0
        self.placedLocalHold = false
    }

    /// Only the initial receiver decision uses the approval timeout.
    public var isAwaitingApproval: Bool {
        phase == .expectPoll && token == nil
    }

    public var canPlacePause: Bool {
        switch phase {
        case .expectPut, .expectComplete, .paused:
            return true
        default:
            return false
        }
    }

    public var canPlaceResume: Bool {
        phase == .paused && placedLocalHold
    }

    public mutating func start() -> SingleFileClientTick {
        phase = .expectHello
        sessionID = nil
        token = nil
        offset = 0
        checksumRetries = 0
        placedLocalHold = false
        finalNameHint = nil
        expectedPutEnd = nil
        guard source.size <= FileTransferLimits.maximumFileBytes else {
            return fail(.wire(ProtocolError(code: .fileTooLarge, httpStatus: nil, retryable: false)))
        }
        return tick(helloRequest(), status: .inProgress, sent: 0)
    }

    /// POST pause. `detail` is copied onto the receiver's hold. Omit it for `app_background`.
    public mutating func pause(reason: String, detail: [String: String]? = nil) -> SingleFileClientTick {
        guard canPlacePause else {
            return fail(.wire(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false)))
        }
        placedLocalHold = true
        phase = .expectPause
        guard let request = pauseRequest(reason: reason, detail: detail) else {
            return fail(.wire(ProtocolError(code: .internal, httpStatus: 500, retryable: true)))
        }
        return tick(request, status: .inProgress, sent: offset)
    }

    /// POST resume. Removes only this sender's hold. A remaining receiver hold stays paused.
    public mutating func resume() -> SingleFileClientTick {
        guard canPlaceResume else {
            return fail(.wire(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false)))
        }
        phase = .expectResume
        guard let request = resumeRequest() else {
            return fail(.wire(ProtocolError(code: .internal, httpStatus: 500, retryable: true)))
        }
        return tick(request, status: .inProgress, sent: offset)
    }

    /// GET the session again after the receiver paused and this sender did not.
    public mutating func continueAfterPeer() -> SingleFileClientTick {
        guard phase == .paused, !placedLocalHold, let sessionID else {
            return fail(.wire(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false)))
        }
        phase = .expectPoll
        return tick(pollRequest(sessionID), status: .inProgress, sent: offset)
    }

    public mutating func receive(_ response: HTTPResponse) -> SingleFileClientTick {
        if response.status >= 400 {
            let error = WireApp.decodeError(response.body)
                ?? ProtocolError(code: .badRequest, httpStatus: response.status, retryable: false)
            if (phase == .expectPut || phase == .expectComplete), error.code == .sessionPaused {
                phase = .paused
                return tick(nil, status: .paused(committedBytes: offset), sent: offset)
            }
            if phase == .expectComplete, error.code == .checksumMismatch, checksumRetries == 0 {
                checksumRetries = 1
                offset = 0
                return nextPutTick()
            }
            phase = .terminal
            return fail(TransferHostErrorMapping.classify(error))
        }
        switch phase {
        case .expectHello:
            guard let hello = WireApp.decodeHello(response.body) else {
                return fail(.wire(ProtocolError(code: .badRequest, httpStatus: response.status, retryable: false)))
            }
            let check = TlsRecheckEngine.evaluate(
                deviceName: hello.alias ?? deviceName,
                ip: peerHost,
                txtAppRaw: txtAppRaw,
                txtAppPresent: txtAppPresent,
                tlsAppRaw: hello.app,
                tlsAppPresent: hello.appPresent,
                peerAddressIsLocal: peerAddressIsLocal,
                intent: intent,
                timestamp: timestamp,
                host: local
            )
            if let hostError = check.hostError {
                phase = .terminal
                return tick(nil, status: .failed(hostError), log: check.logEntry, sent: 0)
            }
            phase = .expectCreate
            return tick(createRequest(), status: .inProgress, log: check.logEntry, sent: 0)
        case .expectCreate:
            guard let object = JSONWire.object(response.body),
                  let sid = JSONWire.string(object, "sessionId") else {
                return fail(.wire(ProtocolError(code: .badRequest, httpStatus: response.status, retryable: false)))
            }
            sessionID = sid
            phase = .expectPoll
            return tick(pollRequest(sid), status: .inProgress, sent: 0)
        case .expectPoll:
            if response.status == 202, let sessionID {
                return tick(pollRequest(sessionID), status: .inProgress, sent: offset)
            }
            guard let object = JSONWire.object(response.body) else {
                return fail(.wire(ProtocolError(code: .badRequest, httpStatus: response.status, retryable: false)))
            }
            if let files = object["files"] as? [String: Any], let file = files[fileID] as? [String: Any] {
                if let token = JSONWire.string(file, "token") {
                    self.token = token
                }
                for key in ["offset", "committedBytes"] where file[key] != nil {
                    guard let next = JSONWire.int(file, key), (0...source.size).contains(next) else {
                        return invalidPeerResponse(status: response.status)
                    }
                }
                if let next = JSONWire.int(file, "offset") ?? JSONWire.int(file, "committedBytes") {
                    offset = next
                }
            }
            guard token != nil else {
                return fail(.wire(ProtocolError(code: .badRequest, httpStatus: response.status, retryable: false)))
            }
            let state = JSONWire.string(object, "state") ?? ""
            if state == "paused" {
                phase = .paused
                return tick(nil, status: .paused(committedBytes: offset), sent: offset)
            }
            if state == "expired" {
                return fail(.wire(ProtocolError(code: .sessionExpired, httpStatus: 410, retryable: false)))
            }
            return nextPutTick()
        case .expectPut:
            guard let object = JSONWire.object(response.body),
                  let committed = JSONWire.int(object, "committedBytes"),
                  (0...source.size).contains(committed), committed == expectedPutEnd else {
                return invalidPeerResponse(status: response.status)
            }
            offset = committed
            if offset < source.size {
                return nextPutTick()
            }
            phase = .expectComplete
            guard let request = completeRequest() else {
                return fail(.wire(ProtocolError(code: .internal, httpStatus: 500, retryable: true)))
            }
            return tick(request, status: .inProgress, sent: source.size)
        case .expectPause:
            guard let object = JSONWire.object(response.body) else {
                return fail(.wire(ProtocolError(code: .badRequest, httpStatus: response.status, retryable: false)))
            }
            if let files = object["files"] as? [String: Any],
               let file = files[fileID] as? [String: Any], file["committedBytes"] != nil {
                guard let committed = JSONWire.int(file, "committedBytes"),
                      (0...source.size).contains(committed) else {
                    return invalidPeerResponse(status: response.status)
                }
                offset = committed
            }
            if JSONWire.string(object, "state") == "paused" {
                phase = .paused
                return tick(nil, status: .paused(committedBytes: offset), sent: offset)
            }
            placedLocalHold = false
            return nextPutTick()
        case .expectResume:
            guard let object = JSONWire.object(response.body) else {
                return fail(.wire(ProtocolError(code: .badRequest, httpStatus: response.status, retryable: false)))
            }
            if let files = object["files"] as? [String: Any],
               let file = files[fileID] as? [String: Any], file["committedBytes"] != nil {
                guard let committed = JSONWire.int(file, "committedBytes"),
                      (0...source.size).contains(committed) else {
                    return invalidPeerResponse(status: response.status)
                }
                offset = committed
            }
            placedLocalHold = false
            if JSONWire.string(object, "state") == "paused" {
                phase = .paused
                return tick(nil, status: .paused(committedBytes: offset), sent: offset)
            }
            if JSONWire.string(object, "state") == "expired" {
                return fail(.wire(ProtocolError(code: .sessionExpired, httpStatus: 410, retryable: false)))
            }
            return nextPutTick()
        case .expectComplete:
            guard response.status == 200,
                  let object = JSONWire.object(response.body),
                  JSONWire.bool(object, "verified") == true,
                  let name = JSONWire.string(object, "finalName"), !name.isEmpty else {
                return invalidPeerResponse(status: response.status)
            }
            phase = .expectFinish
            guard let request = finishRequest() else {
                return fail(.wire(ProtocolError(code: .internal, httpStatus: 500, retryable: true)))
            }
            return tick(request, status: .inProgress, sent: source.size, finalNameHint: name)
        case .expectFinish:
            guard response.status == 200,
                  let object = JSONWire.object(response.body),
                  JSONWire.string(object, "sessionId") == sessionID,
                  JSONWire.string(object, "state") == "finished",
                  let files = object["files"] as? [[String: Any]], files.count == 1,
                  let file = files.first,
                  JSONWire.string(file, "id") == fileID,
                  JSONWire.string(file, "state") == "completed",
                  JSONWire.bool(file, "sha256Match") == true,
                  JSONWire.int(file, "size") == source.size,
                  JSONWire.int(file, "bytesReceived") == source.size,
                  let name = JSONWire.string(file, "finalName"), name == finalNameHint else {
                return invalidPeerResponse(status: response.status)
            }
            phase = .terminal
            return tick(nil, status: .completed(finalName: name), sent: source.size)
        case .paused:
            return tick(nil, status: .paused(committedBytes: offset), sent: offset)
        case .terminal:
            return tick(nil, status: .failed(.wire(ProtocolError(code: .invalidState, httpStatus: 409, retryable: false))), sent: offset)
        }
    }

    private var finalNameHint: String?

    private mutating func tick(
        _ request: HTTPRequest?,
        status: SingleFileClientStatus,
        log: AppMismatchLogEntry? = nil,
        sent: Int,
        finalNameHint: String? = nil
    ) -> SingleFileClientTick {
        if let finalNameHint {
            self.finalNameHint = finalNameHint
        }
        return SingleFileClientTick(
            request: request,
            status: status,
            logEntry: log,
            bytesSent: sent,
            bytesTotal: source.size
        )
    }

    private mutating func fail(_ error: TransferHostError) -> SingleFileClientTick {
        phase = .terminal
        return tick(nil, status: .failed(error), sent: offset)
    }

    private mutating func invalidPeerResponse(status: Int) -> SingleFileClientTick {
        fail(.wire(ProtocolError(code: .badRequest, httpStatus: status, retryable: false)))
    }

    private func helloRequest() -> HTTPRequest {
        WireApp.helloRequest(
            app: local.app,
            alias: localAlias,
            devType: localDevType,
            port: localPort,
            hostHeader: peerHost,
            bindingID: bindingID
        )
    }

    private func createRequest() -> HTTPRequest {
        let body = JSONWire.data([
            "clientSessionKey": clientSessionKey,
            "transport": "lan",
            "totalEntries": 1,
            "totalBytes": source.size,
            "entries": [[
                "id": fileID,
                "kind": "file",
                "relativePath": relativePath,
                "size": source.size,
            ]],
        ])
        return WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions",
            app: local.app,
            hostHeader: peerHost,
            body: body,
            json: true
        )
    }

    private func pollRequest(_ sid: String) -> HTTPRequest {
        WireApp.request(
            method: "GET",
            path: "/limlink/v1/sessions/\(sid)?wait=25",
            app: local.app,
            hostHeader: peerHost,
            body: [],
            json: false
        )
    }

    private mutating func nextPutTick() -> SingleFileClientTick {
        phase = .expectPut
        do {
            guard let request = try putRequest() else {
                return fail(.wire(ProtocolError(code: .internal, httpStatus: 500, retryable: true)))
            }
            return tick(request, status: .inProgress, sent: offset)
        } catch {
            return fail(.wire(ProtocolError(
                code: .internal, httpStatus: nil, retryable: false,
                detail: ["reason": "source_read_failed"]
            )))
        }
    }

    private mutating func putRequest() throws -> HTTPRequest? {
        guard let sessionID, let token, offset >= 0, offset <= source.size else { return nil }
        let count = min(FileTransferLimits.maximumChunkBytes, source.size - offset)
        let slice = try source.read(offset: offset, count: count)
        expectedPutEnd = offset + slice.count
        return WireApp.request(
            method: "PUT",
            path: "/limlink/v1/sessions/\(sessionID)/files/\(fileID)",
            app: local.app,
            hostHeader: peerHost,
            body: slice,
            json: false,
            extra: [
                "content-type": "application/octet-stream",
                "x-limlink-token": token,
                "x-limlink-offset": String(offset),
            ]
        )
    }

    private func completeRequest() -> HTTPRequest? {
        guard let sessionID else { return nil }
        return WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions/\(sessionID)/files/\(fileID)/complete",
            app: local.app,
            hostHeader: peerHost,
            body: JSONWire.data(["sha256": source.sha256Hex]),
            json: true
        )
    }

    private func pauseRequest(reason: String, detail: [String: String]?) -> HTTPRequest? {
        guard let sessionID else { return nil }
        var body: [String: Any] = [
            "sessionId": sessionID,
            "reason": reason,
        ]
        if let detail {
            body["detail"] = detail
        }
        return WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions/\(sessionID)/pause",
            app: local.app,
            hostHeader: peerHost,
            body: JSONWire.data(body),
            json: true
        )
    }

    private func resumeRequest() -> HTTPRequest? {
        guard let sessionID else { return nil }
        return WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions/\(sessionID)/resume",
            app: local.app,
            hostHeader: peerHost,
            body: JSONWire.data(["sessionId": sessionID]),
            json: true
        )
    }

    private func finishRequest() -> HTTPRequest? {
        guard let sessionID else { return nil }
        return WireApp.request(
            method: "POST",
            path: "/limlink/v1/sessions/\(sessionID)/finish",
            app: local.app,
            hostHeader: peerHost,
            body: [],
            json: true
        )
    }

    private enum Phase {
        case expectHello
        case expectCreate
        case expectPoll
        case expectPut
        case expectPause
        case expectResume
        case expectComplete
        case expectFinish
        case paused
        case terminal
    }
}
