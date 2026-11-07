import LimLinkAppSupport
import LimLinkKit
import SwiftUI

// MARK: - Full-page dial (iPhone)

@MainActor
struct TransferDialView: View {
    let model: TransferModel
    let progress: TransferProgress
    let finish: () -> Void
    @State private var failures = 0

    var body: some View {
        VStack(spacing: 24) {
            if let peer = progress.peerName {
                HStack(spacing: 6) {
                    Image(systemName: peerSymbol).foregroundStyle(Palette.secondary)
                    Text(L10n.text("发送给")).foregroundStyle(Palette.secondary)
                    Text(peer).fontWeight(.semibold)
                    if let batch = progress.batchLabel {
                        Text("· \(batch)").foregroundStyle(Palette.secondary)
                    }
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }

            ZStack {
                ProgressRing(value: progress.fraction, state: progress.ringState, diameter: 250, lineWidth: 22)
                center
                    .id(progress.ringState == .running || progress.ringState == .paused ? "bytes" : progress.phaseKey)
                    .riseIn()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progress.statusTitle)
            .accessibilityValue(progress.bytesTotal > 0 ? L10n.text("{0}%，{1}，共 {2}", String(describing: Int(progress.fraction * 100)), String(describing: formatSize(progress.bytesSent)), String(describing: formatSize(progress.bytesTotal))) : "")

            VStack(spacing: 6) {
                Text(progress.fileName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                status
                    .id(progress.phaseKey)
                    .riseIn()
                    .accessibilityIdentifier("transfer.progress.status")
            }

            if progress.state == .sending, let rate = formatRate(progress.bytesPerSecond) {
                HStack(spacing: 28) {
                    stat(rate, L10n.text("速度"))
                    if let remaining = formatRemaining(progress.secondsRemaining) { stat(remaining, L10n.text("剩余")) }
                }
                .transition(.opacity)
            }

            TransferStepBar(progress: progress)

            actions
                .id(model.isSending)
                .riseIn()

            if model.isSending {
                Text(L10n.text("请保持 LimLink 在前台，直到完成"))
                    .font(.caption)
                    .foregroundStyle(Palette.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: progress.phaseKey) { _, key in if key == "failed" { failures += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer.progress")
    }

    @ViewBuilder
    private var center: some View {
        switch progress.ringState {
        case .running, .paused:
            VStack(spacing: 2) {
                Text("\(Int(progress.fraction * 100))%")
                    .font(.system(size: 46, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: progress.fraction))
                    .animation(Motion.ringGlide, value: Int(progress.fraction * 100))
                Text("\(formatSize(progress.bytesSent)) / \(formatSize(progress.bytesTotal))")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .monospacedDigit()
            }
        case .waiting:
            Text(progress.statusTitle)
                .font(.headline)
                .foregroundStyle(Palette.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(Palette.danger)
                .shake(trigger: failures)
        case .done:
            EmptyView()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch progress.state {
        case .failed(let reason):
            VStack(spacing: 4) {
                Text(L10n.text("传输失败")).foregroundStyle(Palette.danger).fontWeight(.semibold)
                Text(reason.text).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            }
            .font(.subheadline)
        case .completed:
            Text(L10n.text("已送达，对方已校验并保存")).font(.subheadline).foregroundStyle(Palette.signalText)
        default:
            Text(progress.statusTitle).font(.subheadline).foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.isSending {
            Button(role: .destructive, action: model.cancelSend) {
                Label(L10n.text("取消发送"), systemImage: "stop.circle")
            }
            .buttonStyle(TransferCapsuleButtonStyle(emphasis: .destructive))
            .accessibilityIdentifier("transfer.cancel")
        } else if progress.state == .completed {
            Button(L10n.text("完成"), action: finish)
                .buttonStyle(TransferCapsuleButtonStyle())
                .accessibilityIdentifier("transfer.finish")
        } else {
            Button {
                model.dismissTransfer()
            } label: {
                Label(L10n.text("重新选择设备"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary))
            .accessibilityIdentifier("transfer.retry")
        }
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit().contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var peerSymbol: String {
        model.devices.first { model.peerID($0) == progress.peerID }.map(deviceSymbol) ?? "desktopcomputer"
    }
}

// MARK: - Compact row (home, iPad)

@MainActor
struct TransferProgressRow: View {
    let model: TransferModel
    let progress: TransferProgress
    var open: (() -> Void)?
    @State private var failures = 0

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                ProgressRing(value: progress.fraction, state: progress.ringState, diameter: 72, lineWidth: 8, showsCheck: true)
                if progress.ringState == .running || progress.ringState == .paused {
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progress.fraction))
                        .animation(Motion.ringGlide, value: Int(progress.fraction * 100))
                } else if progress.ringState == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                        .shake(trigger: failures)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(progress.ringState == .failed ? Palette.danger : Palette.signalText)
                    .id(progress.phaseKey)
                    .riseIn()
                    .accessibilityIdentifier("transfer.progress.status")
                Text(progress.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if model.isSending {
                Button(L10n.text("取消"), role: .destructive, action: model.cancelSend)
                    .buttonStyle(TransferCapsuleButtonStyle(emphasis: .destructive, height: 36))
                    .fixedSize()
                    .accessibilityIdentifier("transfer.cancel")
            } else {
                Button(progress.state == .completed ? L10n.text("完成") : L10n.text("关闭")) { model.dismissTransfer() }
                    .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 36))
                    .fixedSize()
                    .accessibilityIdentifier("transfer.dismiss")
            }
        }
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onTapGesture { open?() }
        .onChange(of: progress.phaseKey) { _, key in if key == "failed" { failures += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer.progress")
    }

    private var headline: String {
        let peer = progress.peerName ?? L10n.text("附近设备")
        switch progress.state {
        case .sending: return L10n.text("正在发送给 {0}", String(describing: peer))
        case .completed: return L10n.text("已送达 {0}", String(describing: peer))
        case .failed: return L10n.text("发送失败")
        default: return progress.statusTitle
        }
    }

    private var detail: String {
        if case .failed(let reason) = progress.state { return reason.text }
        var parts = ["\(formatSize(progress.bytesSent)) / \(formatSize(progress.bytesTotal))"]
        if let batch = progress.batchLabel { parts.insert(batch, at: 0) }
        if progress.state == .sending {
            if let rate = formatRate(progress.bytesPerSecond) { parts.append(rate) }
            if let remaining = formatRemaining(progress.secondsRemaining) { parts.append(remaining) }
        }
        return parts.joined(separator: " · ")
    }
}

