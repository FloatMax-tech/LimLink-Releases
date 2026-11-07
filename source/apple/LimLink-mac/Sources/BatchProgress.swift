import LimLinkAppSupport
import Foundation

enum TransferDirection: Equatable {
    case sending
    case receiving

    var centerCaption: String {
        switch self {
        case .sending: return L10n.text("发给")
        case .receiving: return L10n.text("来自")
        }
    }
}

enum BatchProgressPhase: Equatable {
    /// 还没开始。仪表盘只留轨道，Dock 仍用系统图标。
    case idle
    case active
    case indeterminate
    case paused(reason: String)
    case completed(verified: Bool)
    case failed(summary: String)
}

/// 来自真实传输确认状态的进度，用于窗口、Dock 和菜单栏。
struct BatchProgressSnapshot: Equatable {
    var direction: TransferDirection
    var peerName: String
    var bytesTransferred: Int64
    var totalBytes: Int64?
    var totalBytesKnown: Bool
    var speedBytesPerSecond: Double?
    var secondsRemaining: TimeInterval?
    /// 从 1 开始。
    var currentIndex: Int
    var totalCount: Int
    var phase: BatchProgressPhase

    var fraction: Double? {
        switch phase {
        case .completed:
            return 1
        case .idle, .indeterminate:
            return nil
        case .active, .paused, .failed:
            guard totalBytesKnown, let totalBytes, totalBytes > 0 else { return nil }
            return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
        }
    }
}

/// 可供窗口、Dock 和菜单栏消费的进度来源。
protocol TransferProgressSource: AnyObject {
    var progressSnapshot: BatchProgressSnapshot { get }
}

enum ByteCountText {
    static func fileCount(_ bytes: Int64, locale: Locale) -> String {
        let style = ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: false
        ).locale(locale)
        return bytes.formatted(style)
    }

    static func speed(_ bytesPerSecond: Double, locale: Locale) -> String {
        fileCount(Int64(bytesPerSecond.rounded()), locale: locale) + "/s"
    }
}

enum RemainingTimeText {
    static func phrase(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return L10n.text("正在估算…") }
        if seconds < 60 {
            return L10n.text("剩余约 {0} 秒", String(describing: max(1, Int(seconds.rounded()))))
        }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return L10n.text("剩余约 {0} 分钟", String(describing: max(1, minutes)))
        }
        let hours = max(1, Int((Double(minutes) / 60).rounded()))
        return L10n.text("剩余约 {0} 小时", String(describing: hours))
    }
}

enum DialCaption {
    static func percentage(_ snapshot: BatchProgressSnapshot) -> String? {
        switch snapshot.phase {
        case .idle, .indeterminate, .completed, .failed:
            return nil
        case .active, .paused:
            guard let fraction = snapshot.fraction else { return nil }
            return "\(Int((fraction * 100).rounded()))%"
        }
    }

    static func detail(_ snapshot: BatchProgressSnapshot) -> String {
        switch snapshot.phase {
        case .idle:
            return L10n.text("还没有开始")
        case .active:
            let time = RemainingTimeText.phrase(snapshot.secondsRemaining)
            return L10n.text("{0} · 第 {1} 个 / 共 {2} 个", String(describing: time), String(describing: snapshot.currentIndex), String(describing: snapshot.totalCount))
        case .indeterminate:
            return L10n.text("第 {0} 个 / 共 {1} 个 · 大小未知", String(describing: snapshot.currentIndex), String(describing: snapshot.totalCount))
        case .paused(let reason):
            return reason
        case .completed(let verified):
            if verified {
                return L10n.text("已完成 · {0} 个文件 · 已校验", String(describing: snapshot.totalCount))
            }
            return L10n.text("已完成 · {0} 个文件", String(describing: snapshot.totalCount))
        case .failed(let summary):
            return summary
        }
    }
}

enum DialAccessibility {
    static func label(for snapshot: BatchProgressSnapshot) -> String {
        "\(snapshot.direction.centerCaption) \(snapshot.peerName)"
    }

    /// 速率不放进值里，避免 VoiceOver 一直播报（规范 6.11）。
    static func value(for snapshot: BatchProgressSnapshot, locale: Locale = L10n.locale) -> String {
        switch snapshot.phase {
        case .idle:
            return L10n.text("还没有开始")
        case .indeterminate:
            let amount = ByteCountText.fileCount(snapshot.bytesTransferred, locale: locale)
            return L10n.text("进度未知，已传 {0}", String(describing: amount))
        case .paused:
            let percent = DialCaption.percentage(snapshot) ?? ""
            if percent.isEmpty {
                return L10n.text("已暂停")
            }
            return L10n.text("已暂停，{0}", String(describing: percent))
        case .completed:
            return L10n.text("已完成")
        case .failed(let summary):
            return summary
        case .active:
            let percent = DialCaption.percentage(snapshot) ?? ""
            let remaining = RemainingTimeText.phrase(snapshot.secondsRemaining)
            return L10n.text("{0}，第 {1} 个，共 {2} 个，{3}", String(describing: percent), String(describing: snapshot.currentIndex), String(describing: snapshot.totalCount), String(describing: remaining))
        }
    }
}

enum DialCenterDensity: Equatable {
    /// 方向、设备名、速率都放在环里。
    case regular
    /// 辅助功能大字号时环里只留速率，设备名挪到环下面。
    case speedOnly
}

enum DialCenterLayout {
    static func density(isAccessibilitySize: Bool) -> DialCenterDensity {
        isAccessibilitySize ? .speedOnly : .regular
    }
}

/// AppKit 角度：0° 在 3 点钟，正方向是逆时针。进度从 12 点钟顺时针画。
struct RingArc: Equatable {
    var startAngle: CGFloat
    var endAngle: CGFloat
    var clockwise: Bool
}

enum RingGeometry {
    static func arc(fraction: Double) -> RingArc {
        let clamped = min(1, max(0, fraction))
        return RingArc(
            startAngle: 90,
            endAngle: 90 - CGFloat(clamped * 360),
            clockwise: true
        )
    }
}
