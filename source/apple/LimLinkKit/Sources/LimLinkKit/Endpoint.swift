import Foundation
@preconcurrency import Network
@preconcurrency import Security

public struct BonjourAdvertisement: Sendable, Equatable {
    public var instanceName: String

    public init(instanceName: String) {
        self.instanceName = instanceName
    }
}

/// Reads `NWParameters.allowFastOpen` before LimLink forces it off.
public enum TLSParametersProbe {
    public static func allowFastOpenDefault() -> Bool {
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        return parameters.allowFastOpen
    }
}

public final class LimLinkConnection: @unchecked Sendable {
    public let peerFingerprint: Fingerprint
    public let negotiatedVersionRaw: UInt16
    public let earlyDataAccepted: Bool
    public let negotiatedALPN: String?
    public let verifyObservation: VerifyBlockObservation
    private let connection: NWConnection

    init(
        peerFingerprint: Fingerprint,
        negotiatedVersionRaw: UInt16,
        earlyDataAccepted: Bool,
        negotiatedALPN: String?,
        verifyObservation: VerifyBlockObservation,
        connection: NWConnection
    ) {
        self.peerFingerprint = peerFingerprint
        self.negotiatedVersionRaw = negotiatedVersionRaw
        self.earlyDataAccepted = earlyDataAccepted
        self.negotiatedALPN = negotiatedALPN
        self.verifyObservation = verifyObservation
        self.connection = connection
    }

    public func cancel() {
        connection.cancel()
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportFailure(nw: error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive(maximumLength: Int = 65_536) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: TransportFailure(nw: error))
                    return
                }
                let bytes = content.map { [UInt8]($0) } ?? []
                if bytes.isEmpty, isComplete {
                    continuation.resume(throwing: TransportFailure.cancelled)
                    return
                }
                continuation.resume(returning: bytes)
            }
        }
    }

    /// Best-effort peer address for the same-device check. Nil when the path has no host.
    public var remoteHost: String? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, _):
            let text = "\(host)"
            if text.hasSuffix("%") { return nil }
            return text
        default:
            return nil
        }
    }

    public static func connect(
        host: String,
        port: UInt16,
        identity: IdentityMaterial,
        trust: TLSFingerprintPolicy,
        cap: TLSClientCap = .only13,
        scope: TransportScope = .localNetwork,
        timeout: Duration = .seconds(15)
    ) async throws -> LimLinkConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransportFailure.posix(0) }
        let queue = DispatchQueue(label: "limlink.connection")
        let probe = VerifyProbe()
        // acceptLocalOnly is a listener constraint. Setting it on a connection is not
        // how loopback dials 127.0.0.1.
        let parameters = makeParameters(
            identity: identity,
            trust: trust,
            cap: cap,
            probe: probe,
            queue: queue,
            acceptLocalOnly: false
        )
        // Loopback tests dial 127.0.0.1. The listener accepts local connections only.
        let target = scope == .loopback ? "127.0.0.1" : host
        let connection = NWConnection(host: NWEndpoint.Host(target), port: nwPort, using: parameters)
        return try await withTimeout(timeout) {
            try await finish(connection, probe: probe, queue: queue)
        }
    }

    /// User-initiated dial of a browsed instance. Browse filtering itself never calls this.
    public static func connect(
        serviceName: String,
        identity: IdentityMaterial,
        trust: TLSFingerprintPolicy,
        cap: TLSClientCap = .only13,
        timeout: Duration = .seconds(15)
    ) async throws -> LimLinkConnection {
        let queue = DispatchQueue(label: "limlink.connection")
        let probe = VerifyProbe()
        let parameters = makeParameters(
            identity: identity,
            trust: trust,
            cap: cap,
            probe: probe,
            queue: queue,
            acceptLocalOnly: false
        )
        let endpoint = NWEndpoint.service(
            name: serviceName,
            type: LimLinkProtocol.serviceType,
            domain: "local.",
            interface: nil
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        return try await withTimeout(timeout) {
            try await finish(connection, probe: probe, queue: queue)
        }
    }
}

