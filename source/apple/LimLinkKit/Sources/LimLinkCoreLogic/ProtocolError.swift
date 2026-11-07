/// Wire and local error codes from protocol section 13, plus `E_APP_MISMATCH` from section 1.2.
/// The Kit does not localize these. The host maps the code to interface text.
public enum ProtocolErrorCode: String, Sendable, Equatable, CaseIterable {
    case badRequest = "E_BAD_REQUEST"
    case unsupportedVersion = "E_UNSUPPORTED_VERSION"
    case notPaired = "E_NOT_PAIRED"
    case pairCommitMismatch = "E_PAIR_COMMIT_MISMATCH"
    case pairRejected = "E_PAIR_REJECTED"
    case pairTokenInvalid = "E_PAIR_TOKEN_INVALID"
    case pairExpired = "E_PAIR_EXPIRED"
    case rejected = "E_REJECTED"
    case decisionTimeout = "E_DECISION_TIMEOUT"
    case busy = "E_BUSY"
    case tokenInvalid = "E_TOKEN_INVALID"
    case sessionNotFound = "E_SESSION_NOT_FOUND"
    case sessionExpired = "E_SESSION_EXPIRED"
    case sessionCancelled = "E_SESSION_CANCELLED"
    case offsetMismatch = "E_OFFSET_MISMATCH"
    case checksumMismatch = "E_CHECKSUM_MISMATCH"
    case pathInvalid = "E_PATH_INVALID"
    case fileTooLarge = "E_FILE_TOO_LARGE"
    case tooManyEntries = "E_TOO_MANY_ENTRIES"
    case insufficientStorage = "E_INSUFFICIENT_STORAGE"
    case writeFailed = "E_WRITE_FAILED"
    case rateLimited = "E_RATE_LIMITED"
    case notImplemented = "E_NOT_IMPLEMENTED"
    case `internal` = "E_INTERNAL"
    case sessionPaused = "E_SESSION_PAUSED"
    case invalidState = "E_INVALID_STATE"
    case inviteNotActive = "E_INVITE_NOT_ACTIVE"
    case inviteFailed = "E_INVITE_FAILED"
    case inviteExhausted = "E_INVITE_EXHAUSTED"
    case inviteExpired = "E_INVITE_EXPIRED"
    case inviteBusy = "E_INVITE_BUSY"
    case inviteSuiteUnsupported = "E_INVITE_SUITE_UNSUPPORTED"
    case inviteTicketInvalid = "E_INVITE_TICKET_INVALID"
    case appMismatch = "E_APP_MISMATCH"
    case fingerprintChanged = "L_FINGERPRINT_CHANGED"
    case noLocalNetworkPermission = "L_NO_LOCAL_NETWORK_PERMISSION"
    case firewallBlocked = "L_FIREWALL_BLOCKED"
    case apIsolation = "L_AP_ISOLATION"
    case inviteNoCandidate = "L_INVITE_NO_CANDIDATE"
    case inviteCodeWrong = "L_INVITE_CODE_WRONG"
    case webShareNoLAN = "L_WEB_SHARE_NO_LAN"
    case webShareListenFailed = "L_WEB_SHARE_LISTEN_FAILED"
    case portUnavailable = "L_PORT_UNAVAILABLE"
}

public struct ProtocolError: Error, Sendable, Equatable {
    public var code: ProtocolErrorCode
    public var httpStatus: Int?
    public var retryable: Bool
    public var detail: [String: String]
    /// Integer `detail` fields such as `committedBytes`. Kept separate so string details stay strings.
    public var numericDetail: [String: Int]

    public init(
        code: ProtocolErrorCode,
        httpStatus: Int?,
        retryable: Bool,
        detail: [String: String] = [:],
        numericDetail: [String: Int] = [:]
    ) {
        self.code = code
        self.httpStatus = httpStatus
        self.retryable = retryable
        self.detail = detail
        self.numericDetail = numericDetail
    }

    /// `403`, not retryable, `detail.app` is the receiver's own app. No `detail.reason`.
    public static func appMismatch(localApp: String) -> ProtocolError {
        ProtocolError(code: .appMismatch, httpStatus: 403, retryable: false, detail: ["app": localApp])
    }

    /// In-group, different `app`, local address (protocol 1.2). `detail.reason` is `same_device`.
    public static func appMismatchSameDevice(localApp: String) -> ProtocolError {
        ProtocolError(
            code: .appMismatch,
            httpStatus: 403,
            retryable: false,
            detail: ["app": localApp, "reason": AppGate.sameDeviceReason]
        )
    }

    public static func offsetMismatch(committedBytes: Int) -> ProtocolError {
        ProtocolError(
            code: .offsetMismatch,
            httpStatus: 409,
            retryable: true,
            numericDetail: ["committedBytes": committedBytes]
        )
    }

    public var isLocalOnly: Bool {
        code.rawValue.hasPrefix("L_")
    }
}

