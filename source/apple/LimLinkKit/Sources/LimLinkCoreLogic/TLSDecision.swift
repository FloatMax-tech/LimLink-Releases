public enum TLSVersionObservation: Equatable, Sendable {
    case tls13
    /// A known TLS version other than 1.3.
    case rejected(raw: UInt16)
    /// Zero, or a value this stack does not treat as a finished negotiation.
    case unavailable
}

public func classifyNegotiatedTLSVersion(_ raw: UInt16) -> TLSVersionObservation {
    switch raw {
    case LimLinkProtocol.tls13WireVersion:
        return .tls13
    case 0x0301, 0x0302, 0x0303:
        return .rejected(raw: raw)
    default:
        return .unavailable
    }
}

/// Inside `sec_protocol_options_set_verify_block`, reject only when the metadata already
/// shows TLS 1.2 or older. A zero result is treated as "not populated yet"; the ready-state
/// check still requires TLS 1.3.
public func verifyBlockShouldRejectVersion(_ raw: UInt16) -> Bool {
    if case .rejected = classifyNegotiatedTLSVersion(raw) {
        return true
    }
    return false
}

public struct PostHandshakeCheck: Equatable, Sendable {
    public var versionRaw: UInt16
    public var earlyDataAccepted: Bool
    public var alpn: String?

    public init(versionRaw: UInt16, earlyDataAccepted: Bool, alpn: String?) {
        self.versionRaw = versionRaw
        self.earlyDataAccepted = earlyDataAccepted
        self.alpn = alpn
    }

    /// Fail closed: the negotiated version must be TLS 1.3, early data must be off,
    /// and a negotiated ALPN other than `http/1.1` is refused. A missing ALPN is allowed
    /// because protocol section 2 says ALPN may be omitted.
    public var accept: Bool {
        guard versionRaw == LimLinkProtocol.tls13WireVersion, !earlyDataAccepted else { return false }
        if let alpn, alpn != LimLinkProtocol.alpnHTTP11 { return false }
        return true
    }
}

/// Fingerprint pin for one TLS handshake. This type deliberately has no `app` field.
public enum TLSFingerprintPolicy: Hashable, Sendable {
    /// Tests and connections to an already chosen peer. Any other fingerprint is rejected.
    case allowListed(Set<Fingerprint>)
    /// Complete the handshake and report the fingerprint. Pairing decides trust later.
    case acceptAndReport
}

public enum TLSTrustDecision: Equatable, Sendable {
    case accept(Fingerprint)
    case reject
}

/// Certificate bytes are already reduced to a fingerprint by the platform code.
/// Expiry, hostname, and `app` are not inputs.
public func decideTLSTrust(peer: Fingerprint?, policy: TLSFingerprintPolicy) -> TLSTrustDecision {
    guard let peer else { return .reject }
    switch policy {
    case .allowListed(let allowed):
        return allowed.contains(peer) ? .accept(peer) : .reject
    case .acceptAndReport:
        return .accept(peer)
    }
}
