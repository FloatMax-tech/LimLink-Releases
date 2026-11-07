#if LIMLINK_DIRECT_DISTRIBUTION
import LimLinkAppSupport
import SwiftUI

struct DirectUpdateControl: View {
    @Environment(\.openURL) private var openURL
    @State private var checking = false
    @State private var status = ""
    @State private var available: WebsiteUpdate?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(L10n.text(checking ? "正在检查更新…" : "检查更新"), systemImage: "arrow.clockwise", action: check)
                .disabled(checking)
                .accessibilityIdentifier("updates.check")
            Text(L10n.text("仅在点击时向官网查询版本信息，不上传文件、设备名称或绑定记录。"))
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.callout).accessibilityIdentifier("updates.status") }
            if let available {
                if !available.notes.isEmpty { Text(available.notes).font(.caption).lineLimit(6) }
                Button(L10n.text("前往官网下载")) { openURL(available.url) }
                    .accessibilityIdentifier("updates.download")
                Text(L10n.text("请完成传输后覆盖安装，保留设备绑定和个人设置。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func check() {
        guard !checking else { return }
        checking = true
        available = nil
        status = ""
        task = Task { @MainActor in
            defer { checking = false }
            do {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                let result = try await WebsiteUpdateClient.check(installed: version)
                try Task.checkCancellation()
                available = result
                status = result.map { L10n.text("发现新版本 {0}", $0.version) } ?? L10n.text("已是最新版本")
            } catch is CancellationError {
                // Closing identity cancels the request without a false status.
            } catch WebsiteUpdateError.unpublished {
                status = L10n.text("官网暂未发布 Mac 安装包")
            } catch {
                if !Task.isCancelled { status = L10n.text("检查更新失败，请稍后重试。") }
            }
        }
    }
}
#endif
