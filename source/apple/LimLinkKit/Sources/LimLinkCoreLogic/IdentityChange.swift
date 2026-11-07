import Foundation

public struct TrustedPeerIdentity: Hashable, Sendable {
    public var fingerprint: String
    public var name: String
    public var app: String

    public init(fingerprint: String, name: String, app: String) {
        self.fingerprint = fingerprint
        self.name = name
        self.app = app
    }
}

public enum IdentityChange: Hashable, Sendable {
    /// Name and `app` both match a trusted row, and the fingerprint does not.
    case changed(trustedFingerprint: String)
    /// Includes a matching fingerprint, a different name, or the same name with a different `app`.
    case notThisCase
}

public enum IdentityChangeCheck {
    /// Protocol 4.4: prompt only when the name and `app` both match. A shared name
    /// with a different `app` (LimLink and CaseCheck on one phone) is not this case.
    ///
    /// // TODO(protocol §4.4): name comparison is exact. The text does not say whether
    /// to trim, case-fold, or normalize Unicode before comparing.
    public static func evaluate(
        observedName: String,
        observedApp raw: String?,
        observedFingerprint: String,
        trusted: [TrustedPeerIdentity]
    ) -> IdentityChange {
        guard let observedApp = HostAppIdentity.observe(raw).effectiveIdentifier else {
            return .notThisCase
        }
        for row in trusted {
            let trustedApp = HostAppIdentity.observe(row.app).effectiveIdentifier ?? row.app
            guard observedName == row.name, observedApp == trustedApp else { continue }
            if observedFingerprint != row.fingerprint {
                return .changed(trustedFingerprint: row.fingerprint)
            }
        }
        return .notThisCase
    }
}
