import Foundation
import LimLinkAppSupport
import LimLinkKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

@MainActor
struct TransferHomeView: View {
    @State private var model = TransferModel()
    @State private var showingImporter = false
    @State private var showingBindings = false
    @State private var showingSource = false
    @State private var showingPhotos = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingRecipients = false
    @State private var importingSharedFile = false
    #if DEBUG
    @State private var stagedBackgroundUIShare = false
    #endif
    @Namespace private var fileTransition
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// Two columns in landscape from 700pt wide; portrait and narrow split view use the iPhone flow.
    private static let wideLayoutWidth: CGFloat = 700

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.wideLayoutWidth && geometry.size.width > geometry.size.height
            NavigationStack {
                Group {
                    if wide { wideLayout(width: geometry.size.width) } else { compactLayout }
                }
                .navigationTitle(wide ? "" : "LimLink")
                .navigationBarTitleDisplayMode(wide ? .inline : .large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { TransferIdentityButton(model: model, showingBindings: $showingBindings) }
                    #if DEBUG && targetEnvironment(simulator)
                    if model.canTriggerUITestReceiptCompletion {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成接收示例") { model.triggerUITestReceiptCompletion() }
                                .accessibilityIdentifier("ui.fixture.receipt.complete")
                        }
                    }
                    #endif
                }
                .navigationDestination(isPresented: $showingRecipients) {
                    RecipientPickerView(model: model, namespace: fileTransition, showingBindings: $showingBindings) {
                        model.dismissTransfer()
                        showingRecipients = false
                    }
                }
                .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data], onCompletion: importResult)
                .photosPicker(isPresented: $showingPhotos, selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current)
                .task(id: selectedPhoto) {
                    guard let selectedPhoto else { return }
                    await model.importPhoto(selectedPhoto)
                    self.selectedPhoto = nil
                }
            }
            .onChange(of: wide) { _, isWide in if isWide { showingRecipients = false } }
        }
        // Keyboard avoidance must not change the home layout breakpoint. On portrait iPad,
        // the keyboard otherwise makes width > height and rebuilds the identity sheet's host.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .top) {
            MessageToast(id: model.message?.id, text: model.message?.text ?? "") { model.dismissMessage() }
        }
        .overlay(alignment: .top) {
            TransferCompletionBanner(completion: model.completion) { model.dismissCompletion(id: $0) }
        }
        .modifier(PhotoLibraryNotice())
        .overlay {
            IncomingOfferPanel(model: model, centered: horizontalSizeClass == .regular)
        }
        .overlay { if !showingBindings { IncomingDeviceBindingPanel(request: model.bindingRequest) { model.decideBinding(accept: $0) } } }
        .task {
            LocalNotifications.shared.prepare()
            #if DEBUG
            // Test fixtures use the same disk handoff as the extension.
            if ProcessInfo.processInfo.environment["LIMLINK_UI_TEST_SHARE_ON_BACKGROUND"] == "1" {
                for share in SharedInbox.pending() where share.name == "分享示例.txt" {
                    SharedInbox.discard(share)
                }
            }
            if ProcessInfo.processInfo.environment["LIMLINK_UI_TEST_SHARE"] == "1" {
                stageUIShare()
            }
            #endif
            await importPendingShares()
            await model.start()
        }
        .onOpenURL { _ in Task { await importPendingShares() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await importPendingShares() } }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            guard ProcessInfo.processInfo.environment["LIMLINK_UI_TEST_SHARE_ON_BACKGROUND"] == "1",
                  !stagedBackgroundUIShare else { return }
            stagedBackgroundUIShare = true
            stageUIShare()
        }
        #endif
    }

    // MARK: iPhone and narrow iPad

    private var compactLayout: some View {
        TransferPage(model: model) {
            StartupSummary(state: model.startup, deviceName: model.deviceName) { Task { await model.start() } }
                .riseIn(replaysOnResume: true)
            fileComposer(showsSendButton: true)
                .riseIn(delay: 0.07, replaysOnResume: true)
            TransferActivity(model: model) { showingRecipients = true }
            ReceivedFilesCard(model: model)
                .riseIn(delay: 0.14, replaysOnResume: true)
        }
    }

    // MARK: iPad landscape

    private func wideLayout(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // A fixed title: the navigation large title moved with pull-to-refresh and covered the card.
            Text("LimLink")
                .font(.system(size: 34, weight: .bold))
                .padding(.leading, 28)
                .padding(.top, 10)
                .padding(.bottom, 2)
            HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StartupSummary(state: model.startup, deviceName: model.deviceName) { Task { await model.start() } }
                        .riseIn(replaysOnResume: true)
                    fileComposer(showsSendButton: false)
                        .riseIn(delay: 0.07, replaysOnResume: true)
                    if model.receivingCount > 0 {
                        ReceivingProgressCard(count: model.receivingCount).riseIn()
                    }
                    ReceivedFilesCard(model: model)
                        .riseIn(delay: 0.07, replaysOnResume: true)
                }
                .padding(.leading, 28)
                .padding(.trailing, 14)
                .padding(.vertical, 16)
            }
            .refreshable { await model.refreshReceivedFiles() }
            .frame(width: min(max(width * 0.4, 340), 480))

            ScrollView {
                NearbyDevicesColumn(model: model)
                    .padding(.leading, 14)
                    .padding(.trailing, 28)
                    .padding(.vertical, 16)
                    .riseIn(delay: 0.14, replaysOnResume: true)
            }
            }
        }
        .background(Palette.paper)
    }

    private func fileComposer(showsSendButton: Bool) -> some View {
        FileComposer(
            model: model,
            namespace: fileTransition,
            showsSendButton: showsSendButton,
            showingSource: $showingSource,
            chooseFiles: { showingImporter = true },
            choosePhotos: { showingPhotos = true },
            chooseRecipient: { showingRecipients = true }
        )
    }

    /// Takes one pending share (the protocol sends one file at a time) and goes to 选择设备.
    private func importPendingShares() async {
        guard !importingSharedFile, !model.isSending, !model.importing else { return }
        importingSharedFile = true
        defer { importingSharedFile = false }

        let result = await SharedInbox.importNext(canImport: model.selectedFile == nil) { url in
            await model.importSharedFile(url)
        }
        if case .imported(let hasMore) = result {
            if hasMore {
                model.message = UserMessage(text: L10n.message("一次只能发送一个文件，已选择第一个。"))
            }
            showingRecipients = true
        }
    }

    #if DEBUG
    /// Simulates the extension writing its disk handoff after this process is already running.
    private func stageUIShare() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("分享示例.txt")
        do {
            try Data("shared from the share sheet".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            try SharedInbox.stage(url, name: url.lastPathComponent)
        } catch {
            model.message = UserMessage(text: L10n.message("无法读取分享的文件，请重试。"))
        }
    }
    #endif

    private func importResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): Task { await model.importFile(url) }
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled, !(error is CancellationError) else { return }
            model.reportImportFailure(error)
        }
    }
}

