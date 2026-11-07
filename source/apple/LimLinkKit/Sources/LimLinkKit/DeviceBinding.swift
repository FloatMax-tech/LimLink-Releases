import Foundation
import Security
import Darwin

public struct DeviceBindingRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { bindingID }
    public let ownFingerprint: String
    public let peerFingerprint: String
    public let bindingID: String
    public let alias: String
    public let deviceType: String
    public let boundAt: Date
    public init(ownFingerprint: String, peerFingerprint: String, bindingID: String, alias: String, deviceType: String, boundAt: Date = Date()) {
        self.ownFingerprint = ownFingerprint; self.peerFingerprint = peerFingerprint
        self.bindingID = bindingID; self.alias = alias; self.deviceType = deviceType; self.boundAt = boundAt
    }
}

public enum DeviceBindingFailure: Error, Sendable { case invalidRecord, unavailable, rejected, expired, invalidResponse }

/// Identity-scoped private file. Every mutation writes the replacement before changing memory.
public final class DeviceBindingStore: @unchecked Sendable {
    // A stopped runtime may still unwind a cancelled task while its replacement starts.
    // Serialize shared-file operations across store instances and read the current grant.
    private static let fileLock = NSLock()
    private let lock = NSLock()
    public let ownFingerprint: String
    private let url: URL
    private var records: [DeviceBindingRecord] = []
    private var available = true
    public init(url: URL, ownFingerprint: String) throws {
        guard Self.validFingerprint(ownFingerprint) else { throw DeviceBindingFailure.invalidRecord }
        self.url = url; self.ownFingerprint = ownFingerprint
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        records = try readRecords()
    }
    public var all: [DeviceBindingRecord] {
        lock.lock(); defer { lock.unlock() }
        guard available else { return [] }
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        do { records = try readRecords(); return records }
        catch { available = false; return [] }
    }
    public func record(for peer: String) -> DeviceBindingRecord? { all.first { $0.peerFingerprint == peer } }
    public func put(_ record: DeviceBindingRecord, isCurrent: () -> Bool = { true }) throws {
        lock.lock(); defer { lock.unlock() }
        guard available, Self.valid(record), record.ownFingerprint == ownFingerprint else { throw DeviceBindingFailure.invalidRecord }
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        do { records = try readRecords() } catch { available = false; throw error }
        guard isCurrent() else { throw CancellationError() }
        var next = records.filter { $0.peerFingerprint != record.peerFingerprint }; next.append(record)
        do { try save(next); records = next } catch { available = false; throw error }
    }
    public func remove(peer: String, bindingID: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        do { records = try readRecords() } catch { available = false; throw error }
        let next = records.filter { !($0.peerFingerprint == peer && (bindingID == nil || $0.bindingID == bindingID)) }
        guard next != records else { return }
        do { try save(next); records = next } catch { available = false; throw error }
    }
    private func readRecords() throws -> [DeviceBindingRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoded = try JSONDecoder().decode([DeviceBindingRecord].self, from: Data(contentsOf: url))
        guard decoded.allSatisfy({ Self.valid($0) }), Set(decoded.map(\.peerFingerprint)).count == decoded.count else { throw DeviceBindingFailure.invalidRecord }
        return decoded.filter { $0.ownFingerprint == ownFingerprint }
    }
    private func save(_ next: [DeviceBindingRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".binding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(next).write(to: temporary, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func validUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func validFingerprint(_ value: String) -> Bool { Fingerprint(base64URL: value)?.base64URL == value }
    static func validAlias(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 63 && value == value.precomposedStringWithCanonicalMapping && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static let types: Set<String> = ["iphone", "ipad", "mac", "windows", "android"]
    private static func valid(_ r: DeviceBindingRecord) -> Bool {
        validUUID(r.bindingID) && validFingerprint(r.ownFingerprint) && validFingerprint(r.peerFingerprint) && r.ownFingerprint != r.peerFingerprint && validAlias(r.alias) && types.contains(r.deviceType)
    }
}

public struct IncomingDeviceBinding: Equatable, Sendable, Identifiable {
    public let id: String
    public let alias: String
    public let deviceType: String
    public let fingerprint: String
}

/// Serialized pairing control, separate from the file receiver lock and permission list.
public final class DeviceBindingController: @unchecked Sendable {
    private let lock = NSLock()
    public let store: DeviceBindingStore
    private let alias: String
    private let deviceType: String
    private let now: @Sendable () -> TimeInterval
    private var starts: [TimeInterval] = []
    private var outgoing = false
    private var attempt: Attempt?
    public var onChange: (@Sendable (IncomingDeviceBinding?) -> Void)?
    private struct Attempt {
        var owner: String; var connection: String; var requestID: String; var pairID: String; var token: String
        var alias: String; var deviceType: String; var deadline: TimeInterval; var state = "pending"
    }
    public init(store: DeviceBindingStore, alias: String, deviceType: String, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.alias = alias; self.deviceType = deviceType; self.now = now
    }
    public var pending: IncomingDeviceBinding? {
        lock.lock(); defer { lock.unlock() }
        guard let a = attempt, a.state == "pending", now() < a.deadline else { return nil }
        return IncomingDeviceBinding(id: a.pairID, alias: a.alias, deviceType: a.deviceType, fingerprint: a.owner)
    }
    public func decide(pairID: String, accept: Bool) {
        lock.lock()
        if var a = attempt, a.pairID == pairID, a.state == "pending", now() < a.deadline { a.state = accept ? "accepted" : "rejected"; attempt = a }
        lock.unlock(); onChange?(nil)
    }
    public func disconnect(_ connectionID: String) {
        lock.lock()
        if var a = attempt, a.connection == connectionID, ["pending", "accepted"].contains(a.state) { a.state = "cancelled"; attempt = a }
        lock.unlock(); onChange?(pending)
    }
    public func beginOutgoing() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !outgoing else { return false }
        if let a = attempt, now() < a.deadline, ["pending", "accepted"].contains(a.state) { return false }
        outgoing = true
        return true
    }
    public func endOutgoing() { lock.lock(); outgoing = false; lock.unlock() }
    public func stop() { lock.lock(); outgoing = false; attempt = nil; lock.unlock(); onChange?(nil) }
    public func permits(peer: String, bindingID: String?) -> Bool {
        guard let bindingID, let record = store.record(for: peer) else { return false }
        return record.bindingID == bindingID && record.ownFingerprint == store.ownFingerprint
    }
    public func unbind(_ record: DeviceBindingRecord) throws {
        lock.lock()
        defer { lock.unlock(); onChange?(pending) }
        // Local unbind revokes the user's consent for this peer, including a
        // replacement handshake that has not completed yet. Remote revoke stays
        // scoped to its exact binding ID to prevent stale requests cancelling a new grant.
        if var a = attempt, a.owner == record.peerFingerprint,
           a.pairID == record.bindingID || ["pending", "accepted"].contains(a.state) {
            a.state = "cancelled"; attempt = a
        }
        // The visible row may lag behind a replacement that already completed.
        // This local gesture removes the device's current grant, regardless of ID.
        try store.remove(peer: record.peerFingerprint)
    }
    public func handle(_ request: HTTPRequest, fingerprint: String, connectionID: String) -> HTTPResponse {
        lock.lock()
        let response = handleLocked(request, fingerprint: fingerprint, connectionID: connectionID)
        lock.unlock()
        onChange?(pending)
        return response
    }
    static func error(_ code: String, _ status: Int) -> HTTPResponse { json(status, ["code": code, "retryable": false]) }
    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse { HTTPResponse(status: status, headers: ["content-type": "application/json"], body: JSONWire.data(object)) }
    private func handleLocked(_ request: HTTPRequest, fingerprint: String, connectionID: String) -> HTTPResponse {
        guard request.body.count <= 16_384, request.value(for: "host")?.isEmpty == false else { return Self.error("E_BAD_REQUEST", 400) }
        guard request.value(for: LimLinkProtocol.appHeader) == "limlink" else { return Self.error("E_APP_MISMATCH", 403) }
        guard DeviceBindingStore.validFingerprint(fingerprint), fingerprint != store.ownFingerprint else { return Self.error("E_BAD_REQUEST", 400) }
        let path = request.target.split(separator: "?").first.map(String.init) ?? ""
        let parts = path.split(separator: "/")
        if request.method == "POST", path == "/limlink/v1/pair/start" {
            guard let body = JSONWire.object(request.body) else { return Self.error("E_BAD_REQUEST", 400) }
            guard JSONWire.int(body, "version") == 1 else { return Self.error("E_PAIR_VERSION", 400) }
            guard let requestID = JSONWire.string(body, "requestId"), DeviceBindingStore.validUUID(requestID), let peerAlias = JSONWire.string(body, "alias"), DeviceBindingStore.validAlias(peerAlias), let type = JSONWire.string(body, "deviceType"), DeviceBindingStore.types.contains(type) else { return Self.error("E_BAD_REQUEST", 400) }
            if let a = attempt, now() < a.deadline, ["pending", "accepted"].contains(a.state) {
                guard a.owner == fingerprint, a.connection == connectionID, a.requestID == requestID else { return Self.error("E_PAIR_BUSY", 409) }
                return startResponse(a)
            }
            guard !outgoing else { return Self.error("E_PAIR_BUSY", 409) }
            starts.removeAll { now() - $0 >= 60 }
            guard starts.count < 3 else { return Self.error("E_PAIR_RATE_LIMITED", 429) }
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { return Self.error("E_PAIR_STORAGE_FAILED", 500) }
            let a = Attempt(owner: fingerprint, connection: connectionID, requestID: requestID, pairID: UUID().uuidString.lowercased(), token: OpaqueToken.encode(random), alias: peerAlias, deviceType: type, deadline: now() + 120)
            starts.append(now()); attempt = a
            return startResponse(a)
        }
        guard parts.count >= 4, DeviceBindingStore.validUUID(String(parts[3])) else { return Self.error("E_BAD_REQUEST", 400) }
        let id = String(parts[3])
        if request.method == "POST", parts.count == 5, parts[4] == "revoke" {
            guard request.body == Array("{}".utf8) || JSONWire.object(request.body)?.isEmpty == true else { return Self.error("E_BAD_REQUEST", 400) }
            do {
                try store.remove(peer: fingerprint, bindingID: id)
                if var a = attempt, a.owner == fingerprint, a.pairID == id { a.state = "cancelled"; attempt = a }
                return Self.json(200, ["state": "revoked"])
            } catch { return Self.error("E_PAIR_STORAGE_FAILED", 500) }
        }
        guard var a = attempt, a.pairID == id else { return Self.error("E_PAIR_EXPIRED", 410) }
        guard a.owner == fingerprint, a.connection == connectionID, let token = request.value(for: "X-LimLink-Pair-Token"), constantTimeEqual(token, a.token) else { return Self.error("E_PAIR_TOKEN_INVALID", 403) }
        guard now() < a.deadline else { a.state = "expired"; attempt = a; return Self.error("E_PAIR_EXPIRED", 410) }
        if request.method == "GET", parts.count == 4 { return stateResponse(a) }
        guard request.method == "POST", parts.count == 5, JSONWire.object(request.body)?.isEmpty == true else { return Self.error("E_BAD_REQUEST", 400) }
        if parts[4] == "cancel" {
            do { try store.remove(peer: a.owner, bindingID: a.pairID); a.state = "cancelled"; attempt = a; return Self.json(200, ["state": "cancelled"]) }
            catch { a.state = "failed"; attempt = a; return Self.error("E_PAIR_STORAGE_FAILED", 500) }
        }
        guard parts[4] == "complete" else { return Self.error("E_BAD_REQUEST", 400) }
        if a.state == "completed", store.record(for: a.owner)?.bindingID == a.pairID { return stateResponse(a) }
        guard a.state == "accepted" else { return Self.error("E_PAIR_NOT_ACCEPTED", 409) }
        do {
            try store.put(DeviceBindingRecord(ownFingerprint: store.ownFingerprint, peerFingerprint: a.owner, bindingID: a.pairID, alias: a.alias, deviceType: a.deviceType))
            a.state = "completed"; attempt = a; return stateResponse(a)
        } catch { a.state = "failed"; attempt = a; return Self.error("E_PAIR_STORAGE_FAILED", 500) }
    }
    private func startResponse(_ a: Attempt) -> HTTPResponse { Self.json(202, ["version": 1, "pairId": a.pairID, "token": a.token, "state": a.state, "expiresInSeconds": max(0, Int(ceil(a.deadline - now()))), "alias": alias, "deviceType": deviceType]) }
    private func stateResponse(_ a: Attempt) -> HTTPResponse { Self.json(200, ["version": 1, "pairId": a.pairID, "state": a.state, "expiresInSeconds": max(0, Int(ceil(a.deadline - now())))]) }
    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

/// A dedicated, already pinned mTLS connection. Bind itself is the initiator consent.
public enum DeviceBindingClient {
    public static func bind(connection: LimLinkConnection, selectedFingerprint: String, store: DeviceBindingStore, alias: String, deviceType: String) async throws -> DeviceBindingRecord {
        try await withTimeout(.seconds(120)) {
            try await bindWithinDeadline(connection: connection, selectedFingerprint: selectedFingerprint, store: store, alias: alias, deviceType: deviceType)
        }
    }
    private static func bindWithinDeadline(connection: LimLinkConnection, selectedFingerprint: String, store: DeviceBindingStore, alias: String, deviceType: String) async throws -> DeviceBindingRecord {
        guard connection.peerFingerprint.base64URL == selectedFingerprint,
              selectedFingerprint != store.ownFingerprint else { throw DeviceBindingFailure.invalidResponse }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        let start = try await exchange(connection, method: "POST", route: "start", body: ["version": 1, "requestId": UUID().uuidString.lowercased(), "alias": alias, "deviceType": deviceType])
        guard start.status == 202, let body = JSONWire.object(start.body), JSONWire.int(body, "version") == 1,
              JSONWire.string(body, "state") == "pending",
              let id = JSONWire.string(body, "pairId"), DeviceBindingStore.validUUID(id),
              let token = JSONWire.string(body, "token"), token.count == 43, Fingerprint(base64URL: token)?.base64URL == token,
              let remoteAlias = JSONWire.string(body, "alias"), DeviceBindingStore.validAlias(remoteAlias),
              let remoteType = JSONWire.string(body, "deviceType"), DeviceBindingStore.types.contains(remoteType) else { throw DeviceBindingFailure.invalidResponse }
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
                let response = try await exchange(connection, method: "GET", route: id, token: token)
                guard response.status == 200, let object = JSONWire.object(response.body), JSONWire.string(object, "pairId") == id,
                      JSONWire.int(object, "version") == 1, let state = JSONWire.string(object, "state") else { throw DeviceBindingFailure.invalidResponse }
                if state == "pending" { continue }
                guard state == "accepted" else { throw DeviceBindingFailure.rejected }
                let complete = try await exchange(connection, method: "POST", route: id + "/complete", token: token)
                guard complete.status == 200, let completed = JSONWire.object(complete.body), JSONWire.string(completed, "pairId") == id,
                      JSONWire.int(completed, "version") == 1, JSONWire.string(completed, "state") == "completed" else { throw DeviceBindingFailure.invalidResponse }
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw DeviceBindingFailure.expired }
                let record = DeviceBindingRecord(ownFingerprint: store.ownFingerprint, peerFingerprint: selectedFingerprint, bindingID: id, alias: remoteAlias, deviceType: remoteType)
                try store.put(record, isCurrent: { !Task.isCancelled })
                // Cancellation after persistence must clear the exact local grant.
                if Task.isCancelled { try store.remove(peer: selectedFingerprint, bindingID: id); throw CancellationError() }
                return record
            }
            throw DeviceBindingFailure.expired
        } catch {
            _ = try? await exchange(connection, method: "POST", route: id + "/cancel", token: token)
            throw error
        }
    }
    public static func revoke(connection: LimLinkConnection, record: DeviceBindingRecord) async throws {
        guard connection.peerFingerprint.base64URL == record.peerFingerprint else { throw DeviceBindingFailure.invalidResponse }
        let response = try await exchange(connection, method: "POST", route: record.bindingID + "/revoke")
        guard response.status == 200 else { throw DeviceBindingFailure.invalidResponse }
    }
    private static func exchange(_ connection: LimLinkConnection, method: String, route: String, token: String? = nil, body: [String: Any] = [:]) async throws -> HTTPResponse {
        var headers = ["host": "limlink", "X-LimLink-App": "limlink", "content-type": "application/json"]
        headers["X-LimLink-Pair-Token"] = token
        return try await FramedExchange.transact(connection, HTTPRequest(method: method, target: "/limlink/v1/pair/" + route, headers: headers, body: method == "GET" ? [] : JSONWire.data(body)), responseLimits: HTTPResponseLimits(maximumHeaderBytes: 16_384, maximumBodyBytes: 16_384), idleTimeout: .seconds(10))
    }
}
