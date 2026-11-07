import LimLinkAppSupport
import LimLinkKit
import SwiftUI

struct StartupSummary: View {
    let state: StartupState
    var deviceName: String? = nil
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(title).font(.footnote).foregroundStyle(Palette.secondary)
                    .contentTransition(.opacity)
                if case .starting = state { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                if case .failed = state {
                    Button(L10n.text("重试"), action: retry)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .accessibilityIdentifier("transfer.startup.retry")
                }
            }
            if case .failed(let reason) = state {
                Text(reason.text).font(.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.25), value: state)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isReady ? "transfer.startup.ready" : "transfer.startup.status")
    }

    private var isReady: Bool { if case .ready = state { return true }; return false }
    private var title: String {
        switch state {
        case .ready: deviceName.map { L10n.text("局域网已就绪 · 本机「{0}」", String(describing: $0)) } ?? L10n.text("局域网已就绪")
        case .starting(let title): title?.text ?? L10n.text("正在连接局域网")
        case .stopped: L10n.text("正在准备连接")
        case .failed: L10n.text("局域网连接失败")
        }
    }
    private var color: Color {
        switch state {
        case .ready: Palette.signal
        case .failed: Palette.danger
        case .starting, .stopped: .orange
        }
    }
}

// MARK: - File card

@MainActor
struct FileComposer: View {
    let model: TransferModel
    let namespace: Namespace.ID
    /// Wide layouts send by tapping a device, so they hide the send button.
    var showsSendButton = true
    @Binding var showingSource: Bool
    let chooseFiles: () -> Void
    let choosePhotos: () -> Void
    let chooseRecipient: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let file = model.selectedFile {
                    FilePreviewButton(selection: file) { fileSurface }
                } else {
                    Button { showingSource = true } label: { fileSurface }
                }
            }
                .buttonStyle(PressableButtonStyle(shape: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous), pressedScale: 0.975))
                .disabled(model.importing || model.isSending)
                .accessibilityIdentifier("transfer.file.choose")
                .accessibilityLabel(model.importing ? L10n.text("正在读取") : model.selectedFile == nil ? L10n.text("选择文件或照片") : L10n.text("预览"))
                .accessibilityValue(model.selectedFile.map { "\($0.name)，\(formatSize($0.size))" } ?? L10n.text("尚未选择"))
                .modifier(FileTransitionSource(namespace: namespace, reduceMotion: reduceMotion))
                .modifier(SourceChoice(
                    showing: $showingSource,
                    anchored: horizontalSizeClass == .regular,
                    chooseFiles: chooseFiles,
                    choosePhotos: choosePhotos
                ))
                .overlay { DropTargetOutline(isTargeted: dropTargeted, cornerRadius: Radius.hero) }
                .dropDestination(for: PickedFile.self) { items, _ in
                    guard let file = items.first, !model.isSending, !model.importing else { return false }
                    Task { await model.importDroppedFile(file) }
                    return true
                } isTargeted: { dropTargeted = $0 }

            if let file = model.selectedFile {
                HStack {
                    FilePreviewButton(selection: file)
                    Spacer()
                    Button(L10n.text("更换文件或照片")) { showingSource = true }
                        .accessibilityIdentifier("transfer.file.replace")
                        .disabled(model.importing || model.isSending)
                }
                    .padding(.top, 10)
            }

            if showsSendButton {
                Button(action: chooseRecipient) {
                    HStack {
                        Text(L10n.text("发送"))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(TransferCapsuleButtonStyle())
                .disabled(model.selectedFile == nil || model.importing || model.isSending)
                .accessibilityIdentifier("transfer.send")
                .accessibilityHint(L10n.text("下一步选择附近的接收设备"))
                .padding(.top, 24)
            }

            Text(limitText)
                .font(.caption).foregroundStyle(Palette.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .accessibilityIdentifier("transfer.file.limit")
        }
    }

    private var limitText: String {
        let base = L10n.text("单个文件 · 最大 {0}", String(describing: formatSize(TransferLimits.maximumFileBytes)))
        return showsSendButton ? base : L10n.text("{0} · 在右侧选择设备即可发送", String(describing: base))
    }

    /// Changes whenever the card switches between empty, reading and a particular file.
    private var surfaceKey: String {
        if model.importing { return "importing" }
        return model.selectedFile.map { "file:\($0.name):\($0.size)" } ?? "empty"
    }

    private var fileSurface: some View {
        VStack(spacing: 16) {
            FileRing(fileName: model.selectedFile?.name)
                .id(model.selectedFile.map { "\($0.name):\($0.size)" } ?? "empty")

            Group {
                if model.importing {
                    HStack(spacing: 8) {
                        ProgressRing(value: 0, state: .waiting, diameter: 18, lineWidth: 2.5)
                        Text(L10n.text("正在准备发送内容…")).font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                } else if let file = model.selectedFile {
                    VStack(spacing: 4) {
                        Text(file.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                        Text(formatSize(file.size)).font(.subheadline).foregroundStyle(Palette.secondary).monospacedDigit()
                        Text(L10n.text("预览"))
                            .font(.footnote)
                            .foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Palette.fill, in: Capsule())
                            .padding(.top, 10)
                    }
                    .accessibilityIdentifier("transfer.file.selected")
                } else {
                    VStack(spacing: 6) {
                        Text(L10n.text("选择要发送的内容")).font(.headline)
                        Text(L10n.text("照片、文档，任何格式")).font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                }
            }
            .id(surfaceKey)
            .riseIn()
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
    }
}

private struct FileTransitionSource: ViewModifier {
    let namespace: Namespace.ID
    let reduceMotion: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.matchedTransitionSource(id: "selected-file", in: namespace)
        } else { content }
    }
}

private struct FileTransitionDestination: ViewModifier {
    let namespace: Namespace.ID
    let reduceMotion: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.navigationTransition(.zoom(sourceID: "selected-file", in: namespace))
        } else { content }
    }
}

