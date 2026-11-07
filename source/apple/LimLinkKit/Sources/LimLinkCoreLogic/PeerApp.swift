import Foundation

/// Where an `app` value was learned. TXT and multicast are provisional.
public enum AppObservationSource: String, Hashable, Sendable {
    case txt
    case multicast
    case hello
    case inviteHello = "invite/hello"
    case requestHeader = "X-LimLink-App"
}

public enum DiscoveryPath: Hashable, Sendable {
    /// TXT or multicast browse. The pre-filter is one-way.
    case browse
    /// QR, manual IP, or subnet scan. Always `hello`, then decide on the TLS `app`.
    case manual
}

public enum TlsCheckIntent: Hashable, Sendable {
    /// A later TXT or background `hello`. Failure drops the peer and only writes the log.
    case backgroundRefresh
    /// The user tapped this peer. Failure is a typed error so the host can show spec 6.15.
    case userTap
}

public enum DiscoveryPlacement: Hashable, Sendable {
    case visible
    case diagnosticOnly
    case hidden
}

public struct TxtPrefilterDecision: Hashable, Sendable {
    public var placement: DiscoveryPlacement
    /// False when a browse TXT is outside the allow-list or is another app on this device.
    /// Manual paths are always true. There is no second probe after a browse rejection.
    public var sendHello: Bool

    public init(placement: DiscoveryPlacement, sendHello: Bool) {
        self.placement = placement
        self.sendHello = sendHello
    }
}

public enum TxtPrefilter {
    /// Revision 13:22. Out-of-allow-list TXT peers stay grey in diagnostics and are not contacted.
    /// A new TXT record is classified again by calling this with the new value.
    public static func decide(
        peerApp raw: String?,
        addresses: [String],
        localAddresses: Set<String>,
        host: HostAppIdentity,
        path: DiscoveryPath
    ) -> TxtPrefilterDecision {
        if path == .manual {
            return TxtPrefilterDecision(placement: .visible, sendHello: true)
        }
        let place = placement(raw: raw, addresses: addresses, localAddresses: localAddresses, host: host)
        return TxtPrefilterDecision(placement: place, sendHello: place == .visible)
    }
}

public struct PeerEntry: Hashable, Sendable {
    public var id: String
    public var alias: String
    public var addresses: [String]
    public var fingerprint: String?
    public var provisionalSource: AppObservationSource
    /// Nil when the provisional record had no `app` key. That still means `limlink` at the gate.
    public var provisionalRaw: String?
    public var provisionalPresent: Bool
    public var authoritativeSource: AppObservationSource?
    public var authoritativeRaw: String?
    public var authoritativePresent: Bool

    public init(
        id: String,
        alias: String,
        addresses: [String] = [],
        fingerprint: String? = nil,
        provisionalSource: AppObservationSource,
        provisionalRaw: String? = nil,
        provisionalPresent: Bool,
        authoritativeSource: AppObservationSource? = nil,
        authoritativeRaw: String? = nil,
        authoritativePresent: Bool = false
    ) {
        self.id = id
        self.alias = alias
        self.addresses = addresses
        self.fingerprint = fingerprint
        self.provisionalSource = provisionalSource
        self.provisionalRaw = provisionalRaw
        self.provisionalPresent = provisionalPresent
        self.authoritativeSource = authoritativeSource
        self.authoritativeRaw = authoritativeRaw
        self.authoritativePresent = authoritativePresent
    }

    public static func fromTXT(_ service: DiscoveredService, id: String? = nil) -> PeerEntry {
        PeerEntry(
            id: id ?? service.instanceName,
            alias: service.instanceName,
            addresses: service.addresses,
            fingerprint: service.fields.fingerprint,
            provisionalSource: .txt,
            provisionalRaw: service.fields.app,
            provisionalPresent: service.fields.entries["app"] != nil
        )
    }
}

public struct TlsRecheck: Equatable, Sendable {
    public var disposition: PeerDisposition
    /// Where the peer belongs after the TLS value. `.hidden` is in neither list.
    public var listPlacement: DiscoveryPlacement
    /// Set only for `.userTap` when the TLS check fails. Background failure stays nil.
    public var hostError: TransferHostError?
    public var logEntry: AppMismatchLogEntry?

    public init(
        disposition: PeerDisposition,
        listPlacement: DiscoveryPlacement,
        hostError: TransferHostError?,
        logEntry: AppMismatchLogEntry?
    ) {
        self.disposition = disposition
        self.listPlacement = listPlacement
        self.hostError = hostError
        self.logEntry = logEntry
    }
}

