import AppKit
import LimLinkAppSupport
import LimLinkKit
import SwiftUI

/// Two-column main window: file, save location and recent files on the left; nearby devices on the
/// right, each with its own “发送” button. Files can be dropped anywhere on the window.
struct RootView: View {
    @Environment(MacTransferModel.self) private var model
    @EnvironmentObject private var folderStore: ReceiveFolderStore
    @Environment(\.openWindow) private var openWindow
    @State private var editingName = false
    @State private var showingBindings = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FileDropCard(chooseFile: chooseFile)
                        .riseIn(replaysOnResume: true)
                    SaveLocationRow(chooseFolder: chooseFolder)
                        .riseIn(delay: 0.07, replaysOnResume: true)
                    if model.receivingCount > 0 {
                        ReceivingProgressCard(count: model.receivingCount)
                            .riseIn()
                            .transition(.opacity)
                    }
                    RecentFilesCard()
                        .riseIn(delay: 0.07, replaysOnResume: true)
                }
                .padding(.leading, 24)
                .padding(.trailing, 12)
                .padding(.vertical, 20)
                .animation(Motion.smooth(0.42), value: model.receivingCount > 0)
            }
            .frame(minWidth: 360, idealWidth: 424, maxWidth: 440)

            ScrollView {
                NearbyDeviceList()
                    .padding(.leading, 12)
                    .padding(.trailing, 24)
                    .padding(.vertical, 20)
                    .riseIn(delay: 0.14, replaysOnResume: true)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .overlay { DropTargetOutline(isTargeted: dropTargeted, cornerRadius: 14).padding(8) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL, !model.isSending, !model.importing else { return false }
            Task { await model.importFile(url) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay(alignment: .top) {
            MessageToast(id: model.message?.id, text: model.message?.text ?? "") { model.dismissMessage() }
        }
        .overlay(alignment: .top) {
            TransferCompletionBanner(completion: model.completion) { model.dismissCompletion(id: $0) }
        }
        .modifier(PhotoLibraryNotice())
        .overlay {
            ConsentOverlay(id: model.offer?.id, centered: true) {
                if let offer = model.offer {
                    IncomingFileCard(
                        senderName: offer.senderName, fileName: offer.fileName, size: offer.size,
                        saveLocation: offer.saveLocation ?? folderStore.decision.displayName, receivedAt: offer.receivedAt,
                        queued: model.queuedOfferCount, centered: true, buttonHeight: 36,
                        accept: { model.decideOffer(id: offer.id, accept: true) },
                        reject: { model.decideOffer(id: offer.id, accept: false) }
                    )
                    .frame(width: 400)
                }
            }
        }
        .overlay { if !showingBindings { IncomingDeviceBindingPanel(request: model.bindingRequest) { model.decideBinding(accept: $0) } } }
        .navigationTitle("LimLink")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DeviceNamePill { editingName = true }
            }
        }
        .sheet(isPresented: $editingName, onDismiss: { showingBindings = false }) {
            DeviceNameEditor(showingBindings: $showingBindings)
        }
        .onChange(of: model.bindingRequest?.id) { _, requestID in
            if requestID != nil && !showingBindings { editingName = false }
        }
        .onChange(of: showingBindings) { _, isPresented in
            if !isPresented && model.bindingRequest != nil { editingName = false }
        }
        .onAppear { MainWindowOpener.shared.open = { openWindow(id: MainWindowOpener.windowID) } }
    }

    private func chooseFile() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("选择")
        panel.message = L10n.text("选择一个不超过 5 GB 的文件")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.importFile(url) }
        }
    }

    private func chooseFolder() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("选择")
        panel.message = L10n.text("选择接收文件的保存位置")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try model.chooseReceiveFolder(url) }
            catch { model.message = UserMessage(text: L10n.message("无法使用这个文件夹，请在传输结束后重试。")) }
        }
    }
}

/// Lets the menu bar panel reopen the main window after it was closed.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    static let windowID = "main"
    var open: (() -> Void)?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }
}

func formatMacSize(_ bytes: Int) -> String {
    ByteCountText.fileCount(Int64(bytes), locale: L10n.locale)
}