public final class LimLinkListener: @unchecked Sendable {
    public let port: UInt16
    public let portDiagnostic: PortDiagnosticCode
    public let configuration: LimLinkConfiguration
    private let listener: NWListener
    private let queue: DispatchQueue
    private let probe: VerifyProbe
    private let advertisedFingerprint: String
    private let lock = NSLock()
    private var readyConnections: [LimLinkConnection] = []
    private var waiters: [OnceContinuation] = []
    private var terminalFailure: TransportFailure?
    private var advertising: BonjourAdvertisement?
    private var inviting: Bool

    public var latestVerifyObservation: VerifyBlockObservation? { probe.latest() }

    public static func start(
        configuration: LimLinkConfiguration,
        identity: IdentityMaterial,
        trust: TLSFingerprintPolicy,
        scope: TransportScope = .localNetwork,
        advertise: BonjourAdvertisement? = nil,
        timeout: Duration = .seconds(15)
    ) async throws -> LimLinkListener {
        let queue = DispatchQueue(label: "limlink.listener")
        let probe = VerifyProbe()
        var lastFailure: TransportFailure = .notReady
        for choice in MainPortPolicy.candidates() {
            let parameters = makeParameters(
                identity: identity,
                trust: trust,
                cap: .only13,
                probe: probe,
                queue: queue,
                acceptLocalOnly: scope == .loopback
            )
            let port: NWEndpoint.Port?
            switch choice {
            case .specified(let value):
                port = NWEndpoint.Port(rawValue: value)
            case .systemAssigned:
                port = nil
            }
            let incoming = ListenerConnectionHandoff()
            do {
                let listener = try await bind(
                    parameters: parameters, port: port, queue: queue, timeout: timeout,
                    onConnection: { incoming.receive($0) }
                )
                // Loopback tests dial 127.0.0.1 and must not advertise; Bonjour would wait on the
                // Local Network privacy prompt on a GitHub-hosted macOS runner.
                let serviceAdvertisement = scope == .loopback ? nil : advertise
                if let serviceAdvertisement {
                    let name = try bonjourInstanceName(serviceAdvertisement.instanceName)
                    listener.service = NWListener.Service(
                        name: name,
                        type: LimLinkProtocol.serviceType,
                        txtRecord: makeTXTRecord(serviceTXT(configuration: configuration, identity: identity, instanceOverride: name))
                    )
                }
                let bound = listener.port?.rawValue ?? 0
                let diagnostic = diagnosticCode(requested: choice, bound: bound)
                let endpoint = LimLinkListener(
                    port: bound,
                    portDiagnostic: diagnostic,
                    configuration: configuration,
                    listener: listener,
                    queue: queue,
                    probe: probe,
                    advertisedFingerprint: identity.fingerprint.base64URL,
                    advertising: serviceAdvertisement,
                    inviting: configuration.inviting
                )
                incoming.activate { [weak endpoint] connection in
                    guard let endpoint else { connection.cancel(); return }
                    endpoint.accept(connection)
                }
                return endpoint
            } catch {
                incoming.cancel()
                guard let failure = error as? TransportFailure else { throw error }
                lastFailure = failure
                if failure != .addressInUse, case .systemAssigned = choice {
                    throw failure
                }
                if failure != .addressInUse, case .specified = choice {
                    // A non-address error on a fixed port still advances only for EADDRINUSE.
                    throw failure
                }
            }
        }
        throw lastFailure
    }

    /// Replaces the advertised TXT `inv` key. Whether a running NWListener publishes the
    /// new record without a restart is not settled by Apple's documentation.
    public func setInviting(_ inviting: Bool) {
        lock.lock()
        self.inviting = inviting
        let advertising = self.advertising
        let configuration = self.configuration
        lock.unlock()
        guard let advertising else { return }
        var updated = configuration
        updated.inviting = inviting
        guard let name = try? bonjourInstanceName(advertising.instanceName) else { return }
        listener.service = NWListener.Service(
            name: name,
            type: LimLinkProtocol.serviceType,
            txtRecord: makeTXTRecord(serviceTXT(
                configuration: updated,
                identityFingerprint: advertisedFingerprint,
                inviting: inviting,
                name: name
            ))
        )
    }

