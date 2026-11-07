import CoreServices
import Foundation

/// 收到的文件要带隔离标记。只写「LimLink」和时间，不写对方 IP 或设备名（Mac 方案 4.9）。
struct QuarantineStamp: Equatable {
    var agentName: String
    var timestamp: Date
    var includesOriginURL: Bool
    var includesDataURL: Bool
    var includesAgentBundleIdentifier: Bool
}

enum QuarantinePolicy {
    static let agentName = "LimLink"

    static func stamp(at date: Date) -> QuarantineStamp {
        QuarantineStamp(
            agentName: agentName,
            timestamp: date,
            includesOriginURL: false,
            includesDataURL: false,
            includesAgentBundleIdentifier: false
        )
    }
}

enum QuarantineMarker {
    static func properties(at date: Date) -> [String: Any] {
        [
            kLSQuarantineAgentNameKey as String: QuarantinePolicy.agentName,
            kLSQuarantineTimeStampKey as String: date as NSDate,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
    }

    static func apply(to fileURL: URL, now: Date = Date()) throws {
        try (fileURL as NSURL).setResourceValue(properties(at: now), forKey: .quarantinePropertiesKey)
    }
}
