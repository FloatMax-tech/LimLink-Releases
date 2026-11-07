import LimLinkKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @StateObject private var lab = TransferLab()
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section("附近设备") {
                    if lab.devices.isEmpty {
                        Text("还没有发现设备")
                    }
                    ForEach(lab.devices, id: \.instanceName) { peer in
                        Button {
                            lab.select(peer)
                        } label: {
                            peerRow(peer)
                        }
                    }
                }
                Section("手动地址") {
                    TextField("地址", text: $lab.manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $lab.manualPort)
                        .keyboardType(.numberPad)
                    Button("连接") { lab.sendManual() }
                }
                Section("诊断") {
                    if lab.diagnostics.isEmpty {
                        Text("没有其他 App")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lab.diagnostics, id: \.instanceName) { peer in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(peer.instanceName)
                            Text("其他 App，暂不支持互传")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !lab.mismatch.isEmpty {
                        ForEach(Array(lab.mismatch.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.deviceName) \(entry.ip)")
                                Text("TXT \(entry.txtApp) · TLS \(entry.tlsApp)")
                                    .font(.caption)
                                Text(entry.timestamp)
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(lab.ticketNotes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("清除诊断记录") { lab.clearDiagnostics() }
                }
                Section("传输") {
                    Text(lab.status)
                    if let chosen = lab.chosenFile {
                        Text(chosen)
                    }
                    if lab.executableWarning {
                        Text("这个文件可能是可执行文件或安装包，仍然可以发送。")
                            .font(.caption)
                    }
                    Text(lab.trustedLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("信任此指纹") { lab.trustSelected() }
                    if lab.pendingSessionID != nil {
                        Button("接收") { lab.acceptPending() }
                    }
                    Button("选择文件") { showImporter = true }
                    Button("发送") { lab.sendSelected() }
                    ForEach(lab.received, id: \.self) { name in
                        Text("已保存到本机 \(name)")
                    }
                }
            }
            .navigationTitle("LimLink")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result {
                    lab.takeFile(url)
                }
            }
            .alert("LimLink", isPresented: alertShown) {
                Button("知道了", role: .cancel) { lab.alertMessage = nil }
            } message: {
                Text(lab.alertMessage ?? "")
            }
            .task { await lab.start() }
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { lab.alertMessage != nil }, set: { shown in
            if !shown { lab.alertMessage = nil }
        })
    }

    /// `app` and the device name stay separate. The Kit does not build a display string.
    @ViewBuilder
    private func peerRow(_ peer: DiscoveredService) -> some View {
        HStack {
            Text(peer.instanceName)
            Spacer()
            if peer.fields.normalizedApp == "casecheck" {
                Text("CaseCheck")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary))
            }
        }
    }
}