/// The right-hand column on iPad: the active transfer, then every nearby device. Tapping a device sends.
@MainActor
private struct NearbyDevicesColumn: View {
    let model: TransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress = model.transfer {
                TransferProgressRow(model: model, progress: progress)
                    .riseIn()
                    .transition(.opacity)
            }
            HStack(alignment: .center) {
                Text(L10n.text("附近设备")).font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
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
                Text(model.devices.isEmpty ? L10n.text("正在持续发现") : L10n.text("{0} 台 · 正在持续发现", String(describing: model.devices.count)))
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .contentTransition(.numericText())
            }
            if model.devices.isEmpty {
                VStack(spacing: 12) {
                    DiscoveryRadar(isActive: model.startup.isReady)
                    Text(L10n.text("让设备靠近一点")).font(.title3.weight(.bold))
                    Text(L10n.text("请在另一台设备上打开 LimLink\n连接同一 Wi-Fi，并允许本地网络访问"))
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                    DiscoveryEmptyHint(canConnect: model.canConnect)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                if model.selectedFile == nil {
                    Text(L10n.text("先在左侧选择要发送的文件"))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                }
                RecipientGrid(model: model, minimumWidth: 180)
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
        .animation(Motion.smooth(0.42), value: model.transfer == nil)
    }
}

/// The root model owns network work; moving between pages only changes presentation.
@MainActor
struct TransferPage<Content: View>: View {
    let model: TransferModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24, content: content)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .refreshable { await model.refreshReceivedFiles() }
    }
}

@MainActor
struct TransferActivity: View {
    let model: TransferModel
    var open: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let progress = model.transfer {
                TransferProgressRow(model: model, progress: progress, open: open)
                    .riseIn()
                    .transition(.opacity)
            }
            if model.receivingCount > 0 {
                ReceivingProgressCard(count: model.receivingCount)
                    .riseIn()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.smooth(0.42), value: model.transfer == nil)
        .animation(reduceMotion ? nil : Motion.smooth(0.42), value: model.receivingCount)
    }
}

@MainActor
struct TransferIdentityButton: View {
    let model: TransferModel
    @Binding var showingBindings: Bool
    @State private var showingIdentity = false
    var body: some View {
        Button(L10n.text("本机身份"), systemImage: "person.crop.circle") { showingIdentity = true }
            .labelStyle(.iconOnly)
            .foregroundStyle(Palette.ink)
            .accessibilityIdentifier("transfer.identity")
            .sheet(isPresented: $showingIdentity, onDismiss: { showingBindings = false }) {
                DeviceIdentityView(model: model, showingBindings: $showingBindings)
                    .presentationDetents([.large])
            }
            .onChange(of: model.bindingRequest?.id) { _, requestID in
                if requestID != nil && !showingBindings { showingIdentity = false }
            }
            .onChange(of: showingBindings) { _, isPresented in
                if !isPresented && model.bindingRequest != nil { showingIdentity = false }
            }
    }
}

// MARK: - Receive consent

/// Covers every page: a bottom panel on iPhone, a centered panel on iPad. Requests queue one at a time.
@MainActor
struct IncomingOfferPanel: View {
    let model: TransferModel
    let centered: Bool

