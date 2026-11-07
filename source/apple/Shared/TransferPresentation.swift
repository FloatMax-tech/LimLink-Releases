import LimLinkAppSupport
import Foundation
import LimLinkKit
import SwiftUI

// Presentation shared by the iOS and macOS apps. Each app defines the same
// `TransferProgress`, `TransferProgressState` and `StartupState` model types.

extension TransferProgress {
    var ringState: RingState {
        switch state {
        case .connecting, .waitingForReceiver: .waiting
        case .sending, .finishing: .running
        case .paused: .paused
        case .completed: .done
        case .cancelled, .failed: .failed
        }
    }

    var statusTitle: String {
        switch state {
        case .connecting: L10n.text("正在连接")
        case .waitingForReceiver: L10n.text("等待对方接收")
        case .sending: bytesTotal == 0 ? L10n.text("正在发送空文件") : L10n.text("正在发送")
        case .finishing: L10n.text("等待对方校验并保存")
        case .paused: L10n.text("传输已暂停")
        case .completed: L10n.text("已送达")
        case .cancelled: L10n.text("已取消")
        case .failed: L10n.text("传输失败")
        }
    }

    /// “第 2/3 台” while sending to several devices, nil for a single recipient.
    var batchLabel: String? {
        batchCount > 1 ? L10n.text("第 {0}/{1} 台", String(describing: batchPosition), String(describing: batchCount)) : nil
    }

    /// Stable key for "state changed" entrance motion; progress ticks do not count.
    var phaseKey: String {
        switch state {
        case .failed: "failed"
        default: String(describing: state)
        }
    }
}

func formatRate(_ bytesPerSecond: Double?) -> String? {
    guard let rate = bytesPerSecond, rate > 0 else { return nil }
    return "\(formatSize(Int(rate)))/s"
}

func formatRemaining(_ seconds: Double?) -> String? {
    guard let seconds, seconds.isFinite else { return nil }
    if seconds < 60 { return L10n.text("约 {0} 秒", String(describing: max(Int(seconds.rounded(.up)), 1))) }
    if seconds < 3600 { return L10n.text("约 {0} 分钟", String(describing: Int((seconds / 60).rounded(.up)))) }
    return L10n.text("约 {0} 小时", String(describing: Int((seconds / 3600).rounded(.up))))
}

// MARK: - Step bar

/// Connect → receiver approves → transfer → verify and save. Verification can take up to 30 minutes,
/// so it is shown as its own step.
struct TransferStepBar: View {
    let progress: TransferProgress
    private var titles: [String] { [L10n.text("连接"), L10n.text("对方同意"), L10n.text("传输"), L10n.text("校验保存")] }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { index in
                    if index > 0 { Rectangle().fill(Palette.faint.opacity(0.6)).frame(width: 14, height: 1) }
                    step(index)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(titles.indices, id: \.self) { step($0) }
            }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("传输步骤"))
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("transfer.progress.steps")
    }

    private enum Phase { case done, now, failed, pending }

    private func phase(_ index: Int) -> Phase {
        let current = progress.state.step ?? progress.reachedStep
        if progress.state.step == nil && index == current { return .failed }
        if index < current { return .done }
        if index == current { return .now }
        return .pending
    }

    private func step(_ index: Int) -> some View {
        let phase = phase(index)
        return HStack(spacing: 5) {
            ZStack {
                if phase == .now { PulseHalo(diameter: 16) }
                switch phase {
                case .done:
                    Circle().fill(Palette.ink)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Palette.paper)
                case .now:
                    Circle().fill(Palette.paper)
                    Circle().strokeBorder(Palette.signal, lineWidth: 1.5)
                    Circle().fill(Palette.signal).frame(width: 6, height: 6)
                case .failed:
                    Circle().fill(Palette.danger)
                    Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                case .pending:
                    Circle().strokeBorder(Palette.faint, lineWidth: 1.5)
                }
            }
            .frame(width: 16, height: 16)
            Text(titles[index])
                .fontWeight(phase == .now ? .semibold : .regular)
                .foregroundStyle(color(phase))
                .lineLimit(1)
        }
        .animation(.easeOut(duration: 0.25), value: progress.state)
    }

    private func color(_ phase: Phase) -> Color {
        switch phase {
        case .done: Palette.ink
        case .now: Palette.signalText
        case .failed: Palette.danger
        case .pending: Palette.secondary
        }
    }

    private var accessibilityValue: String {
        if progress.state == .completed { return L10n.text("全部完成") }
        let index = min(progress.state.step ?? progress.reachedStep, 3)
        if progress.state.step == nil {
            return L10n.text("停在第 {0} 步，共 4 步：{1}", String(index + 1), titles[index])
        }
        return L10n.text("当前第 {0} 步，共 4 步：{1}", String(index + 1), titles[index])
    }
}

func fileSymbol(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp": "photo"
    case "mov", "mp4", "m4v", "avi", "mkv", "webm": "play.rectangle"
    case "mp3", "m4a", "wav", "aac", "flac": "waveform"
    case "zip", "rar", "7z", "gz", "tar": "doc.zipper"
    default: "doc"
    }
}

func deviceKind(_ peer: DiscoveredService) -> String {
    switch peer.fields.deviceType?.lowercased() {
    case "iphone": "iPhone"
    case "ipad": "iPad"
    case "mac": "Mac"
    case "android": "Android"
    case "windows": "Windows"
    default: appName(peer)
    }
}

func formatSize(_ bytes: Int) -> String {
    guard bytes >= 1024 else { return L10n.text("{0} 字节", String(describing: max(bytes, 0))) }
    return L10n.byteCount(Int64(bytes))
}

func appName(_ peer: DiscoveredService) -> String {
    peer.app == "casecheck" ? "CaseCheck" : "LimLink"
}

func deviceSymbol(_ peer: DiscoveredService) -> String {
    switch peer.fields.deviceType?.lowercased() {
    case "iphone", "android": return "iphone"
    case "ipad": return "ipad"
    case "mac": return "laptopcomputer"
    default: return "desktopcomputer"
    }
}

extension StartupState {
    var isReady: Bool { if case .ready = self { return true }; return false }
}
