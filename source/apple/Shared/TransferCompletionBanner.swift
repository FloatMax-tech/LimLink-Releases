import LimLinkAppSupport
import SwiftUI

struct TransferCompletionBanner: View {
    let completion: FileTransferCompletion?
    let dismiss: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        Group {
            if let completion {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Palette.signal.opacity(0.14))
                        Circle().trim(from: 0, to: drawn ? 1 : 0).stroke(Palette.signal, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                        CompletionTick().trim(from: 0, to: drawn ? 1 : 0).stroke(Palette.signal, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)).padding(10)
                    }.frame(width: 40, height: 40).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text(completion.direction == .receiving ? "接收完成" : "发送完成")).font(.headline)
                        Text(completion.fileName).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: 460)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.signal.opacity(0.25)))
                .padding()
                .id(completion.id)
                .task(id: completion.id) {
                    drawn = false
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { drawn = true }
                    do { try await Task.sleep(for: .seconds(4)); dismiss(completion.id) } catch { }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("transfer.completion.\(completion.direction == .receiving ? "received" : "sent")")
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: completion?.id)
        .allowsHitTesting(false)
    }
}

private struct CompletionTick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