    /// Stealth invite advertisement: instance name plus TXT `app` and `inv=1` only.
    /// `app` is always written (protocol 13:26). This does not open a client connection.
    public func publishStealthInvite(instanceName: String) throws {
        let name = try bonjourInstanceName(instanceName)
        var record = NWTXTRecord()
        record["app"] = configuration.hostApp.app
        record["inv"] = "1"
        listener.service = NWListener.Service(
            name: name,
            type: LimLinkProtocol.serviceType,
            txtRecord: record
        )
    }

    public func nextConnection(timeout: Duration = .seconds(15)) async throws -> LimLinkConnection {
        let holder = OnceHolder()
        return try await withTimeout(timeout) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let once = OnceContinuation(continuation)
                    holder.once = once
                    self.enqueue(once)
                }
            } onCancel: {
                holder.once?.resume(with: .failure(TransportFailure.timedOut))
            }
        }
    }

    public func stop() {
        terminate(with: .cancelled)
        listener.cancel()
    }

    private func terminate(with failure: TransportFailure) {
        lock.lock()
        guard terminalFailure == nil else {
            lock.unlock()
            return
        }
        terminalFailure = failure
        let pending = waiters
        let connections = readyConnections
        waiters.removeAll()
        readyConnections.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(with: .failure(failure))
        }
        for connection in connections { connection.cancel() }
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .failed(let error): terminate(with: TransportFailure(nw: error))
        case .cancelled: terminate(with: .cancelled)
        default: break
        }
    }

    init(
        port: UInt16,
        portDiagnostic: PortDiagnosticCode,
        configuration: LimLinkConfiguration,
        listener: NWListener,
        queue: DispatchQueue,
        probe: VerifyProbe,
        advertisedFingerprint: String,
        advertising: BonjourAdvertisement?,
        inviting: Bool
    ) {
        self.port = port
        self.portDiagnostic = portDiagnostic
        self.configuration = configuration
        self.listener = listener
        self.queue = queue
        self.probe = probe
        self.advertisedFingerprint = advertisedFingerprint
        self.advertising = advertising
        self.inviting = inviting
        listener.stateUpdateHandler = { [weak self] state in self?.handleState(state) }
        // Binding finishes before this owner is created; retain a failure that occurred
        // during that handoff even if the previous ready callback already consumed it.
        handleState(listener.state)
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                do {
                    let link = try makeLink(connection, probe: self.probe)
                    self.deliver(link)
                } catch {
                    connection.cancel()
                }
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func enqueue(_ once: OnceContinuation) {
        lock.lock()
        if let terminalFailure {
            lock.unlock()
            once.resume(with: .failure(terminalFailure))
            return
        }
        waiters.removeAll { $0.isSpent }
        if !readyConnections.isEmpty {
            let connection = readyConnections.removeFirst()
            lock.unlock()
            once.resume(with: .success(connection))
            return
        }
        waiters.append(once)
        lock.unlock()
    }

    private func deliver(_ connection: LimLinkConnection) {
        lock.lock()
        guard terminalFailure == nil else {
            lock.unlock()
            connection.cancel()
            return
        }
        waiters.removeAll { $0.isSpent }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(with: .success(connection))
            return
        }
        readyConnections.append(connection)
        lock.unlock()
    }
}

private final class SecIdentityBox: @unchecked Sendable {
    let value: sec_identity_t
    init(_ value: sec_identity_t) { self.value = value }
}

final class VerifyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: VerifyBlockObservation?

    func record(_ value: VerifyBlockObservation) {
        lock.lock()
        observation = value
        lock.unlock()
    }

    func latest() -> VerifyBlockObservation? {
        lock.lock()
        defer { lock.unlock() }
        return observation
    }
}

