import LimLinkAppSupport
import Foundation
import SwiftUI

// Views shared by the iOS and macOS apps.

/// The file illustration built on the brand ring. Empty: a slowly turning dashed orbit.
/// Selected: the thick ring draws itself (900ms) and the file icon pops in (delay 160ms).
/// Give it a new identity per file so the draw-in replays.
struct FileRing: View {
    let fileName: String?
    var diameter: CGFloat = 144
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    var body: some View {
        let unit = diameter / 144
        ZStack {
            Circle().stroke(Palette.stroke, lineWidth: 1.5).frame(width: 128 * unit, height: 128 * unit)
            if let fileName {
                Circle()
                    .trim(from: 0, to: drawn)
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 10 * unit, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 104 * unit, height: 104 * unit)
                Image(systemName: fileSymbol(fileName))
                    .font(.system(size: 34 * unit, weight: .light))
                    .foregroundStyle(Palette.ink)
                    .popIn(delay: 0.16)
            } else {
                DashedOrbit(diameter: 104 * unit)
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 36 * unit, weight: .light))
                    .foregroundStyle(Palette.ink)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .onAppear {
            guard fileName != nil else { return }
            if reduceMotion { drawn = 1 } else { withAnimation(Motion.ringDraw) { drawn = 1 } }
        }
    }
}

/// Receive consent: who is sending, the file, where it will be saved, and the time left to answer.
struct IncomingFileCard: View {
    let senderName: String
    let fileName: String
    let size: Int
    var saveLocation: String
    var receivedAt = Date()
    var queued = 0
    var centered = false
    var buttonHeight: CGFloat = 52
    let accept: () -> Void
    let reject: () -> Void

    /// Matches the receiver's automatic rejection in the transfer models.
    private static let answerSeconds = 120

    var body: some View {
        VStack(spacing: 0) {
            if !centered {
                Capsule().fill(Palette.fill2).frame(width: 38, height: 5).padding(.bottom, 18)
            }
            VStack(spacing: 12) {
                ZStack {
                    ProgressRing(value: 0, state: .waiting, diameter: 64, lineWidth: 6)
                    Image(systemName: "arrow.down").font(.title2.weight(.medium))
                }
                VStack(spacing: 2) {
                    Text(senderName)
                        .accessibilityLabel(L10n.text("来自：{0}", String(describing: senderName)))
                    Text(L10n.text("想发送一个文件给你"))
                }
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Image(systemName: fileSymbol(fileName))
                    .font(.system(size: 18))
                    .frame(width: 40, height: 40)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName).font(.subheadline.weight(.semibold)).lineLimit(3)
                    Text(L10n.text("{0} · 保存到「{1}」", String(describing: formatSize(size)), String(describing: saveLocation)))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
            .padding(.top, 18)

            Text(L10n.text("名称由对方设备自行设置。接收后不会自动打开。"))
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)

            VStack(spacing: 10) {
                Button(action: accept) { Text(L10n.text("接收")) }
                    .buttonStyle(TransferCapsuleButtonStyle(height: buttonHeight))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(L10n.text("确认接收"))
                    .accessibilityIdentifier("transfer.offer.accept")
                Button(action: reject) { Text(L10n.text("拒绝")) }
                    .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: buttonHeight))
                    .accessibilityLabel(L10n.text("拒绝接收"))
                    .accessibilityIdentifier("transfer.offer.reject")
            }

            TimelineView(.periodic(from: receivedAt, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(receivedAt))
                let remaining = max(Self.answerSeconds - elapsed, 0)
                VStack(spacing: 2) {
                    Text(L10n.text("{0} 秒后自动拒绝", String(describing: remaining)))
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.easeOut(duration: 0.2), value: remaining)
                        .accessibilityIdentifier("transfer.offer.countdown")
                    if queued > 0 {
                        Text(L10n.text("还有 {0} 个请求在等待", String(describing: queued))).accessibilityIdentifier("transfer.offer.queue")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.faint)
            .monospacedDigit()
            .padding(.top, 12)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 24)
        .padding(.top, centered ? 28 : 10)
        .padding(.bottom, centered ? 24 : 34)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: centered ? 30 : 38, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("transfer.offer")
    }
}

/// Dialog presentation: the scrim fades in, the card pops 0.9 → 1 (420ms); closing fades out
/// over 170ms while scaling to 0.98. Keyed by `id` so queued requests replace each other.
struct ConsentOverlay<Card: View>: View {
    let id: String?
    let centered: Bool
    @ViewBuilder let card: () -> Card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: centered ? .center : .bottom) {
            if let id {
                Palette.scrim
                    .ignoresSafeArea()
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.25)),
                        removal: .opacity.animation(.easeIn(duration: 0.17))
                    ))
                    .accessibilityHidden(true)
                card()
                    .id(id)
                    .transition(cardTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centered ? .center : .bottom)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.pop(0.42), value: id)
    }

    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.9, anchor: centered ? .center : .bottom).combined(with: .opacity),
            removal: .scale(scale: 0.98).combined(with: .opacity).animation(.easeIn(duration: 0.17))
        )
    }
}