// MARK: - Toolbar

private struct DeviceNamePill: View {
    @Environment(MacTransferModel.self) private var model
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(model.deviceName).lineLimit(1)
                    .accessibilityIdentifier("localDevice.name")
                Image(systemName: "pencil").font(.caption).foregroundStyle(Palette.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Palette.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(shape: Capsule()))
        .help(L10n.text("本机名称 · {0} · 点击改名", String(describing: statusText)))
        .accessibilityLabel(L10n.text("本机名称 {0}", String(describing: model.deviceName)))
        .accessibilityValue(statusText)
        .accessibilityHint(L10n.text("点击修改附近设备看到的名称"))
        .accessibilityIdentifier("network.status")
    }

    private var statusColor: Color {
        switch model.startup {
        case .ready: Palette.signal
        case .failed: Palette.danger
        case .starting, .stopped: .orange
        }
    }

    private var statusText: String {
        switch model.startup {
        case .stopped: L10n.text("尚未连接")
        case .starting: L10n.text("正在连接局域网")
        case .ready: L10n.text("局域网已就绪")
        case .failed(let text): text.text
        }
    }
}

private struct DeviceNameEditor: View {
    @Environment(MacTransferModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var showingBindings: Bool
    @State private var name = ""
    @State private var error: LocalizedMessage?
    @State private var saving = false
    #if !LIMLINK_DIRECT_DISTRIBUTION
    @State private var showingSupport = false
    #endif
    @State private var showingPrivacy = false
    @State private var showingTerms = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LanguagePicker()
            Button(L10n.text("设备绑定"), systemImage: "link") { showingBindings = true }
                .accessibilityIdentifier("binding.open")
            Divider()
            Text(L10n.text("设备名称")).font(.title2.bold())
            TextField(L10n.text("例如：书房 Mac"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .accessibilityIdentifier("deviceName.field")
            Text(L10n.text("附近设备会看到这个名称。")).font(.caption).foregroundStyle(Palette.secondary)
            if let error {
                Text(error.text).font(.callout).foregroundStyle(Palette.danger).shake(trigger: error.text.hashValue)
            }
            HStack {
                Button(L10n.text("取消"), role: .cancel) { dismiss() }
                    .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 32))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("保存"), action: save)
                    .buttonStyle(TransferCapsuleButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canChangeDeviceName || saving)
            }
            Divider()
            #if LIMLINK_DIRECT_DISTRIBUTION
            DirectUpdateControl()
            #else
            Button(L10n.text("支持 LimLink"), systemImage: "heart") { showingSupport = true }
                .accessibilityIdentifier("support.open")
            #endif
            ReceivedPhotoSettings()
            Button(L10n.text("隐私政策")) { showingPrivacy = true }
                .accessibilityIdentifier("privacy.open")
            Button(L10n.text("用户协议与使用说明")) { showingTerms = true }
                .accessibilityIdentifier("terms.open")
        }
        .padding(28)
        .frame(width: 400)
        .sheet(isPresented: $showingBindings) {
            DeviceBindingView(devices: model.devices, records: model.boundDevices, waiting: model.isBinding,
                              bind: model.bindDevice, cancel: model.cancelBinding, unbind: model.unbindDevice,
                              incoming: model.bindingRequest, decideIncoming: { model.decideBinding(accept: $0) })
        }
        #if !LIMLINK_DIRECT_DISTRIBUTION
        .sheet(isPresented: $showingSupport) { SupportLimLinkView() }
        #endif
        .sheet(isPresented: $showingPrivacy) { PrivacyPolicyView() }
        .sheet(isPresented: $showingTerms) { UsageTermsView() }
        .onAppear { name = model.deviceName }
    }

    private func save() {
        saving = true
        Task {
            error = await model.saveDeviceName(name)
            saving = false
            if error == nil { dismiss() }
        }
    }
}

// MARK: - Left column