// MARK: - Recipient page (iPhone)

@MainActor
struct RecipientPickerView: View {
    let model: TransferModel
    let namespace: Namespace.ID
    @Binding var showingBindings: Bool
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var subtitle: String {
        if model.multiSelectEnabled { return L10n.text("选择多台设备，依次发送，对方同意后开始传输") }
        return model.devices.isEmpty
            ? L10n.text("请在另一台设备上打开 LimLink\n连接同一 Wi-Fi，并允许本地网络访问")
            : L10n.text("轻点设备即发送，对方同意后开始传输")
    }

    private var multiSelectButton: some View {
        Button(model.multiSelectEnabled ? L10n.text("完成") : L10n.text("多选")) { model.toggleMultiSelect() }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Palette.fill, in: Capsule())
            .buttonStyle(.plain)
            .disabled(!model.canMultiSelect && !model.multiSelectEnabled)
            .accessibilityIdentifier("transfer.multiSelect")
    }

    var body: some View {
        TransferPage(model: model) {
            StartupSummary(state: model.startup) { Task { await model.start() } }
            if let progress = model.transfer {
                TransferDialView(model: model, progress: progress, finish: finish)
                    .padding(.top, 8)
                    .riseIn()
            } else {
                if let file = model.selectedFile {
                    SelectedFileChip(file: file).riseIn()
                }
                VStack(spacing: 10) {
                    DiscoveryRadar(isActive: model.canConnect, size: model.devices.isEmpty ? 180 : 150)
                    VStack(spacing: 10) {
                        Text(model.devices.isEmpty ? L10n.text("让设备靠近一点") : L10n.text("发送给谁？"))
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("transfer.recipientTitle")
                        if !model.devices.isEmpty {
                            multiSelectButton
                        }
                    }
                    Text(subtitle)
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .riseIn(delay: 0.07)
                if model.devices.isEmpty {
                    DiscoveryEmptyHint(canConnect: model.canConnect)
                } else {
                    RecipientGrid(model: model, minimumWidth: 140)
                    if model.multiSelectEnabled {
                        Button(action: model.sendToSelected) {
                            Text(model.selectedPeers.isEmpty
                                 ? L10n.text("选择要发送的设备")
                                 : L10n.text("发送给 {0} 台设备", String(describing: model.selectedPeers.count)))
                        }
                        .buttonStyle(TransferCapsuleButtonStyle())
                        .disabled(model.selectedPeers.isEmpty || !model.canConnect)
                        .accessibilityIdentifier("transfer.sendMultiple")
                        .riseIn()
                    }
                }
            }
        }
        .navigationTitle(model.transfer == nil ? L10n.text("选择设备") : L10n.text("正在发送"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { TransferIdentityButton(model: model, showingBindings: $showingBindings) } }
        .accessibilityIdentifier("transfer.recipientPicker")
        .modifier(FileTransitionDestination(namespace: namespace, reduceMotion: reduceMotion))
    }
}

struct DiscoveryEmptyHint: View {
    let canConnect: Bool

    var body: some View {
        Text(canConnect ? L10n.text("正在发现附近设备…") : L10n.text("连接就绪后会显示附近设备"))
            .font(.caption).foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("transfer.discovery.empty")
    }
}

private struct SelectedFileChip: View {
    let file: TransferFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fileSymbol(file.name))
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(formatSize(file.size)).font(.caption).foregroundStyle(Palette.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Device grid (shared by the iPhone page and the iPad right column)

@MainActor
struct RecipientGrid: View {
    let model: TransferModel
    var minimumWidth: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deliveredPeerID: String?

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: minimumWidth), spacing: 14)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Array(model.devices.enumerated()), id: \.element.fields.fingerprint) { index, peer in
                let id = model.peerID(peer)
                Button {
                    if model.multiSelectEnabled { model.toggleSelection(peer) } else { model.send(to: peer) }
                } label: {
                    RecipientTile(peer: peer, state: tileState(id))
                }
                .buttonStyle(PressableButtonStyle(shape: RoundedRectangle(cornerRadius: Radius.device, style: .continuous)))
                .disabled(!model.canConnect)
                .accessibilityIdentifier("transfer.peer.\(id)")
                .accessibilityLabel(peer.instanceName)
                .accessibilityValue(tileAccessibilityValue(id))
                .accessibilityHint(model.multiSelectEnabled ? L10n.text("选择此设备，一起发送") : L10n.text("向此设备发送已选择的文件，等待对方确认接收"))
                .riseIn(delay: Motion.stagger(index))
                .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.smooth(0.42), value: model.devices.map { model.peerID($0) })
        .onChange(of: model.transfer?.state == .completed) { _, completed in
            guard completed, let id = model.transfer?.peerID else { return }
            deliveredPeerID = id
        }
        .task(id: deliveredPeerID) {
            guard deliveredPeerID != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { deliveredPeerID = nil }
        }
    }

    private func tileState(_ id: String) -> RecipientTile.Status {
        if model.multiSelectEnabled, model.selectedPeerIDs.contains(id) { return .selected }
        if let transfer = model.transfer, transfer.peerID == id, model.isSending {
            return .sending(transfer.fraction, transfer.ringState)
        }
        if deliveredPeerID == id { return .delivered }
        return model.canConnect ? .idle : .unavailable
    }

    private func tileAccessibilityValue(_ id: String) -> String {
        switch tileState(id) {
        case .sending(let fraction, _): L10n.text("发送中 {0}%", String(describing: Int(fraction * 100)))
        case .delivered: L10n.text("刚刚已送达")
        case .selected: L10n.text("已选择")
        default: ""
        }
    }
}

