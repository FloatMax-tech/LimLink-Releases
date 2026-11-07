import SwiftUI
import LimLinkKit
import LimLinkAppSupport

/// Independent device picker; selecting Bind is the initiating permission.
struct DeviceBindingView: View {
    let devices: [DiscoveredService]
    let records: [DeviceBindingRecord]
    let waiting: Bool
    let bind: (DiscoveredService) -> Void
    let cancel: () -> Void
    let unbind: (DeviceBindingRecord) -> Void
    let incoming: IncomingDeviceBinding?
    let decideIncoming: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if waiting {
                    Section {
                        ProgressView(L10n.text("等待对方确认绑定…"))
                            .accessibilityIdentifier("binding.waiting")
                        Button(L10n.text("取消绑定"), action: cancel)
                            .accessibilityIdentifier("binding.cancel")
                    }
                }
                Section(L10n.text("附近设备")) {
                    if devices.isEmpty { Text(L10n.text("未发现附近设备")) }
                    ForEach(devices, id: \.self) { peer in
                        HStack {
                            Text(peer.instanceName)
                            Spacer()
                            Button(L10n.text("绑定")) { bind(peer) }
                                .disabled(waiting)
                                .accessibilityIdentifier("binding.bind." + (peer.fields.fingerprint ?? peer.instanceName))
                        }
                    }
                }
                Section(L10n.text("已绑定设备")) {
                    if records.isEmpty { Text(L10n.text("尚未绑定设备")) }
                    ForEach(records) { record in
                        HStack {
                            Text(record.alias)
                            Spacer()
                            Button(L10n.text("解绑"), role: .destructive) { unbind(record) }
                                .accessibilityIdentifier("binding.unbind." + record.bindingID)
                        }
                    }
                    Text(L10n.text("解绑立即停止本机后续文件自动接收。离线设备的本地记录可能仍保留。"))
                }
            }
            .navigationTitle(L10n.text("设备绑定"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("完成")) { dismiss() }.accessibilityIdentifier("binding.done") } }
        }
        .overlay { IncomingDeviceBindingPanel(request: incoming, decide: decideIncoming) }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 500)
        #endif
    }
}

struct IncomingDeviceBindingPanel: View {
    let request: IncomingDeviceBinding?
    let decide: (Bool) -> Void
    var body: some View {
        if let request {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 18) {
                    Text(L10n.text("设备绑定请求")).font(.title2.bold())
                    Text(request.alias).font(.headline)
                        .accessibilityIdentifier("binding.request.name")
                    Text(L10n.text("确认绑定后，双方将自动接收彼此发送的文件。请确认这是你选择的设备，名称可自行修改。"))
                    HStack {
                        Button(L10n.text("拒绝"), role: .cancel) { decide(false) }
                            .accessibilityIdentifier("binding.reject")
                        Button(L10n.text("确认绑定")) { decide(true) }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("binding.accept")
                    }
                }
                .padding(24).frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(24)
            }
            .accessibilityAddTraits(.isModal)
        }
    }
}
