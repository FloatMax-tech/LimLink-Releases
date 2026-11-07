public struct PairingCoreInfo: Equatable, Sendable {
    public var version: String
    public var abiVersion: UInt32
    public var suites: [String]

    public init(version: String, abiVersion: UInt32, suites: [String]) {
        self.version = version
        self.abiVersion = abiVersion
        self.suites = suites
    }
}

public struct PairingCoreUnavailable: Error, Sendable, Equatable {}

/// Plug-in for the shared Rust core (protocol 15.10.7). This milestone does not link the core.
public protocol LimLinkPairingCore: Sendable {
    func coreInfo() async throws -> PairingCoreInfo
}

public struct UnavailablePairingCore: LimLinkPairingCore {
    public init() {}

    public func coreInfo() async throws -> PairingCoreInfo {
        throw PairingCoreUnavailable()
    }
}

/// Temporary trust path for tests and for a host that already knows the peer fingerprint.
/// Not a pairing method, and not affected by `app`.
public struct ExplicitFingerprintTrust: Hashable, Sendable {
    public var fingerprints: Set<Fingerprint>

    public init(fingerprints: Set<Fingerprint>) {
        self.fingerprints = fingerprints
    }

    public func trusts(_ fingerprint: Fingerprint) -> Bool {
        fingerprints.contains(fingerprint)
    }
}