public enum TlsRecheckEngine {
    /// TLS wins: `hello` for the initiator, `invite/hello` for the invite-code receiver,
    /// `X-LimLink-App` for a server. Allow-list first, then same-device.
    public static func evaluate(
        deviceName: String,
        ip: String,
        txtAppRaw: String?,
        txtAppPresent: Bool,
        tlsAppRaw: String?,
        tlsAppPresent: Bool,
        peerAddressIsLocal: Bool,
        intent: TlsCheckIntent,
        timestamp: String,
        host: HostAppIdentity
    ) -> TlsRecheck {
        let tlsRaw = tlsAppPresent ? tlsAppRaw : nil
        let disposition = AppGate.decide(
            peerApp: tlsRaw,
            peerAddressIsLocal: peerAddressIsLocal,
            host: host
        )
        let place: DiscoveryPlacement
        switch disposition {
        case .proceed:
            place = .visible
        case .appNotInInteropGroup:
            place = .diagnosticOnly
        case .sameDeviceOtherApp:
            place = .hidden
        }
        let txtObserved = HostAppIdentity.observe(txtAppPresent ? txtAppRaw : nil)
        let tlsObserved = HostAppIdentity.observe(tlsRaw)
        let differed = txtObserved != tlsObserved
        let failed: Bool
        if case .proceed = disposition {
            failed = false
        } else {
            failed = true
        }
        let shouldLog = differed || failed
        let entry = shouldLog
            ? AppMismatchLogEntry(
                deviceName: deviceName,
                ip: ip,
                txtApp: DiagnosticAppLabel.render(raw: txtAppRaw, present: txtAppPresent),
                tlsApp: DiagnosticAppLabel.render(raw: tlsAppRaw, present: tlsAppPresent),
                timestamp: timestamp
            )
            : nil
        let prompt: TransferHostError?
        if failed && intent == .userTap {
            switch disposition {
            case .appNotInInteropGroup:
                prompt = .appNotInInteropGroup
            case .sameDeviceOtherApp:
                prompt = .sameDeviceOtherApp
            case .proceed:
                prompt = nil
            }
        } else {
            prompt = nil
        }
        return TlsRecheck(
            disposition: disposition,
            listPlacement: place,
            hostError: prompt,
            logEntry: entry
        )
    }
}

public struct InviteHelloBody: Equatable, Sendable {
    public var inviteSessionId: String
    public var nonceS: String?
    public var alias: String?
    public var inviteAgeSec: Int?
    public var suite: String?
    /// Absent on the wire means `limlink`. Responses we send always set this.
    public var app: String?
    public var appPresent: Bool

    public init(
        inviteSessionId: String,
        nonceS: String? = nil,
        alias: String? = nil,
        inviteAgeSec: Int? = nil,
        suite: String? = nil,
        app: String? = nil,
        appPresent: Bool
    ) {
        self.inviteSessionId = inviteSessionId
        self.nonceS = nonceS
        self.alias = alias
        self.inviteAgeSec = inviteAgeSec
        self.suite = suite
        self.app = app
        self.appPresent = appPresent
    }
}

public struct InviteCandidateDraft: Hashable, Sendable {
    public var id: String
    public var alias: String
    public var addresses: [String]
    public var txtAppRaw: String?
    public var txtAppPresent: Bool
    public var ageSec: Int?

    public init(
        id: String,
        alias: String,
        addresses: [String] = [],
        txtAppRaw: String? = nil,
        txtAppPresent: Bool,
        ageSec: Int? = nil
    ) {
        self.id = id
        self.alias = alias
        self.addresses = addresses
        self.txtAppRaw = txtAppRaw
        self.txtAppPresent = txtAppPresent
        self.ageSec = ageSec
    }
}

public enum InviteCandidateBoard {
    /// One-way TXT pre-filter. False means do not send `invite/hello`.
    public static func shouldSendInviteHello(
        _ draft: InviteCandidateDraft,
        host: HostAppIdentity,
        localAddresses: Set<String>
    ) -> Bool {
        TxtPrefilter.decide(
            peerApp: draft.txtAppPresent ? draft.txtAppRaw : nil,
            addresses: draft.addresses,
            localAddresses: localAddresses,
            host: host,
            path: .browse
        ).sendHello
    }

    /// Final label after `invite/hello`, only for a peer the pre-filter allowed us to contact.
    public static func applyInviteHello(
        _ draft: InviteCandidateDraft,
        response: InviteHelloBody,
        host: HostAppIdentity,
        localAddresses: Set<String>,
        intent: TlsCheckIntent,
        timestamp: String,
        ip: String
    ) -> TlsRecheck {
        let local = draft.addresses.contains {
            LocalAddressMatch.isLocal($0, interfaceAddresses: localAddresses)
        }
        return TlsRecheckEngine.evaluate(
            deviceName: response.alias ?? draft.alias,
            ip: ip,
            txtAppRaw: draft.txtAppRaw,
            txtAppPresent: draft.txtAppPresent,
            tlsAppRaw: response.app,
            tlsAppPresent: response.appPresent,
            peerAddressIsLocal: local,
            intent: intent,
            timestamp: timestamp,
            host: host
        )
    }
}

func placement(
    raw: String?,
    addresses: [String],
    localAddresses: Set<String>,
    host: HostAppIdentity
) -> DiscoveryPlacement {
    let local = addresses.contains { LocalAddressMatch.isLocal($0, interfaceAddresses: localAddresses) }
    switch AppGate.decide(peerApp: raw, peerAddressIsLocal: local, host: host) {
    case .proceed:
        return .visible
    case .appNotInInteropGroup:
        return .diagnosticOnly
    case .sameDeviceOtherApp:
        return .hidden
    }
}