private struct FileDropCard: View {
    @Environment(MacTransferModel.self) private var model
    let chooseFile: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            FileRing(fileName: model.selectedFile?.name, diameter: 144)
                .id(model.selectedFile.map { "\($0.name):\($0.size)" } ?? "empty")
            Group {
                if model.importing {
                    HStack(spacing: 8) {
                        ProgressRing(value: 0, state: .waiting, diameter: 16, lineWidth: 2.5)
                        Text(L10n.text("正在准备文件…")).foregroundStyle(Palette.secondary)
                    }
                } else if let file = model.selectedFile {
                    VStack(spacing: 4) {
                        FilePreviewButton(selection: file) {
                            Text(file.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("预览") + " " + file.name)
                        Text(formatMacSize(file.size)).foregroundStyle(Palette.secondary).monospacedDigit()
                        HStack(spacing: 8) {
                            FilePreviewButton(selection: file)
                            smallButton(L10n.text("更换文件"), action: chooseFile).accessibilityIdentifier("send.chooseFile")
                            smallButton(L10n.text("移除")) { model.removeSelectedFile() }
                        }
                        .disabled(model.isSending || model.importing)
                        .padding(.top, 10)
                    }
                } else {
                    VStack(spacing: 12) {
                        VStack(spacing: 4) {
                            Text(L10n.text("选择要发送的内容")).font(.headline)
                            Text(L10n.text("单个文件，最大 5 GB")).foregroundStyle(Palette.secondary)
                        }
                        Button(L10n.text("选择文件"), action: chooseFile)
                            .buttonStyle(TransferCapsuleButtonStyle(height: 32))
                            .frame(width: 140)
                            .accessibilityIdentifier("send.chooseFile")
                    }
                }
            }
            .id(model.importing ? "importing" : model.selectedFile?.name ?? "empty")
            .riseIn()
            Text(L10n.text("也可以直接把文件拖到窗口任意位置"))
                .font(.caption)
                .foregroundStyle(Palette.faint)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 28))
            .font(.callout)
            .fixedSize()
    }
}

/// Shows ~/Downloads/LimLink the way the design does.
private func abbreviatedPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    guard path.hasPrefix(home) else { return path }
    return "~" + path.dropFirst(home.count)
}

private struct SaveLocationRow: View {
    @Environment(MacTransferModel.self) private var model
    @EnvironmentObject private var folderStore: ReceiveFolderStore
    let chooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Palette.secondary)
                Text(L10n.text("保存到")).foregroundStyle(Palette.secondary)
                Text(abbreviatedPath(folderStore.decision.url))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(L10n.text("更改"), action: chooseFolder)
                    .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 28))
                    .fixedSize()
                    .disabled(!model.canChangeReceiveFolder)
                    .accessibilityIdentifier("receiveFolder.choose")
            }
            if let notice = folderStore.decision.notice {
                Text(notice).font(.caption).foregroundStyle(Palette.secondary)
            }
        }
        .font(.callout)
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 6)
    }
}

private struct RecentFilesCard: View {
    @Environment(MacTransferModel.self) private var model
    @EnvironmentObject private var folderStore: ReceiveFolderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("最近")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.text("全部")) { NSWorkspace.shared.open(folderStore.incomingDirectory) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                    .accessibilityIdentifier("recent.all")
            }
            if model.received.isEmpty && model.recentSends.isEmpty {
                Text(L10n.text("收到的文件会显示在这里")).foregroundStyle(Palette.secondary).padding(.vertical, 6)
            } else {
                ForEach(Array(model.received.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { Divider().overlay(Palette.stroke) }
                    SwipeToDeleteRow(title: L10n.text("移到废纸篓"), delete: { model.deleteReceived(file) }) {
                    HStack(spacing: 12) {
                        FilePreviewButton(file: file) {
                        HStack(spacing: 12) {
                        Image(systemName: fileSymbol(file.name))
                            .frame(width: 38, height: 38)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            Text(L10n.text("{0} · 已保存并校验", String(describing: formatMacSize(file.size))))
                                .font(.caption).foregroundStyle(Palette.secondary)
                        }
                        Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("预览") + " " + file.name)
                        FilePreviewButton(file: file).labelStyle(.iconOnly)
                        FileLocationButton(file: file)
                            .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 28))
                            .font(.callout)
                            .fixedSize()
                    }
                    .padding(.vertical, 6)
                    }
                    .help(L10n.text("向左拖动或右键可移到废纸篓"))
                    .riseIn(delay: Motion.stagger(index))
                    .transition(.opacity)
                }
                ForEach(Array(model.recentSends.enumerated()), id: \.element.id) { index, sent in
                    if index > 0 || !model.received.isEmpty { Divider().overlay(Palette.stroke) }
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17))
                            .frame(width: 38, height: 38)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sent.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            Text(L10n.text("发给 {0} · 已送达", String(describing: sent.peer)))
                                .font(.caption).foregroundStyle(Palette.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .riseIn(delay: Motion.stagger(model.received.count + index))
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .animation(Motion.smooth(0.32), value: model.received.map(\.id))
        .animation(Motion.smooth(0.32), value: model.recentSends.map(\.id))
    }
}