struct RecipientTile: View {
    enum Status: Equatable {
        case idle, unavailable, delivered, selected
        case sending(Double, RingState)
    }

    let peer: DiscoveredService
    let status: Status

    init(peer: DiscoveredService, state: Status) {
        self.peer = peer
        self.status = state
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Image(systemName: deviceSymbol(peer))
                    .font(.system(size: 30, weight: .light))
                if case .sending(let fraction, let ring) = status {
                    ProgressRing(value: fraction, state: ring, diameter: 64, lineWidth: 4)
                        .popIn()
                }
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            VStack(spacing: 3) {
                Text(peer.instanceName).font(.subheadline.weight(.semibold)).lineLimit(3)
                Text(subtitle)
                    .font(.caption.weight(isSending ? .semibold : .regular))
                    .foregroundStyle(isSending ? Palette.signalText : Palette.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .multilineTextAlignment(.center)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.device, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.device, style: .continuous)
                .strokeBorder(isSending ? Palette.signal : status == .selected ? Palette.ink : .clear, lineWidth: 1.5)
        }
        .overlay(alignment: .topTrailing) {
            if status == .delivered || status == .selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(status == .selected ? Palette.paper : .white)
                    .frame(width: 22, height: 22)
                    .background(status == .selected ? Palette.ink : Palette.signal, in: Circle())
                    .padding(10)
                    .popIn()
                    .transition(.opacity)
            }
        }
        .opacity(status == .unavailable ? 0.45 : 1)
        .animation(.easeOut(duration: 0.25), value: isSending)
    }

    private var isSending: Bool { if case .sending = status { return true }; return false }

    private var subtitle: String {
        switch status {
        case .sending(let fraction, let ring):
            ring == .waiting ? L10n.text("等待对方接收") : L10n.text("发送中 {0}%", String(describing: Int(fraction * 100)))
        case .delivered: L10n.text("刚刚已送达")
        case .selected: L10n.text("已选择")
        default: deviceKind(peer)
        }
    }
}

/// Files / Photos chooser. On iPad it is a popover anchored to the file card; on iPhone it keeps
/// the system action sheet.
private struct SourceChoice: ViewModifier {
    @Binding var showing: Bool
    let anchored: Bool
    let chooseFiles: () -> Void
    let choosePhotos: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if anchored {
            content.popover(isPresented: $showing, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("选择要发送的内容")).font(.headline).padding(.bottom, 2)
                    Button(action: chooseFiles) {
                        Label(L10n.text("文件"), systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 44))
                    .accessibilityIdentifier("transfer.source.files")
                    Button(action: choosePhotos) {
                        Label(L10n.text("照片"), systemImage: "photo").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary, height: 44))
                    .accessibilityIdentifier("transfer.source.photos")
                }
                .foregroundStyle(Palette.ink)
                .padding(18)
                .frame(width: 260)
                .presentationBackground(Palette.surface)
            }
        } else {
            content.confirmationDialog(L10n.text("选择要发送的内容"), isPresented: $showing, titleVisibility: .visible) {
                Button(L10n.text("文件"), systemImage: "folder", action: chooseFiles)
                    .accessibilityIdentifier("transfer.source.files")
                Button(L10n.text("照片"), systemImage: "photo", action: choosePhotos)
                    .accessibilityIdentifier("transfer.source.photos")
                Button(L10n.text("取消"), role: .cancel) { }
            }
        }
    }
}