final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LimLinkConnection, Error>?

    init(_ continuation: CheckedContinuation<LimLinkConnection, Error>) {
        self.continuation = continuation
    }

    var isSpent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation == nil
    }

    func resume(with result: Result<LimLinkConnection, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class OnceHolder: @unchecked Sendable {
    var once: OnceContinuation?
}

func listenerSetupSummary(parameters: NWParameters, port: NWEndpoint.Port?) -> String {
    let portText: String
    if let port {
        portText = port.rawValue == 0 ? "any(0)" : String(port.rawValue)
    } else {
        portText = "omitted"
    }
    let local = parameters.requiredLocalEndpoint.map { String(describing: $0) } ?? "nil"
    return [
        "on=\(portText)",
        "acceptLocalOnly=\(parameters.acceptLocalOnly)",
        "allowLocalEndpointReuse=\(parameters.allowLocalEndpointReuse)",
        "requiredInterfaceType=\(String(describing: parameters.requiredInterfaceType))",
        "requiredLocalEndpoint=\(local)",
        "includePeerToPeer=\(parameters.includePeerToPeer)",
        "allowFastOpen=\(parameters.allowFastOpen)",
    ].joined(separator: " ")
}

private func makeParameters(
    identity: IdentityMaterial,
    trust: TLSFingerprintPolicy,
    cap: TLSClientCap,
    probe: VerifyProbe,
    queue: DispatchQueue,
    acceptLocalOnly: Bool
) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    let minimum: tls_protocol_version_t = cap == .only12 ? .TLSv12 : .TLSv13
    let maximum: tls_protocol_version_t = cap == .only12 ? .TLSv12 : .TLSv13
    sec_protocol_options_set_min_tls_protocol_version(options, minimum)
    sec_protocol_options_set_max_tls_protocol_version(options, maximum)
    sec_protocol_options_set_tls_renegotiation_enabled(options, false)
    sec_protocol_options_set_tls_resumption_enabled(options, false)
    sec_protocol_options_set_tls_tickets_enabled(options, false)
    sec_protocol_options_set_tls_false_start_enabled(options, false)
    sec_protocol_options_set_tls_ocsp_enabled(options, false)
    sec_protocol_options_set_peer_authentication_required(options, true)
    sec_protocol_options_add_tls_application_protocol(options, LimLinkProtocol.alpnHTTP11)
    let identityBox = SecIdentityBox(identity.secIdentity)
    sec_protocol_options_set_local_identity(options, identityBox.value)
    sec_protocol_options_set_challenge_block(options, { _, complete in
        complete(identityBox.value)
    }, queue)
    sec_protocol_options_set_verify_block(options, { metadata, _, complete in
        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata).rawValue
        let early = sec_protocol_metadata_get_early_data_accepted(metadata)
        let fingerprint = peerFingerprint(metadata)
        let versionRejected = verifyBlockShouldRejectVersion(version)
        let decision = decideTLSTrust(peer: fingerprint, policy: trust)
        let accepted = !versionRejected && !early && {
            if case .accept = decision { return true }
            return false
        }()
        fputs(
            "LIMLINK_VERIFY_BLOCK version=\(version) available=\(version != 0) early=\(early) sawCert=\(fingerprint != nil) accepted=\(accepted)\n",
            stderr
        )
        probe.record(VerifyBlockObservation(
            negotiatedVersionRaw: version,
            versionWasAvailable: version != 0,
            earlyDataAccepted: early,
            sawCertificate: fingerprint != nil,
            acceptedFingerprint: accepted
        ))
        complete(accepted)
    }, queue)

    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.allowFastOpen = false
    parameters.includePeerToPeer = false
    parameters.acceptLocalOnly = acceptLocalOnly
    // Leave requiredLocalEndpoint unset and allowLocalEndpointReuse at its default.
    // Either one, combined with `NWListener(using:on:)`, fails start with POSIX EINVAL.
    return parameters
}