// MARK: - Right column

private struct NearbyDeviceList: View {
    @Environment(MacTransferModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deliveredPeerID: String?
    @State private var failures = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(L10n.text("附近设备")).font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if !model.devices.isEmpty {
                    Toggle(L10n.text("多选"), isOn: Binding(
                        get: { model.multiSelectEnabled },
                        set: { model.setMultiSelect($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.callout)
                    .disabled(!model.canMultiSelect && !model.multiSelectEnabled)
                    .accessibilityIdentifier("transfer.multiSelect")
                }
                Text(model.devices.isEmpty ? L10n.text("正在持续发现") : L10n.text("正在持续发现 · {0} 台", String(describing: model.devices.count)))
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .contentTransition(.numericText())
            }
            if case .failed(let reason) = model.startup {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
                        .shake(trigger: failures)
                    Text(reason.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.text("重试连接")) { Task { await model.start() } }
                        .buttonStyle(TransferCapsuleButtonStyle(height: 28))
                        .fixedSize()
                }
                .padding(14)
                .background(Palette.dangerSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .riseIn()
            }
            if model.devices.isEmpty {
                VStack(spacing: 12) {
                    DiscoveryRadar(isActive: model.startup.isReady)
                    Text(L10n.text("让设备靠近一点")).font(.title3.weight(.bold))
                    Text(L10n.text("请在另一台设备上打开 LimLink，并连接同一 Wi-Fi"))
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.devices.enumerated()), id: \.element.fields.fingerprint) { index, peer in
                        if index > 0 { Divider().overlay(Palette.stroke).padding(.leading, 70) }
                        DeviceRow(
                            peer: peer,
                            status: status(for: peer),
                            selecting: model.multiSelectEnabled,
                            selected: model.selectedPeerIDs.contains(model.peerID(peer)),
                            toggle: { model.toggleSelection(peer) }
                        )
                        .riseIn(delay: Motion.stagger(index))
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .animation(reduceMotion ? nil : Motion.smooth(0.42), value: model.devices.map { model.peerID($0) })
                if model.multiSelectEnabled {
                    Button(action: model.sendToSelected) {
                        Text(model.selectedPeers.isEmpty
                             ? L10n.text("选择要发送的设备")
                             : L10n.text("发送给 {0} 台设备", String(describing: model.selectedPeers.count)))
                    }
                    .buttonStyle(TransferCapsuleButtonStyle(height: 32))
                    .disabled(model.selectedPeers.isEmpty || !model.canConnect)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("transfer.sendMultiple")
                    .riseIn()
                }
                if model.selectedFile == nil {
                    hint(L10n.text("先在左侧选择要发送的文件，或直接拖入窗口"))
                } else {
                    hint(L10n.text("没找到设备？确认对方已打开 LimLink，并在同一 Wi-Fi 下"))
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .animation(reduceMotion ? nil : Motion.smooth(0.42), value: model.devices.isEmpty)
        .onChange(of: model.startup) { _, state in if case .failed = state { failures += 1 } }
        .onChange(of: model.transfer?.state == .completed) { _, completed in
            guard completed, let id = model.transfer?.peerID else { return }
            deliveredPeerID = id
        }
        .task(id: deliveredPeerID) {
            guard deliveredPeerID != nil, (try? await Task.sleep(for: .seconds(3))) != nil else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { deliveredPeerID = nil }
        }
    }

    private func hint(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 4)
    }

    private func status(for peer: DiscoveredService) -> DeviceRow.Status {
        let id = model.peerID(peer)
        if let transfer = model.transfer, transfer.peerID == id {
            if model.isSending { return .sending(transfer) }
            if case .failed(let reason) = transfer.state { return .failed(reason.text) }
        }
        if deliveredPeerID == id { return .delivered }
        return model.canConnect ? .ready : .unavailable
    }
}

private struct DeviceRow: View {
    enum Status {
        case ready, unavailable, delivered
        case sending(TransferProgress)
        case failed(String)
    }

    @Environment(MacTransferModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let peer: DiscoveredService
    let status: Status
    var selecting = false
    var selected = false
    var toggle: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Image(systemName: deviceSymbol(peer)).font(.system(size: 22, weight: .light))
                if case .sending(let progress) = status {
                    ProgressRing(value: progress.fraction, state: progress.ringState, diameter: 44, lineWidth: 3.5, showsCheck: false)
                        .popIn()
                }
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .bottomTrailing) {
                if case .delivered = status {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Palette.signal, in: Circle())
                        .offset(x: 4, y: 4)
                        .popIn()
                        .transition(.opacity)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.instanceName).font(.body.weight(.semibold)).lineLimit(1)
                subtitle
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            action
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            Palette.fill.opacity(selecting && selected ? 1 : (hovering ? 1 : 0)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selecting && selected ? Palette.ink : .clear, lineWidth: 1.5)
        }
        .opacity(isUnavailable ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if selecting { toggle() } }
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: inside ? 0.15 : 0.3)) { hovering = inside }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(selected ? L10n.text("取消选择") : L10n.text("选择"))) { if selecting { toggle() } }
        .accessibilityIdentifier("peer.\(model.peerID(peer))")
    }

    private var isUnavailable: Bool { if case .unavailable = status { return true }; return false }

    @ViewBuilder
    private var subtitle: some View {
        switch status {
        case .sending(let progress):
            Text(sendingText(progress)).foregroundStyle(Palette.signalText).fontWeight(.medium)
                .contentTransition(.numericText())
        case .delivered:
            Text(L10n.text("已送达")).foregroundStyle(Palette.signalText).fontWeight(.medium)
        case .failed(let reason):
            Text(reason).foregroundStyle(Palette.danger)
        case .ready, .unavailable:
            Text(deviceKind(peer)).foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        if selecting {
            ZStack {
                Circle()
                    .strokeBorder(selected ? Palette.ink : Palette.faint, lineWidth: 1.5)
                    .frame(width: 26, height: 26)
                if selected {
                    Circle().fill(Palette.ink).frame(width: 26, height: 26)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.paper)
                }
            }
            .frame(width: 76, height: 32)
            .accessibilityHidden(true)
        } else if case .sending = status {
            Button(L10n.text("取消")) { model.cancelSend() }
                .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 32))
                .lineLimit(1)
                .frame(minWidth: 76)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("transfer.cancel")
        } else {
            Button(L10n.text("发送")) { model.send(to: peer) }
                .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 32))
                .lineLimit(1)
                .frame(minWidth: 76)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!model.canConnect)
                .accessibilityLabel(L10n.text("发送给 {0}", String(describing: peer.instanceName)))
                .accessibilityIdentifier("send.to.\(model.peerID(peer))")
        }
    }

    private func sendingText(_ progress: TransferProgress) -> String {
        switch progress.state {
        case .sending:
            var parts: [String] = []
            if let batch = progress.batchLabel { parts.append(batch) }
            parts.append(L10n.text("发送中 {0}%", String(describing: Int(progress.fraction * 100))))
            if let rate = formatRate(progress.bytesPerSecond) { parts.append(rate) }
            if let remaining = formatRemaining(progress.secondsRemaining) { parts.append(remaining) }
            return parts.joined(separator: " · ")
        default:
            return progress.statusTitle
        }
    }
}