    var body: some View {
        ConsentOverlay(id: model.offer?.id, centered: centered) {
            if let offer = model.offer {
                IncomingFileCard(
                    senderName: offer.senderName, fileName: offer.fileName, size: offer.size,
                    saveLocation: model.saveLocationName, receivedAt: offer.receivedAt,
                    queued: model.queuedOfferCount, centered: centered,
                    accept: { model.decideOffer(id: offer.id, accept: true) },
                    reject: { model.decideOffer(id: offer.id, accept: false) }
                )
                .frame(maxWidth: centered ? 420 : 600)
                .padding(.horizontal, centered ? 24 : 8)
                .padding(.bottom, centered ? 0 : 8)
            }
        }
        .ignoresSafeArea(.container, edges: centered ? [] : .bottom)
    }
}

// MARK: - Received files

@MainActor
private struct ReceivedFilesCard: View {
    let model: TransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("已接收"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            if model.received.isEmpty {
                Text(L10n.text("收到的文件会显示在这里"))
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
            } else {
                ForEach(Array(model.received.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { Divider().overlay(Palette.stroke) }
                    SwipeToDeleteRow(delete: { model.deleteReceived(file) }) {
                    HStack(spacing: 12) {
                        FilePreviewButton(file: file) {
                        HStack(spacing: 12) {
                        Image(systemName: fileSymbol(file.name))
                            .font(.system(size: 18))
                            .frame(width: 38, height: 38)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.subheadline.weight(.medium)).lineLimit(2)
                            Text(model.isInSaveFolder(file)
                                 ? L10n.text("{0} · 在「{1}」中", String(describing: formatSize(file.size)), String(describing: model.saveFolder?.displayName ?? L10n.text("下载")))
                                 : L10n.text("{0} · 在「{1}」中", String(describing: formatSize(file.size)), String(describing: model.defaultLocationName)))
                                .font(.caption).foregroundStyle(Palette.secondary).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        }
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("file.preview.received.\(file.name)")
                        .accessibilityLabel(L10n.text("预览") + " " + file.name)
                        FilePreviewButton(file: file).labelStyle(.iconOnly)
                        FileLocationButton(file: file).labelStyle(.iconOnly)
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body)
                                .foregroundStyle(Palette.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("transfer.received.share.\(file.id)")
                        .accessibilityLabel(L10n.text("分享或存储 {0}", String(describing: file.name)))
                    }
                    .padding(.vertical, 4)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("transfer.received.row.\(file.name)")
                    .riseIn(delay: Motion.stagger(index))
                    .transition(.opacity)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .animation(Motion.smooth(0.32), value: model.received.map(\.id))
        .accessibilityIdentifier("transfer.received")
    }
}

// MARK: - Identity

struct LocalFingerprintCard: View {
    let fingerprint: String
    @State private var copied = false

    var body: some View {
        TransferCard(title: L10n.text("本机 TLS 指纹"), symbol: "shield.lefthalf.filled") {
            if fingerprint.isEmpty {
                Text(L10n.text("启动后显示本机完整指纹"))
                    .foregroundStyle(Palette.secondary)
            } else {
                FingerprintBlock(fingerprint: fingerprint, identifier: "transfer.localFingerprint")
                Button {
                    UIPasteboard.general.string = fingerprint
                    copied = true
                } label: {
                    Label(
                        copied ? L10n.text("已复制指纹") : L10n.text("复制完整指纹"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary))
                .accessibilityIdentifier("transfer.localFingerprint.copy")
                Text(L10n.text("此标识用于加密连接与问题诊断，日常收发无需手动确认。"))
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .onChange(of: fingerprint) { _, _ in copied = false }
    }
}

private struct FingerprintBlock: View {
    let fingerprint: String
    let identifier: String

    var body: some View {
        Text(fingerprint)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(L10n.text("完整 TLS 指纹"))
            .accessibilityValue(fingerprint)
            .accessibilityIdentifier(identifier)
    }
}

struct TransferCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

#Preview("接收确认 · 大字体") {
    ZStack(alignment: .bottom) {
        Palette.scrim.ignoresSafeArea()
        IncomingFileCard(
            senderName: "附近的 MacBook",
            fileName: "共享的项目资料和图片.zip",
            size: 1_024_000,
            saveLocation: L10n.text("LimLink › 已接收"),
            queued: 1,
            accept: {},
            reject: {}
        )
        .padding(8)
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("进度环五种状态 · 深色") {
    HStack(spacing: 12) {
        ProgressRing(value: 0.25, state: .waiting, diameter: 64, lineWidth: 7)
        ProgressRing(value: 0.62, state: .running, diameter: 64, lineWidth: 7)
        ProgressRing(value: 0.48, state: .paused, diameter: 64, lineWidth: 7)
        ProgressRing(value: 0.71, state: .failed, diameter: 64, lineWidth: 7)
        ProgressRing(value: 1, state: .done, diameter: 64, lineWidth: 7)
    }
    .padding()
    .background(Palette.paper)
    .preferredColorScheme(.dark)
}