private func peerFingerprint(_ metadata: sec_protocol_metadata_t) -> Fingerprint? {
    var der: Data?
    let accessed = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
        guard der == nil else { return }
        let ref = sec_certificate_copy_ref(certificate).takeRetainedValue()
        der = SecCertificateCopyData(ref) as Data
    }
    guard accessed, let der else { return nil }
    return try? X509Parser.parseCertificate([UInt8](der)).fingerprint
}

private func makeLink(_ connection: NWConnection, probe: VerifyProbe) throws -> LimLinkConnection {
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
        throw TransportFailure.metadataMissing
    }
    let security = metadata.securityProtocolMetadata
    let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(security).rawValue
    let early = sec_protocol_metadata_get_early_data_accepted(security)
    let alpn = sec_protocol_metadata_get_negotiated_protocol(security).map { String(cString: $0) }
    let check = PostHandshakeCheck(versionRaw: version, earlyDataAccepted: early, alpn: alpn)
    fputs(
        "LIMLINK_POST_HANDSHAKE version=\(version) early=\(early) alpn=\(alpn ?? "nil") accept=\(check.accept)\n",
        stderr
    )
    guard check.accept else {
        connection.cancel()
        throw TransportFailure.tlsRejected
    }
    guard let fingerprint = peerFingerprint(security) else { throw TransportFailure.tlsRejected }
    let observation = probe.latest() ?? VerifyBlockObservation(
        negotiatedVersionRaw: version,
        versionWasAvailable: false,
        earlyDataAccepted: early,
        sawCertificate: true,
        acceptedFingerprint: true
    )
    return LimLinkConnection(
        peerFingerprint: fingerprint,
        negotiatedVersionRaw: version,
        earlyDataAccepted: early,
        negotiatedALPN: alpn,
        verifyObservation: observation,
        connection: connection
    )
}

private func finish(_ connection: NWConnection, probe: VerifyProbe, queue: DispatchQueue) async throws -> LimLinkConnection {
    let holder = LinkOnceHolder()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let once = LinkOnce(continuation)
            holder.once = once
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    do {
                        once.resume(with: .success(try makeLink(connection, probe: probe)))
                    } catch {
                        connection.cancel()
                        once.resume(with: .failure(error))
                    }
                case .failed(let error):
                    once.resume(with: .failure(TransportFailure(nw: error)))
                case .cancelled:
                    once.resume(with: .failure(TransportFailure.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    } onCancel: {
        connection.cancel()
        holder.once?.resume(with: .failure(TransportFailure.timedOut))
    }
}

/// Bridges connections arriving between listener readiness and owner creation.
private final class ListenerConnectionHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [NWConnection] = []
    private var handler: (@Sendable (NWConnection) -> Void)?
    private var closed = false

    func receive(_ connection: NWConnection) {
        lock.lock()
        if closed {
            lock.unlock()
            connection.cancel()
        } else if let handler {
            lock.unlock()
            handler(connection)
        } else {
            pending.append(connection)
            lock.unlock()
        }
    }

    func activate(_ handler: @escaping @Sendable (NWConnection) -> Void) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        self.handler = handler
        let buffered = pending
        pending.removeAll()
        lock.unlock()
        for connection in buffered { handler(connection) }
    }

    func cancel() {
        lock.lock()
        closed = true
        handler = nil
        let buffered = pending
        pending.removeAll()
        lock.unlock()
        for connection in buffered { connection.cancel() }
    }
}

