import LimLinkAppSupport
import AppKit
import LimLinkKit
import SwiftUI

/// Menu bar popover: answer receive requests and watch the current transfer without opening the window.
struct MenuBarPanel: View {
    @Environment(MacTransferModel.self) private var model
    @EnvironmentObject private var folderStore: ReceiveFolderStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LimLinkMark(size: 22)
                Text("LimLink").font(.headline)
                Spacer()
                Circle().fill(model.startup.isReady ? Palette.signal : model.startupFailed ? Palette.danger : .orange)
                    .frame(width: 7, height: 7)
                Text(statusText).font(.callout).foregroundStyle(Palette.secondary)
            }

            if let offer = model.offer {
                offerCard(offer)
                    .id(offer.id)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }

            if let request = model.bindingRequest {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("设备绑定请求")).font(.headline)
                    Text(request.alias).font(.callout.weight(.semibold))
                        .accessibilityIdentifier("binding.request.name")
                    Text(L10n.text("确认绑定后，双方将自动接收彼此发送的文件。请确认这是你选择的设备，名称可自行修改。"))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.text("拒绝"), role: .cancel) { model.decideBinding(accept: false) }
                            .accessibilityIdentifier("binding.reject")
                        Button(L10n.text("确认绑定")) { model.decideBinding(accept: true) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("binding.accept")
                    }
                }
                .padding(14)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if let transfer = model.transfer {
                HStack(spacing: 12) {
                    ProgressRing(value: transfer.fraction, state: transfer.ringState, diameter: 40, lineWidth: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transfer.fileName).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Text(transferDetail(transfer))
                            .font(.caption)
                            .foregroundStyle(transfer.ringState == .failed ? Palette.danger : Palette.secondary)
                            .monospacedDigit()
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if model.isSending {
                        Button(L10n.text("取消")) { model.cancelSend() }
                            .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 28))
                            .fixedSize()
                    } else {
                        Button(L10n.text("清除")) { model.dismissTransfer() }
                            .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 28))
                            .fixedSize()
                    }
                }
                .riseIn()
            }

            if model.receivingCount > 0 {
                HStack(spacing: 12) {
                    ProgressRing(value: 0, state: .waiting, diameter: 40, lineWidth: 4)
                    Text(L10n.text("正在接收 {0} 个文件，校验后保存", String(describing: model.receivingCount))).font(.callout)
                }
                .riseIn()
            }

            if model.offer == nil && model.bindingRequest == nil && model.transfer == nil && model.receivingCount == 0 {
                Text(L10n.text("没有进行中的传输")).font(.callout).foregroundStyle(Palette.secondary)
            }

            Divider().overlay(Palette.stroke)
            HStack {
                Button(L10n.text("打开 LimLink")) { MainWindowOpener.shared.show() }
                Spacer()
                Button(L10n.text("退出")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Palette.secondary)
        }
        .foregroundStyle(Palette.ink)
        .padding(16)
        .frame(width: 320)
        .animation(reduceMotion ? nil : Motion.pop(0.42), value: model.offer?.id)
        .animation(reduceMotion ? nil : Motion.smooth(0.42), value: model.transfer == nil)
    }

    private func offerCard(_ offer: IncomingOffer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("{0} 想发送", String(describing: offer.senderName))).font(.callout.weight(.semibold))
            HStack(spacing: 10) {
                Image(systemName: fileSymbol(offer.fileName))
                    .frame(width: 36, height: 36)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.fileName).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    Text(L10n.text("{0} · 保存到 {1}", String(describing: formatSize(offer.size)), String(describing: offer.saveLocation ?? folderStore.decision.displayName)))
                        .font(.caption).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                Button(L10n.text("拒绝")) { model.decideOffer(id: offer.id, accept: false) }
                    .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 32))
                    .accessibilityIdentifier("receive.reject")
                Button(L10n.text("接收")) { model.decideOffer(id: offer.id, accept: true) }
                    .buttonStyle(TransferCapsuleButtonStyle(height: 32))
                    .accessibilityIdentifier("receive.accept")
            }
            TimelineView(.periodic(from: offer.receivedAt, by: 1)) { context in
                let remaining = max(120 - Int(context.date.timeIntervalSince(offer.receivedAt)), 0)
                Text(model.queuedOfferCount > 0 ? L10n.text("{0} 秒后自动拒绝 · 还有 {1} 个请求", String(describing: remaining), String(describing: model.queuedOfferCount)) : L10n.text("{0} 秒后自动拒绝", String(describing: remaining)))
                    .font(.caption)
                    .foregroundStyle(Palette.faint)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusText: String {
        switch model.startup {
        case .ready: L10n.text("已就绪")
        case .starting, .stopped: L10n.text("正在连接")
        case .failed: L10n.text("连接失败")
        }
    }

    private func transferDetail(_ transfer: TransferProgress) -> String {
        let peer = transfer.peerName ?? L10n.text("附近设备")
        switch transfer.state {
        case .sending: return L10n.text("发给 {0} · {1}%", String(describing: peer), String(describing: Int(transfer.fraction * 100)))
        case .failed(let reason): return reason.text
        default: return L10n.text("发给 {0} · {1}", String(describing: peer), String(describing: transfer.statusTitle))
        }
    }
}

extension MacTransferModel {
    var startupFailed: Bool { if case .failed = startup { return true }; return false }
}
