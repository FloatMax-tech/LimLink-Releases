import LimLinkAppSupport
import StoreKit
import SwiftUI

@MainActor
struct SupportLimLinkView: View {
    @State private var purchases = SupportPurchases.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L10n.text("支持完全自愿，不会解锁功能。所有传输功能始终免费。"))
                    Text(L10n.text("通过 Apple 一次性付款，可重复支持，无需订阅。"))
                        .font(.callout).foregroundStyle(.secondary)
                    if purchases.loading {
                        ProgressView(L10n.text("正在加载支持选项…"))
                    }
                    ForEach(SupportPurchasePolicy.productIDs, id: \.self) { id in
                        if let product = purchases.products.first(where: { $0.id == id }) {
                            Button {
                                Task { await purchases.purchase(product) }
                            } label: {
                                HStack {
                                    Text(L10n.text(tierKey(id)))
                                    Spacer()
                                    Text(verbatim: product.displayPrice)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!purchases.canPurchase)
                            .accessibilityIdentifier(id)
                        }
                    }
                    if purchases.loadFailed {
                        Text(L10n.text("部分支持选项暂不可用。请检查网络连接后重试。"))
                            .foregroundStyle(.secondary)
                        Button(L10n.text("重试")) { Task { await purchases.loadProducts() } }
                            .disabled(purchases.loading || purchases.outcome == .purchasing)
                            .accessibilityIdentifier("support.retry")
                    }
                    if purchases.canRetryPending {
                        Text(L10n.text("先在 Apple 账户中确认待批准付款。再次支持不会取消原付款，原付款仍可能获批。"))
                            .font(.callout).foregroundStyle(.secondary)
                        Button(L10n.text("我已检查，允许再次支持")) { purchases.allowAnotherSupport() }
                            .accessibilityIdentifier("support.pending.retry")
                    }
                    if let message = statusKey {
                        HStack(alignment: .top) {
                            if purchases.outcome == .purchasing { ProgressView() }
                            Text(L10n.text(message))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("support.status")
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(L10n.text("支持 LimLink"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("关闭")) { dismiss() }
                        .accessibilityIdentifier("support.close")
                }
            }
            .task { await purchases.loadProducts() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 460)
        #endif
    }

    private func tierKey(_ id: String) -> String {
        switch id {
        case "com.limlink.tip.small": "小份心意"
        case "com.limlink.tip.medium": "暖心支持"
        default: "慷慨支持"
        }
    }

    private var statusKey: String? {
        switch purchases.outcome {
        case .idle: nil
        case .purchasing: "正在等待 Apple 确认…"
        case .pending: "付款正在等待批准。Apple 确认后会自动更新，请勿重复付款。"
        case .cancelled: "已取消付款。你可以继续免费使用 LimLink。"
        case .failed: "付款未完成。请检查网络或 Apple 账户后重试。"
        case .unverified: "无法验证付款，尚未确认支持成功。请稍后重新打开此页面。"
        case .unknown: "Apple 尚未确认付款结果。请稍后重新打开此页面。"
        case .completed: "感谢支持 LimLink！付款已由 Apple 确认。"
        }
    }
}
