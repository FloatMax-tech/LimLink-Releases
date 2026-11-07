import LimLinkAppSupport
import SwiftUI

/// Offline usage guidance, with an optional link to the App Store's standard license.
struct UsageTermsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("用户协议与使用说明")).font(.title2.bold())
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }
                    .accessibilityIdentifier("terms.close")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L10n.text("运营主体：{0}", LegalResources.operatorName))
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("terms.operator")
                    Text(L10n.text("开发者：{0}", LegalResources.developerName))
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("terms.developer")
                    #if !LIMLINK_DIRECT_DISTRIBUTION
                    section(L10n.text("许可与适用说明"), L10n.text("通过 App Store 安装的 LimLink 适用 Apple 标准最终用户许可协议（EULA）。以下离线说明不替代该协议，也不限制法律赋予你的权利。"), identifier: "terms.license")
                    Link(L10n.text("查看 Apple 标准 EULA"), destination: LegalResources.standardEULAURL)
                        .accessibilityIdentifier("terms.eula")
                    #endif
                    section(L10n.text("分享前请确认"), L10n.text("仅分享你有权分享的文件。绑定须由发起方选择设备并点击「绑定」，再由对方确认；双方随后自动接收。名称可自行修改，请选择正确设备。"), identifier: "terms.sharing")
                    section(L10n.text("传输与保存"), L10n.text("两台设备须处于同一局域网，并在传输期间保持 LimLink 在前台运行。每次发送一个不超过 5 GB 的文件。请确保接收设备有足够空间，确认文件已完整收到后再删除原件。"), identifier: "terms.transfer")
                    section(L10n.text("支持与隐私"), L10n.text("支持页面按需在外部浏览器打开。联系支持时，请勿提交文件内容、密钥或私人日志。"), identifier: "terms.help")
                    Text(L10n.text("以下为官网用户协议第八节及第十节，供离线阅读；完整协议见官网。"))
                        .font(.caption).foregroundStyle(.secondary)
                    section(L10n.text("八、责任与权利保障"), L10n.text("官网协议第八节正文"), identifier: "terms.liability")
                    section(L10n.text("十、免责声明"), L10n.text("官网协议第十节正文"), identifier: "terms.disclaimer")
                    #if !LIMLINK_DIRECT_DISTRIBUTION
                    section(L10n.text("支持 LimLink"), L10n.text("Apple 可选支持付款说明"), identifier: "terms.payments")
                    #endif
                    Link(LegalResources.supportEmail, destination: LegalResources.supportEmailURL)
                        .accessibilityIdentifier("terms.email")
                    if LegalResources.isPublicationAvailable {
                        Link(L10n.text("在线查看完整协议"), destination: LegalResources.termsURL)
                            .accessibilityIdentifier("terms.online")
                        Link(L10n.text("联系与支持"), destination: LegalResources.supportURL)
                            .accessibilityIdentifier("terms.support")
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terms.usage")
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 580)
        #endif
    }

    private func section(_ title: String, _ body: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(body).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
    }
}
