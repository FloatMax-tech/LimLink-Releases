import Foundation
import Security

/// HTTP/1.1 frames over an already-open mutual TLS connection.
public enum FramedExchange {
    public static func transact(
        _ connection: LimLinkConnection,
        _ request: HTTPRequest,
        responseLimits: HTTPResponseLimits = .unlimited,
        idleTimeout: Duration? = nil
    ) async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            let watchdog = idleTimeout.map { duration in
                ReceiveIdleWatchdog(timeout: duration) { connection.cancel() }
            }
            defer { watchdog?.stop() }
            try Task.checkCancellation()
            try await connection.send(HTTPCodec.encode(request))
        } onCancel: {
            connection.cancel()
        }
        var buffer: [UInt8] = []
        return try await readResponse(connection, buffer: &buffer, limits: responseLimits, idleTimeout: idleTimeout)
    }

    public static func readRequest(
        _ connection: LimLinkConnection,
        buffer: inout [UInt8],
        limits: HTTPRequestLimits = .unlimited,
        idleTimeout: Duration? = nil
    ) async throws -> HTTPRequest {
        try await withTaskCancellationHandler {
            let watchdog = idleTimeout.map { duration in
                ReceiveIdleWatchdog(timeout: duration) { connection.cancel() }
            }
            defer { watchdog?.stop() }
            while true {
                do {
                    let (request, consumed) = try HTTPCodec.parseRequest(buffer, limits: limits)
                    buffer.removeFirst(consumed)
                    return request
                } catch HTTPCodecError.incomplete {
                    let more = try await connection.receive()
                    if more.isEmpty { throw TransportFailure.cancelled }
                    watchdog?.reset()
                    buffer.append(contentsOf: more)
                }
            }
        } onCancel: {
            // NWConnection.receive does not otherwise wake when its Swift task is cancelled.
            connection.cancel()
        }
    }

    public static func readResponse(
        _ connection: LimLinkConnection,
        buffer: inout [UInt8],
        limits: HTTPResponseLimits = .unlimited,
        idleTimeout: Duration? = nil
    ) async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            let watchdog = idleTimeout.map { duration in
                ReceiveIdleWatchdog(timeout: duration) { connection.cancel() }
            }
            defer { watchdog?.stop() }
            while true {
                try Task.checkCancellation()
                do {
                    let (response, consumed) = try HTTPCodec.parseResponse(buffer, limits: limits)
                    buffer.removeFirst(consumed)
                    return response
                } catch HTTPCodecError.incomplete {
                    let more = try await connection.receive()
                    if more.isEmpty { throw TransportFailure.cancelled }
                    watchdog?.reset()
                    buffer.append(contentsOf: more)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

public struct PendingSession: Equatable, Sendable {
    public var sessionID: String
    public var fingerprint: String
    /// Validated receiver landing name, when this pending session represents a file.
    public var fileName: String?
    /// Exact declared file length in bytes. Nil means the metadata is unavailable.
    public var size: Int?
    /// Claimed display name from the creating TLS connection's hello, never a discovery-name lookup.
    public var senderName: String?
    public var bindingID: String?

    public init(sessionID: String, fingerprint: String, fileName: String? = nil, size: Int? = nil, senderName: String? = nil, bindingID: String? = nil) {
        self.sessionID = sessionID
        self.fingerprint = fingerprint
        self.fileName = fileName
        self.size = size
        self.senderName = senderName
        self.bindingID = bindingID
    }
}

/// A SHA-256-verified file completed by this serving TLS connection.
public struct PublishedFile: Equatable, Sendable {
    public var sessionID: String
    public var fingerprint: String
    public var fileName: String
    public var size: Int
    public var bytes: [UInt8]
    /// Verified private staging file. Disk-backed receive leaves `bytes` empty.
    public var fileURL: URL?

    public init(sessionID: String, fingerprint: String, fileName: String, size: Int, bytes: [UInt8], fileURL: URL? = nil) {
        self.sessionID = sessionID
        self.fingerprint = fingerprint
        self.fileName = fileName
        self.size = size
        self.bytes = bytes
        self.fileURL = fileURL
    }
}

/// Receives one file at a time on connections the listener has already accepted.
/// A pending session stays pending until the host calls `decide`. The Kit does not trust a fingerprint or accept a file on its own.
public final class SingleFileService: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: SingleFileReceiver
    private var announced: Set<String> = []
    private var connectionAliases: [String: String] = [:]
    private var connectionBindings: [String: String] = [:]
    public let deviceBinding: DeviceBindingController?
    private let bindingApp: String
    private var sessionSenderNames: [String: String] = [:]
    private let onPending: @Sendable (PendingSession) -> Void
    private let onDiagnostic: @Sendable (DiagnosticNote) -> Void
    private let onPublished: @Sendable (String, [UInt8]) -> Void
    private let saveLocation: URL?
    private let receivesToDisk: Bool
    private var lifecycleID: UUID?
    private var lifecycleRevision: UInt64 = 0

    private struct LifecycleSnapshot {
        var active: Set<String>
        var revision: UInt64
    }

    public init(
        configuration: LimLinkConfiguration,
        trustedFingerprints: Set<String> = [],
        maximumRetainedSessions: Int? = nil,
        deviceBinding: DeviceBindingController? = nil,
        receiveDirectory: URL? = nil,
        maximumFileBytes: Int? = nil,
        onPending: @escaping @Sendable (PendingSession) -> Void = { _ in },
        onDiagnostic: @escaping @Sendable (DiagnosticNote) -> Void = { _ in },
        onPublished: @escaping @Sendable (String, [UInt8]) -> Void = { _, _ in }
    ) {
        self.deviceBinding = deviceBinding
        self.bindingApp = configuration.hostApp.app
        self.receiver = SingleFileReceiver(
            host: configuration.hostApp,
            alias: configuration.deviceName,
            devType: configuration.deviceType.rawValue,
            port: Int(LimLinkProtocol.primaryPort),
            trustedFingerprints: trustedFingerprints,
            sessionIDs: [],
            tokens: [],
            now: DiagnosticTimestamps.format(Date()),
            maximumRetainedSessions: receiveDirectory == nil ? maximumRetainedSessions : min(maximumRetainedSessions ?? 4, 4),
            storageDirectory: receiveDirectory,
            maximumFileBytes: maximumFileBytes
        )
        self.onPending = onPending
        self.onDiagnostic = onDiagnostic
        self.onPublished = onPublished
        self.saveLocation = configuration.saveLocation
        self.receivesToDisk = receiveDirectory != nil
        self.lifecycleID = nil
        self.lifecycleID = LifecycleObserver.shared.addReceiver { [weak self] directive in
            self?.applyLifecycle(directive)
        }
        LifecycleObserver.shared.adopt(configuration)
    }

    deinit {
        if let lifecycleID {
            LifecycleObserver.shared.removeReceiver(lifecycleID)
        }
    }

    /// Host trust decision. Without this, transfer routes return `401 E_NOT_PAIRED`.
    public func trust(_ fingerprint: String) {
        lock.lock()
        receiver.trustedFingerprints.insert(fingerprint)
        lock.unlock()
    }

    /// Host decision for a session that `onPending` reported. The Kit does not call this itself.
    @discardableResult
    public func decide(sessionID: String, accept: Bool) -> Bool {
        lock.lock()
        let changed = receiver.decide(sessionID: sessionID, accept: accept)
        let snapshot = lifecycleSnapshotLocked()
        lock.unlock()
        updateLifecycle(snapshot)
        return changed
    }

    /// Explicitly releases a session's memory and idempotency key. Its resumption then becomes unavailable.
    @discardableResult
    public func discardSession(sessionID: String) -> Bool {
        discardSessions([sessionID])
    }

    /// Per-connection callbacks replace the constructor callbacks only for this call.
    /// A publication override saves the verified bytes or moves `fileURL`, then returns its exact safe basename before the success reply.
    /// Disk-backed receive requires the URL-aware publication override.
    /// Disconnect cleanup opts out of resumption only for sessions created by this connection.
    public func serve(
        _ connection: LimLinkConnection,
        requestLimits: HTTPRequestLimits = .unlimited,
        idleTimeout: Duration? = nil,
        discardSessionsOnDisconnect: Bool = false,
        onPending pendingOverride: (@Sendable (PendingSession) -> Void)? = nil,
        onPublished publicationOverride: (@Sendable (PublishedFile) async throws -> String)? = nil
    ) async {
        var buffer: [UInt8] = []
        var createdSessionIDs: Set<String> = []
        var pairingConnection: Bool?
        var enforcedLimits = requestLimits
        let pairingPrefix = "/limlink/v1/pair/"
        enforcedLimits.maximumBodyBytesByPathPrefix[pairingPrefix] = min(16_384, enforcedLimits.maximumBodyBytesByPathPrefix[pairingPrefix] ?? 16_384)
        let connectionID = UUID().uuidString
        let connectionScope = discardSessionsOnDisconnect ? connectionID : nil
        defer {
            forgetConnectionAlias(connectionID)
            deviceBinding?.disconnect(connectionID)
            if discardSessionsOnDisconnect {
                discardSessions(createdSessionIDs)
            }
        }
        let localAddresses = InterfaceAddresses.current()
        let peerIsLocal = connection.remoteHost.map {
            LocalAddressMatch.isLocal($0, interfaceAddresses: localAddresses)
        } ?? false
        let fingerprint = connection.peerFingerprint.base64URL
        while !Task.isCancelled {
            do {
                let request = try await FramedExchange.readRequest(connection, buffer: &buffer, limits: enforcedLimits, idleTimeout: idleTimeout)
                let isPairing = request.target.hasPrefix("/limlink/v1/pair/")
                if let mode = pairingConnection, mode != isPairing {
                    try await connection.send(HTTPCodec.encode(DeviceBindingController.error("E_BAD_REQUEST", 400)))
                    connection.cancel()
                    return
                }
                pairingConnection = isPairing
                let outcome = step(request, peerIsLocal: peerIsLocal, fingerprint: fingerprint, connectionScope: connectionScope, deferPublication: publicationOverride != nil || receivesToDisk, connectionID: connectionID)
                createdSessionIDs.formUnion(outcome.createdSessionIDs)
                syncLifecycle()
                persistPartials()
                if let pending = outcome.pending {
                    (pendingOverride ?? onPending)(pending)
                }
                syncLifecycle()
                var response = responseAfterHost(outcome)
                for file in outcome.published {
                    if let publicationOverride {
                        do {
                            response = try await completePublication(file, using: publicationOverride)
                        } catch {
                            let failure = WireApp.errorResponse(ProtocolError(code: .writeFailed, httpStatus: 500, retryable: true))
                            try? await connection.send(HTTPCodec.encode(failure))
                            connection.cancel()
                            return
                        }
                    } else {
                        guard file.fileURL == nil else {
                            discardSession(sessionID: file.sessionID)
                            let failure = WireApp.errorResponse(ProtocolError(code: .writeFailed, httpStatus: 500, retryable: false))
                            try? await connection.send(HTTPCodec.encode(failure))
                            connection.cancel()
                            return
                        }
                        copyVerified(file, name: file.fileName)
                        let publish = onPublished
                        DispatchQueue.main.async { publish(file.fileName, file.bytes) }
                    }
                }
                try await connection.send(HTTPCodec.encode(response))
                for note in outcome.notes {
                    onDiagnostic(note)
                }
            } catch {
                connection.cancel()
                return
            }
        }
        connection.cancel()
    }

    struct ServiceStep {
        var response: HTTPResponse
        var pending: PendingSession?
        var notes: [DiagnosticNote]
        var published: [PublishedFile]
        var createdSessionIDs: Set<String>
    }

    func step(_ request: HTTPRequest, peerIsLocal: Bool, fingerprint: String, connectionScope: String? = nil, deferPublication: Bool = false, connectionID: String? = nil) -> ServiceStep {
        if request.target.hasPrefix("/limlink/v1/pair/") {
            let response: HTTPResponse
            if bindingApp != "limlink" || request.value(for: LimLinkProtocol.appHeader) != "limlink" {
                response = DeviceBindingController.error("E_APP_MISMATCH", 403)
            } else if let deviceBinding {
                response = deviceBinding.handle(request, fingerprint: fingerprint, connectionID: connectionID ?? connectionScope ?? "")
            } else if request.target == "/limlink/v1/pair/start", let body = JSONWire.object(request.body), JSONWire.int(body, "version") != 1 {
                response = DeviceBindingController.error("E_PAIR_VERSION", 400)
            } else { response = DeviceBindingController.error("E_PAIR_STORAGE_FAILED", 500) }
            return ServiceStep(response: response, pending: nil, notes: [], published: [], createdSessionIDs: [])
        }
        lock.lock()
        defer { lock.unlock() }
        let aliasKey = connectionID ?? connectionScope
        let isBindingApp = bindingApp == "limlink" && request.value(for: LimLinkProtocol.appHeader) == "limlink"
        if let aliasKey, request.method == "POST", request.target.split(separator: "?").first == "/limlink/v1/hello" {
            let object = (try? JSONSerialization.jsonObject(with: Data(request.body))) as? [String: Any]
            if isBindingApp, object?["app"] as? String == "limlink", let bindingID = object?["bindingId"] as? String, DeviceBindingStore.validUUID(bindingID) { connectionBindings[aliasKey] = bindingID }
            else { connectionBindings.removeValue(forKey: aliasKey) }
            let claimed = object?["alias"] as? String
            let trimmed = claimed?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty, trimmed.count <= 128,
               !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                connectionAliases[aliasKey] = trimmed
            } else {
                connectionAliases.removeValue(forKey: aliasKey)
            }
        }
        if receiver.sessionIDs.count < 4 {
            receiver.sessionIDs.append(contentsOf: (0..<4).map { _ in OpaqueToken.encode(randomBytes(16)) })
        }
        if receiver.tokens.count < 4 {
            receiver.tokens.append(contentsOf: (0..<4).map { _ in OpaqueToken.encode(randomBytes(16)) })
        }
        receiver.advanceClock(to: Date())
        let noted = receiver.diagnostics.count
        let previousSessionIDs = Set(receiver.sessions.keys)
        let outcome = receiver.handle(
            request,
            peerAddressIsLocal: peerIsLocal,
            clientFingerprint: fingerprint,
            connectionScope: connectionScope,
            deferPublication: deferPublication
        )
        let notes = Array(receiver.diagnostics.dropFirst(noted))
        let response: HTTPResponse
        let pending: PendingSession?
        switch outcome {
        case .response(let value):
            if request.target == "/limlink/v1/hello", isBindingApp,
               JSONWire.string(JSONWire.object(request.body) ?? [:], "app") == "limlink", var object = JSONWire.object(value.body) {
                if let record = deviceBinding?.store.record(for: fingerprint) { object["bindingId"] = record.bindingID }
                object["caps"] = ["binding-v1"]
                response = HTTPResponse(status: value.status, headers: value.headers, body: JSONWire.data(object))
            } else { response = value }
            pending = nil
        case .awaitDecision(let sessionID):
            // Leave the session pending. The host calls `decide`.
            response = receiver.pollResponse(sessionID: sessionID)
            let session = receiver.sessions[sessionID]
            pending = PendingSession(
                sessionID: sessionID,
                fingerprint: fingerprint,
                fileName: session?.finalName,
                size: session?.size,
                senderName: sessionSenderNames[sessionID],
                bindingID: isBindingApp ? aliasKey.flatMap { connectionBindings[$0] } : nil
            )
        }
        let createdSessionIDs = Set(receiver.sessions.keys).subtracting(previousSessionIDs)
        if let aliasKey, let senderName = connectionAliases[aliasKey] {
            for id in createdSessionIDs { sessionSenderNames[id] = senderName }
        }
        var published: [PublishedFile] = []
        for (id, session) in receiver.sessions {
            guard receiver.ownsSession(sessionID: id, clientFingerprint: fingerprint, connectionScope: connectionScope),
                  session.published != nil || session.publishedFileURL != nil,
                  announced.insert(id).inserted else { continue }
            published.append(PublishedFile(sessionID: id, fingerprint: fingerprint, fileName: session.finalName, size: session.size, bytes: session.published ?? [], fileURL: session.publishedFileURL))
        }
        return ServiceStep(response: response, pending: pending, notes: notes, published: published, createdSessionIDs: createdSessionIDs)
    }

    private func copyVerified(_ file: PublishedFile, name: String) {
        guard file.fileURL == nil else { return }
        let save = saveLocation
        DispatchQueue.global(qos: .utility).async {
            PartialFileMaintenance.copyVerifiedIfNeeded(fileName: name, bytes: file.bytes, saveLocation: save)
        }
    }

    func completePublication(_ file: PublishedFile, using publish: @Sendable (PublishedFile) async throws -> String) async throws -> HTTPResponse {
        do {
            let savedName = try await publish(file)
            let response = try recordPublishedName(file, savedName: savedName)
            copyVerified(file, name: savedName)
            return response
        } catch {
            // Clear verified state before another resumable connection can observe a successful finish.
            discardSession(sessionID: file.sessionID)
            throw error
        }
    }

    private func recordPublishedName(_ file: PublishedFile, savedName: String) throws -> HTTPResponse {
        lock.lock()
        let valid = receiver.updatePublishedFileName(sessionID: file.sessionID, fileName: savedName)
        lock.unlock()
        guard valid else { throw PublicationFailure.invalidSavedName }
        let body = try JSONSerialization.data(withJSONObject: ["verified": true, "finalName": savedName], options: [.sortedKeys])
        return HTTPResponse(status: 200, body: Array(body))
    }

    @discardableResult
    private func discardSessions(_ sessionIDs: Set<String>) -> Bool {
        lock.lock()
        var changed = false
        var removals: [PartialSyncItem] = []
        for id in sessionIDs {
            guard let session = receiver.sessions[id] else { continue }
            if !session.isDiskBacked {
                removals.append(PartialSyncItem(id: "\(id)-\(session.fileID)", bytes: [], activity: .transferring, since: nil, lastWrite: receiver.clock, remove: true))
            }
            changed = receiver.discardSession(sessionID: id) || changed
            announced.remove(id)
            sessionSenderNames.removeValue(forKey: id)
        }
        let snapshot = lifecycleSnapshotLocked()
        if !removals.isEmpty { PartialFileMaintenance.enqueue(removals, saveLocation: saveLocation) }
        lock.unlock()
        updateLifecycle(snapshot)
        return changed
    }

    private func forgetConnectionAlias(_ connectionID: String) {
        lock.lock()
        connectionAliases.removeValue(forKey: connectionID)
        connectionBindings.removeValue(forKey: connectionID)
        lock.unlock()
    }

    private enum PublicationFailure: Error { case invalidSavedName }

    /// Re-reads a pending poll after the host's `decide`. The Kit still does not accept on its own.
    private func responseAfterHost(_ outcome: ServiceStep) -> HTTPResponse {
        guard let pending = outcome.pending else { return outcome.response }
        lock.lock()
        let response = receiver.pollResponse(sessionID: pending.sessionID)
        lock.unlock()
        return response
    }

    private func applyLifecycle(_ directive: LifecycleDirective) {
        lock.lock()
        receiver.advanceClock(to: Date())
        receiver.apply(directive)
        lock.unlock()
        persistPartials()
    }

    private func persistPartials() {
        lock.lock()
        let items = partialItemsLocked()
        if !items.isEmpty { PartialFileMaintenance.enqueue(items, saveLocation: saveLocation) }
        lock.unlock()
    }

    private func partialItemsLocked() -> [PartialSyncItem] {
        receiver.sessions.compactMap { id, session in
            guard !session.isDiskBacked else { return nil }
            let partialID = "\(id)-\(session.fileID)"
            switch session.phase {
            case .accepted:
                let activity: PartialActivity = session.disconnectedSince == nil ? .transferring : .disconnected
                return PartialSyncItem(
                    id: partialID,
                    bytes: session.halfFile,
                    activity: activity,
                    since: session.disconnectedSince,
                    lastWrite: receiver.clock,
                    remove: session.halfFile.isEmpty
                )
            case .paused, .expired:
                return PartialSyncItem(
                    id: partialID,
                    bytes: session.halfFile,
                    activity: .paused,
                    since: session.pausedSince,
                    lastWrite: receiver.clock,
                    remove: false
                )
            case .pending, .completed, .verifyFailed, .rejected, .cancelled:
                return PartialSyncItem(
                    id: partialID,
                    bytes: [],
                    activity: .transferring,
                    since: nil,
                    lastWrite: receiver.clock,
                    remove: true
                )
            }
        }
    }

    private func syncLifecycle() {
        lock.lock()
        let snapshot = lifecycleSnapshotLocked()
        lock.unlock()
        updateLifecycle(snapshot)
    }

    private func lifecycleSnapshotLocked() -> LifecycleSnapshot {
        lifecycleRevision += 1
        return LifecycleSnapshot(active: activeSessionIDs(), revision: lifecycleRevision)
    }

    private func updateLifecycle(_ snapshot: LifecycleSnapshot) {
        if let lifecycleID {
            LifecycleObserver.shared.setReceiverSessions(snapshot.active, receiverID: lifecycleID, revision: snapshot.revision)
        }
    }

    private func activeSessionIDs() -> Set<String> {
        Set(receiver.sessions.compactMap { id, session in
            switch session.phase {
            case .accepted, .paused:
                return id
            case .pending, .expired, .completed, .verifyFailed, .rejected, .cancelled:
                return nil
            }
        })
    }

    private func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max)
            }
        }
        return bytes
    }
}

/// Restarts the deadline on incoming progress and invokes cancellation at most once.
final class ReceiveIdleWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: Duration
    private let onTimeout: @Sendable () -> Void
    private var generation = 0
    private var stopped = false
    private var timer: Task<Void, Never>?

    init(timeout: Duration, onTimeout: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onTimeout = onTimeout
        reset()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        generation += 1
        let current = generation
        timer?.cancel()
        timer = Task { [weak self, timeout] in
            do {
                try await Task.sleep(for: timeout)
                self?.fire(generation: current)
            } catch { }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    private func fire(generation current: Int) {
        lock.lock()
        guard !stopped, current == generation else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        onTimeout()
    }
}
