import Foundation

public enum AppIdentifierError: Error, Sendable, Equatable {
    case empty
    case tooLong(bytes: Int)
    case invalidCharset
    /// Local `app` is not in the v1 interop registry, so it has no group.
    case notInRegistry
    /// A host-supplied list narrowed the group until it no longer contained this app.
    case allowListExcludesSelf
}

/// v1 interop registry (protocol 1.2, 13:10). Display names stay in the host.
public enum InteropRegistry {
    public static let limlink = "limlink"
    public static let casecheck = "casecheck"
    /// Both members share the `limlink` group.
    public static let limlinkGroup: Set<String> = [limlink, casecheck]

    public static func group(of app: String) -> Set<String>? {
        limlinkGroup.contains(app) ? limlinkGroup : nil
    }
}

/// What a TXT record, multicast packet, hello body, or header actually carried.
public enum ObservedApp: Hashable, Sendable {
    /// Key or header absent, or present and empty. Allow-list checks use `limlink`.
    case implicitLimlink
    case named(String)
    /// Charset or length failed. Not a member of any allow-list.
    case unrecognized

    public var effectiveIdentifier: String? {
        switch self {
        case .implicitLimlink:
            return LimLinkProtocol.defaultApp
        case .named(let app):
            return app
        case .unrecognized:
            return nil
        }
    }
}

/// The host's own `app` and the peer apps it will show and talk to.
///
/// Section 1.2 is a user-facing filter, not a security boundary. The default
/// allow-list is every app in this host's interop group. A host list may only
/// narrow that set, and the result must still contain this app.
public struct HostAppIdentity: Hashable, Sendable {
    public let app: String
    public let allowedPeers: Set<String>

    public init(app: String, allowedPeers: Set<String>? = nil) throws {
        let normalized = try Self.normalizeHostApp(app)
        guard let group = InteropRegistry.group(of: normalized) else {
            throw AppIdentifierError.notInRegistry
        }
        self.app = normalized
        if let allowedPeers {
            let supplied = try allowedPeers.map(Self.normalizeHostApp)
            let narrowed = group.intersection(Set(supplied))
            guard narrowed.contains(normalized) else {
                throw AppIdentifierError.allowListExcludesSelf
            }
            self.allowedPeers = narrowed
        } else {
            self.allowedPeers = group
        }
    }

    public func allows(peerApp raw: String?) -> Bool {
        guard let identifier = Self.observe(raw).effectiveIdentifier else { return false }
        return allowedPeers.contains(identifier)
    }

    /// Host-supplied identifiers: ASCII-folded, `^[a-z0-9-]{1,16}$`.
    public static func normalizeHostApp(_ raw: String) throws -> String {
        let folded = asciiFold(raw)
        let bytes = Array(folded.utf8)
        if bytes.isEmpty { throw AppIdentifierError.empty }
        if bytes.count > LimLinkProtocol.maxAppUTF8Bytes {
            throw AppIdentifierError.tooLong(bytes: bytes.count)
        }
        guard bytes.allSatisfy(isAppByte) else { throw AppIdentifierError.invalidCharset }
        return folded
    }

    public static func observe(_ raw: String?) -> ObservedApp {
        guard let raw, !raw.isEmpty else { return .implicitLimlink }
        let folded = asciiFold(raw)
        let bytes = Array(folded.utf8)
        if bytes.isEmpty || bytes.count > LimLinkProtocol.maxAppUTF8Bytes || !bytes.allSatisfy(isAppByte) {
            return .unrecognized
        }
        return .named(folded)
    }
}

public enum PeerDisposition: Hashable, Sendable {
    case proceed(app: String)
    case appNotInInteropGroup
    case sameDeviceOtherApp
}

public enum AppRequestDecision: Sendable, Equatable {
    case allowed(app: String)
    case mismatch(ProtocolError)
}

/// `app` and `alias` stay separate. The host adds a product prefix; the Kit does not.
public struct PeerFields: Hashable, Sendable {
    public var app: String
    public var alias: String

    public init(app: String, alias: String) {
        self.app = app
        self.alias = alias
    }
}

public enum AppGate {
    public static let headerName = LimLinkProtocol.appHeader
    public static let sameDeviceReason = "same_device"

    public static func observedApp(headerValue: String?) -> ObservedApp {
        HostAppIdentity.observe(headerValue)
    }

    /// Allow-list first, then same-device (protocol 1.2, revision 13:20).
    ///
    /// An app that is not in the local list is `.appNotInInteropGroup` even when
    /// the address is local, and the wire error has no `detail.reason`.
    /// `.sameDeviceOtherApp` is only an in-group app that differs from this host
    /// and sits on a local address. The same app on this device proceeds.
    public static func decide(
        peerApp raw: String?,
        peerAddressIsLocal: Bool,
        host: HostAppIdentity
    ) -> PeerDisposition {
        guard let identifier = HostAppIdentity.observe(raw).effectiveIdentifier,
              host.allowedPeers.contains(identifier) else {
            return .appNotInInteropGroup
        }
        if peerAddressIsLocal && identifier != host.app {
            return .sameDeviceOtherApp
        }
        return .proceed(app: identifier)
    }

    public static func wireError(for disposition: PeerDisposition, host: HostAppIdentity) -> ProtocolError? {
        switch disposition {
        case .proceed:
            return nil
        case .appNotInInteropGroup:
            return .appMismatch(localApp: host.app)
        case .sameDeviceOtherApp:
            return .appMismatchSameDevice(localApp: host.app)
        }
    }

    /// Admission for a non-hello `/limlink/v1/` request. A missing header is `limlink`.
    /// `hello` itself is not rejected; the initiator stops after the response.
    public static func admit(
        headerValue: String?,
        host: HostAppIdentity,
        peerAddressIsLocal: Bool = false
    ) -> AppRequestDecision {
        let disposition = decide(
            peerApp: headerValue,
            peerAddressIsLocal: peerAddressIsLocal,
            host: host
        )
        switch disposition {
        case .proceed(let app):
            return .allowed(app: app)
        case .appNotInInteropGroup, .sameDeviceOtherApp:
            return .mismatch(wireError(for: disposition, host: host)!)
        }
    }
}

func asciiFold(_ raw: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in raw.unicodeScalars {
        if scalar.value >= 65 && scalar.value <= 90 {
            scalars.append(UnicodeScalar(scalar.value + 32)!)
        } else {
            scalars.append(scalar)
        }
    }
    return String(scalars)
}

func isAppByte(_ byte: UInt8) -> Bool {
    (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
}
