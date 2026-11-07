import Foundation

/// Why starting the local listener failed, in terms that decide whether trying again can help.
public enum StartupFailure: Error, Equatable, Sendable {
    /// Local Network permission is off, still being asked for, or was refused (DNSService -65570 / -65555).
    case localNetworkPermission
    case timedOut
    case addressInUse
    case networkDown
    case other(String)

    public var isTransient: Bool {
        switch self {
        case .other: false
        case .localNetworkPermission, .timedOut, .addressInUse, .networkDown: true
        }
    }
}

public enum StartupRecovery {
    public static let permissionDeniedDNS: Int32 = -65_570
    public static let noAuthDNS: Int32 = -65_555

    /// Classifies a listener failure. `nil` means that kind of failure did not occur.
    public static func classify(
        dnsCode: Int32? = nil,
        posixCode: Int32? = nil,
        timedOut: Bool = false,
        addressInUse: Bool = false
    ) -> StartupFailure {
        if addressInUse { return .addressInUse }
        if timedOut { return .timedOut }
        if let dnsCode {
            if dnsCode == permissionDeniedDNS || dnsCode == noAuthDNS { return .localNetworkPermission }
            // Other DNS failures while advertising are usually a transient mDNS state.
            return .networkDown
        }
        if let posixCode {
            switch posixCode {
            case ENETDOWN, ENETUNREACH, EADDRNOTAVAIL, ENOBUFS, EAGAIN, ECONNABORTED, ETIMEDOUT:
                return .networkDown
            case EADDRINUSE:
                return .addressInUse
            default:
                return .other("POSIX \(posixCode)")
            }
        }
        return .other(L10n.text("未知错误"))
    }

    /// Delays between attempts. The last value repeats for `maxAttempts`. A bind timeout already
    /// waited 15 seconds, so it gets a single, slightly longer retry.
    public static func retryDelays(for failure: StartupFailure) -> [Duration] {
        switch failure {
        case .timedOut: [.seconds(1.5)]
        case .addressInUse: [.milliseconds(500), .seconds(1)]
        case .localNetworkPermission, .networkDown: [.milliseconds(300), .milliseconds(900), .seconds(2)]
        case .other: []
        }
    }

    /// The startup state shown while waiting for the local network prompt to be answered.
    public static func waitingTitle(_ failure: StartupFailure) -> String? { localizedWaitingTitle(failure)?.text }

    public static func localizedWaitingTitle(_ failure: StartupFailure) -> LocalizedMessage? {
        failure == .localNetworkPermission ? L10n.message("正在等待本地网络权限") : nil
    }

    public static func message(for failure: StartupFailure) -> String { localizedMessage(for: failure).text }

    public static func localizedMessage(for failure: StartupFailure) -> LocalizedMessage {
        switch failure {
        case .localNetworkPermission:
            return L10n.message("请允许 LimLink 使用本地网络：打开「设置 › 隐私与安全性 › 本地网络」并打开 LimLink，然后重试。")
        case .timedOut:
            return L10n.message("局域网还没准备好。请确认已连接 Wi-Fi，然后重试。")
        case .addressInUse:
            return L10n.message("网络端口被其他程序占用，请稍后重试。")
        case .networkDown:
            return L10n.message("网络未连接或正在切换。请连接 Wi-Fi 后重试。")
        case .other(let detail):
            return L10n.message("无法启动局域网连接（{0}），请重试。", String(describing: detail))
        }
    }
}