/// Non-blocking message banner: slides down from the top (−10 → 0, 420ms), closes on tap or after
/// eight seconds, and is announced to VoiceOver.
struct MessageToast: View {
    let id: UUID?
    let text: String
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let id {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Palette.secondary)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("关闭"), systemImage: "xmark", action: dismiss)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("transfer.message.close")
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .id(id)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(y: -10).combined(with: .opacity),
                    removal: .opacity.animation(.easeIn(duration: 0.17))
                ))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transfer.message")
                .task(id: id) {
                    AccessibilityNotification.Announcement(text).post()
                    guard (try? await Task.sleep(for: .seconds(8))) != nil else { return }
                    dismiss()
                }
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.smooth(0.42), value: id)
    }
}

struct ReceivingProgressCard: View {
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            ProgressRing(value: 0, state: .waiting, diameter: 40, lineWidth: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(count > 1 ? L10n.text("正在接收 {0} 个文件", String(describing: count)) : L10n.text("正在接收或校验文件"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.text("完成校验后会显示在“已接收”中。"))
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.ink)
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transfer.receiving")
    }
}

/// A row that slides left to reveal a red “删除” button; a long swipe deletes right away.
/// Also offers 删除 in the context menu and as an accessibility action.
@MainActor
struct SwipeToDeleteRow<Content: View>: View {
    var title = L10n.text("删除")
    let delete: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var fileActions = RowFileActionGuard()
    @GestureState private var dragIsActive = false
    private var revealWidth: CGFloat { title.count > 2 ? 108 : 84 }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: performDelete) {
                Label(title, systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleOnly)
                    .foregroundStyle(.white)
                    .frame(width: max(revealWidth, -offset), alignment: .center)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Palette.danger)
            .opacity(offset < -1 ? 1 : 0)
            .accessibilityHidden(offset > -1)
            .accessibilityIdentifier("transfer.received.delete")

            content()
                .environment(\.mayActivateReceivedFile) { [fileActions] in fileActions.allowsActivation }
                .background(Palette.surface)
                .offset(x: offset)
                .simultaneousGesture(drag)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: dragIsActive) { _, active in if !active { fileActions.finishHorizontalSwipe() } }
        .onDisappear { fileActions.finishHorizontalSwipe() }
        .contextMenu {
            Button(title, systemImage: "trash", role: .destructive, action: performDelete)
        }
        .accessibilityAction(named: Text(title), performDelete)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($dragIsActive) { _, active, _ in active = true }
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                fileActions.recordHorizontalSwipe()
                offset = min(0, settled + value.translation.width)
            }
            .onEnded { value in
                fileActions.finishHorizontalSwipe()
                guard abs(value.translation.width) > abs(value.translation.height) else { return settle(to: settled) }
                // Judge a quick flick by where it was heading, not just by the distance covered.
                let reached = min(value.translation.width, value.predictedEndTranslation.width)
                if width > 0, -reached > width * 0.55 { performDelete() }
                else { settle(to: -reached > revealWidth / 2 ? -revealWidth : 0) }
            }
    }

    private func settle(to target: CGFloat) {
        settled = target
        withAnimation(reduceMotion ? nil : Motion.smooth(0.32)) { offset = target }
    }

    private func performDelete() {
        withAnimation(reduceMotion ? nil : Motion.smooth(0.28)) { offset = -max(width, revealWidth) }
        delete()
    }
}

private struct ReceivedFileActivationKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Bool = { true }
}

extension EnvironmentValues {
    var mayActivateReceivedFile: @MainActor @Sendable () -> Bool {
        get { self[ReceivedFileActivationKey.self] }
        set { self[ReceivedFileActivationKey.self] = newValue }
    }
}

/// Reference identity lets a child action consult the latest drag state in the same event turn.
@MainActor
private final class RowFileActionGuard {
    private var gate = FileActionActivationGate()
    var allowsActivation: Bool { gate.allowsActivation(uptime: ProcessInfo.processInfo.systemUptime) }
    func recordHorizontalSwipe() { gate.recordHorizontalSwipe(uptime: ProcessInfo.processInfo.systemUptime) }
    func finishHorizontalSwipe() { gate.endHorizontalSwipe(uptime: ProcessInfo.processInfo.systemUptime) }
}