private func bind(
    parameters: NWParameters,
    port: NWEndpoint.Port?,
    queue: DispatchQueue,
    timeout: Duration,
    onConnection: @escaping @Sendable (NWConnection) -> Void
) async throws -> NWListener {
    // One constructor: `NWListener(using:on:)`. System-assigned is `.any`.
    // `Port(rawValue: 0)` is not that value, and requiredLocalEndpoint is never set.
    let endpointPort = port ?? .any
    let summary = listenerSetupSummary(parameters: parameters, port: endpointPort)
    let listener: NWListener
    do {
        listener = try NWListener(using: parameters, on: endpointPort)
    } catch {
        fputs("LIMLINK_BIND_INIT_FAIL \(summary) error=\(error)\n", stderr)
        throw error
    }
    // Network.framework requires this handler before start, even before the owner
    // can be created with the assigned port. The handoff buffers early arrivals.
    listener.newConnectionHandler = onConnection
    return try await withTimeout(timeout) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWListener, Error>) in
                let once = ListenerOnce(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        fputs("LIMLINK_BIND_READY port=\(listener.port?.rawValue ?? 0)\n", stderr)
                        once.resume(with: .success(listener))
                    case .failed(let error):
                        fputs("LIMLINK_BIND_FAIL \(summary) error=\(error)\n", stderr)
                        once.resume(with: .failure(TransportFailure(nw: error)))
                    case .cancelled:
                        once.resume(with: .failure(TransportFailure.cancelled))
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }
    }
}

private func serviceTXT(configuration: LimLinkConfiguration, identity: IdentityMaterial, instanceOverride: String) -> ServiceTXT {
    ServiceTXT(
        fingerprint: identity.fingerprint.base64URL,
        deviceType: configuration.deviceType.rawValue,
        capabilities: configuration.capabilities,
        inviting: configuration.inviting,
        app: configuration.hostApp.app
    )
}

private func serviceTXT(
    configuration: LimLinkConfiguration,
    identityFingerprint: String?,
    inviting: Bool,
    name: String
) -> ServiceTXT {
    _ = name
    return ServiceTXT(
        fingerprint: identityFingerprint ?? "",
        deviceType: configuration.deviceType.rawValue,
        capabilities: configuration.capabilities,
        inviting: inviting,
        app: configuration.hostApp.app
    )
}

private func makeTXTRecord(_ txt: ServiceTXT) -> NWTXTRecord {
    var record = NWTXTRecord()
    record["pv"] = txt.protocolVersions.joined(separator: ",")
    record["fp"] = txt.fingerprint
    record["dt"] = txt.deviceType
    if !txt.capabilities.isEmpty {
        record["cap"] = txt.capabilities.joined(separator: ",")
    }
    record["app"] = txt.app
    if txt.inviting {
        record["inv"] = "1"
    }
    return record
}

private func diagnosticCode(requested: PortChoice, bound: UInt16) -> PortDiagnosticCode {
    switch requested {
    case .systemAssigned:
        return .systemAssigned
    case .specified(let port):
        if bound == LimLinkProtocol.primaryPort { return .primary }
        if bound >= LimLinkProtocol.primaryPort && bound <= MainPortPolicy.lastFixed {
            return .fallback(port: bound, offset: Int(bound - LimLinkProtocol.primaryPort))
        }
        _ = port
        return .systemAssigned
    }
}

func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TransportFailure.timedOut
        }
        guard let first = try await group.next() else { throw TransportFailure.timedOut }
        group.cancelAll()
        return first
    }
}

extension TransportFailure {
    init(nw error: NWError) {
        switch error {
        case .posix(let code):
            self = code == .EADDRINUSE ? .addressInUse : .posix(code.rawValue)
        case .dns(let code):
            self = .dns(code)
        case .tls(let code):
            self = .tls(code)
        default:
            self = .posix(-1)
        }
    }
}

private final class LinkOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LimLinkConnection, Error>?
    init(_ continuation: CheckedContinuation<LimLinkConnection, Error>) { self.continuation = continuation }
    func resume(with result: Result<LimLinkConnection, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class LinkOnceHolder: @unchecked Sendable {
    var once: LinkOnce?
}

private final class ListenerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWListener, Error>?
    init(_ continuation: CheckedContinuation<NWListener, Error>) { self.continuation = continuation }
    func resume(with result: Result<NWListener, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