public extension ProtocolErrorCode {
    /// Static mapping from protocol section 13. Local `L_` codes have no HTTP status.
    var specification: (httpStatus: Int?, retryable: Bool) {
        switch self {
        case .badRequest: return (400, false)
        case .unsupportedVersion: return (400, false)
        case .notPaired: return (401, false)
        case .pairCommitMismatch: return (400, false)
        case .pairRejected: return (403, false)
        case .pairTokenInvalid: return (403, false)
        case .pairExpired: return (410, false)
        case .rejected: return (403, false)
        case .decisionTimeout: return (408, true)
        case .busy: return (409, true)
        case .tokenInvalid: return (403, false)
        case .sessionNotFound: return (404, false)
        case .sessionExpired: return (410, false)
        case .sessionCancelled: return (410, false)
        case .offsetMismatch: return (409, true)
        case .checksumMismatch: return (422, true)
        case .pathInvalid: return (400, false)
        case .fileTooLarge: return (413, false)
        case .tooManyEntries: return (413, false)
        case .insufficientStorage: return (507, false)
        case .writeFailed: return (500, true)
        case .rateLimited: return (429, true)
        case .notImplemented: return (501, false)
        case .internal: return (500, true)
        case .sessionPaused: return (409, true)
        case .invalidState: return (409, false)
        case .inviteNotActive: return (404, false)
        case .inviteFailed: return (403, false)
        case .inviteExhausted: return (410, false)
        case .inviteExpired: return (410, false)
        case .inviteBusy: return (409, true)
        case .inviteSuiteUnsupported: return (400, false)
        case .inviteTicketInvalid: return (403, false)
        case .appMismatch: return (403, false)
        case .fingerprintChanged, .noLocalNetworkPermission, .firewallBlocked, .apIsolation,
             .inviteNoCandidate, .inviteCodeWrong, .webShareNoLAN, .webShareListenFailed, .portUnavailable:
            return (nil, false)
        }
    }
}

/// Failures returned by the future Rust core (protocol 15.10.7), mapped onto protocol codes.
public enum InviteCoreFailure: String, Sendable, Equatable, CaseIterable {
    case codeFormat = "CodeFormat"
    case suiteUnsupported = "SuiteUnsupported"
    case expired = "Expired"
    case exhausted = "Exhausted"
    case busy = "Busy"
    case notActive = "NotActive"
    case unknownAttempt = "UnknownAttempt"
    case invalidPeerMessage = "InvalidPeerMessage"
    case confirmMismatch = "ConfirmMismatch"
    case tagMismatch = "TagMismatch"
    case ticketMismatch = "TicketMismatch"
    case badState = "BadState"
    case rng = "Rng"
    case nullArg = "NullArg"
    case bufferLen = "BufferLen"
    case panic = "Panic"
}

public enum InviteCoreErrorMapping {
    public static func protocolError(for failure: InviteCoreFailure) -> ProtocolError {
        switch failure {
        case .codeFormat:
            return ProtocolError(code: .badRequest, httpStatus: nil, retryable: false, detail: ["core": failure.rawValue])
        case .suiteUnsupported:
            return ProtocolError(code: .inviteSuiteUnsupported, httpStatus: 400, retryable: false)
        case .expired:
            return ProtocolError(code: .inviteExpired, httpStatus: 410, retryable: false)
        case .exhausted:
            return ProtocolError(code: .inviteExhausted, httpStatus: 410, retryable: false)
        case .busy:
            return ProtocolError(code: .inviteBusy, httpStatus: 409, retryable: true)
        case .notActive:
            return ProtocolError(code: .inviteNotActive, httpStatus: 404, retryable: false)
        case .unknownAttempt, .invalidPeerMessage, .confirmMismatch:
            return ProtocolError(code: .inviteFailed, httpStatus: 403, retryable: false)
        case .tagMismatch:
            return ProtocolError(code: .inviteCodeWrong, httpStatus: nil, retryable: false)
        case .ticketMismatch:
            return ProtocolError(code: .inviteTicketInvalid, httpStatus: 403, retryable: false)
        case .badState, .rng, .nullArg, .bufferLen, .panic:
            return ProtocolError(code: .internal, httpStatus: 500, retryable: true, detail: ["core": failure.rawValue])
        }
    }
}

/// Host-facing result for a received protocol error. The Kit does not localize it.
public enum TransferHostError: Error, Equatable, Sendable {
    case sameDeviceOtherApp
    case appNotInInteropGroup
    case inviteTicketInvalid
    case wire(ProtocolError)
}

public enum TransferHostErrorMapping {
    public static func classify(_ error: ProtocolError) -> TransferHostError {
        switch error.code {
        case .appMismatch:
            if error.detail["reason"] == AppGate.sameDeviceReason {
                return .sameDeviceOtherApp
            }
            return .appNotInInteropGroup
        case .inviteTicketInvalid:
            return .inviteTicketInvalid
        default:
            return .wire(error)
        }
    }
}
