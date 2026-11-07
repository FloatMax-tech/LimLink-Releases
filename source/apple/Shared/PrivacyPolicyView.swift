import LimLinkAppSupport
import SwiftUI

/// Readable offline; public links are shown only while publication is available.
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("隐私政策")).font(.title2.bold())
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }
                    .accessibilityIdentifier("privacy.close")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L10n.text("最后更新：2026年10月25日"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("运营主体：{0}", LegalResources.operatorName))
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("privacy.operator")
                    Text(L10n.text("开发者：{0}", LegalResources.developerName))
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("privacy.developer")
                    section(L10n.text("本地处理"), L10n.text("你选择的文件、设备名称和偏好在本机处理。LimLink 无需账号，不含广告或分析追踪，也不把文件上传到开发者的服务器。"), identifier: "privacy.local")
                    section(L10n.text("设备之间的传输"), L10n.text("同一局域网的参与者可看到设备名称、类型、连接地址和公开身份指纹。加密连接后，接收方可看到文件名称和大小。已绑定设备自动接收，其他设备逐文件确认。"), identifier: "privacy.discovery")
                    section(L10n.text("设备绑定"), L10n.text("设备绑定记录仅保存在本机，可在「设备绑定」中解绑。绑定设备之间自动接收文件；未绑定或绑定不完整时仍逐文件确认。"), identifier: "privacy.binding")
                    section(L10n.text("分享扩展"), L10n.text("分享扩展通过本机共享容器交接文件，不使用系统剪贴板。已完成暂存但尚未导入的分享副本会保留至成功交接或卸载；未完成的旧暂存副本会在后续使用时清理。"), identifier: "privacy.share")
                    section(L10n.text("文件与记录"), L10n.text("收到的文件保存在本机或你选择的文件夹，可能在重启后仍保留；部分传输记录仅在本次会话中显示。删除文件可能移至系统「废纸篓」或「最近删除」，请在相应位置管理。"), identifier: "privacy.storage")
                    section(L10n.text("文件预览与相册"), L10n.text("文件预览在本机完成，不需要上传文件。图片自动存入相册时，仅请求系统添加权限，不读取整个相册；相册可能按系统设置同步。") + "\n\n" + L10n.text("接收目录与相册保留各自副本。删除接收记录不会删除相册副本，可在本机身份中关闭自动保存。"), identifier: "privacy.photos")
                    section(L10n.text("权限与通知"), L10n.text("本地网络和通知权限可在系统设置中更改。通知可能显示设备和文件名称；你可以在系统通知设置中控制预览。"), identifier: "privacy.notifications")
                    section(L10n.text("在线页面与支持"), L10n.text("在线政策与支持页面按需在外部浏览器打开，适用相应网站的隐私规则。联系支持时，请勿提交文件内容、密钥或私人日志。"), identifier: "privacy.external")
                    #if !LIMLINK_DIRECT_DISTRIBUTION
                    section(L10n.text("支持 LimLink"), L10n.text("Apple 可选支持付款说明"), identifier: "privacy.payments")
                    #else
                    section(L10n.text("检查更新"), L10n.text("仅在点击时向官网查询版本信息，不上传文件、设备名称或绑定记录。") + "\n\n" + L10n.text("官网会收到 IP 地址及常规请求信息；版本查询不使用账号或追踪标识。"), identifier: "privacy.updates")
                    #endif
                    Link(LegalResources.supportEmail, destination: LegalResources.supportEmailURL)
                        .accessibilityIdentifier("privacy.email")
                    if LegalResources.isPublicationAvailable {
                        Link(L10n.text("在线查看完整政策"), destination: LegalResources.privacyURL)
                            .accessibilityIdentifier("privacy.online")
                        Link(L10n.text("联系与支持"), destination: LegalResources.supportURL)
                            .accessibilityIdentifier("privacy.support")
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy.policy")
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
