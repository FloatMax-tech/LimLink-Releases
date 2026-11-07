import LimLinkAppSupport
import SwiftUI

@MainActor
struct DeviceIdentityView: View {
    let model: TransferModel
    @Binding var showingBindings: Bool
    @State private var draft: String
    @State private var isSaving = false
    @State private var saved = false
    @State private var saveError: LocalizedMessage?
    @State private var showingSupport = false
    @State private var showingPrivacy = false
    @State private var showingTerms = false
    @FocusState private var editingName: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: TransferModel, showingBindings: Binding<Bool>) {
        self.model = model
        _showingBindings = showingBindings
        _draft = State(initialValue: model.deviceName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    TransferCard(title: L10n.text("设备名称"), symbol: "pencil.line") {
                        TextField(L10n.text("给这台设备起个名字"), text: Binding(
                            get: { draft },
                            set: { draft = $0; saved = false; saveError = nil }
                        ))
                            .font(.title3.weight(.medium))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($editingName)
                            .padding(14)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityLabel(L10n.text("设备名称"))
                            .accessibilityIdentifier("transfer.deviceName.field")
                            .disabled(isSaving)
                            .onSubmit { if canSave { save() } }

                        Text(L10n.text("附近设备会看到这个名称。"))
                            .font(.callout)
                            .foregroundStyle(Palette.secondary)

                        if let problem = saveError ?? validationMessage {
                            Text(problem.text)
                                .font(.callout)
                                .foregroundStyle(Palette.danger)
                                .accessibilityIdentifier("transfer.deviceName.error")
                        } else if !model.canChangeDeviceName && !isSaving {
                            Text(L10n.text("连接或传输结束后即可修改名称。"))
                                .font(.callout)
                                .foregroundStyle(Palette.secondary)
                        }

                        Button(action: save) {
                            if isSaving {
                                HStack { ProgressView(); Text(L10n.text("正在保存…")) }
                            } else {
                                Label(L10n.text("保存名称"), systemImage: "checkmark")
                            }
                        }
                        .buttonStyle(TransferCapsuleButtonStyle(emphasis: .primary))
                        .disabled(!canSave)
                        .accessibilityIdentifier("transfer.deviceName.save")

                        if saved {
                            Label(L10n.text("已保存"), systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(Palette.signalText)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("transfer.deviceName.saved")
                                .transition(.opacity)
                            if case .failed = model.startup {
                                Text(L10n.text("名称已保存，局域网暂未就绪，请返回首页重试。"))
                                    .font(.callout)
                                    .foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                    TransferCard(title: L10n.text("语言"), symbol: "globe") { LanguagePicker() }
                    Button { showingBindings = true } label: {
                        HStack {
                            Label(L10n.text("设备绑定"), systemImage: "link")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Palette.secondary)
                                .accessibilityHidden(true)
                        }
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle(shape: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)))
                    .accessibilityIdentifier("binding.open")
                    SaveFolderCard(model: model)
                    TransferCard(title: L10n.text("相册"), symbol: "photo.on.rectangle") { ReceivedPhotoSettings() }
                    if let failure = model.lastStartupFailure {
                        TransferCard(title: L10n.text("上次连接问题"), symbol: "exclamationmark.triangle") {
                            Text(failure).font(.callout).foregroundStyle(Palette.secondary)
                                .accessibilityIdentifier("transfer.startupFailure")
                            Text(L10n.text("如果反复出现，请把这一行和发生时间告诉开发者。")).font(.caption).foregroundStyle(Palette.faint)
                        }
                    }
                    LocalFingerprintCard(fingerprint: model.ownFingerprint)
                    Button { showingSupport = true } label: {
                        Label(L10n.text("支持 LimLink"), systemImage: "heart")
                    }
                    .accessibilityIdentifier("support.open")
                    Button { showingPrivacy = true } label: {
                        Label(L10n.text("隐私政策"), systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("privacy.open")
                    Button { showingTerms = true } label: {
                        Label(L10n.text("用户协议与使用说明"), systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("terms.open")
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.paper)
            .navigationTitle(L10n.text("本机身份"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("关闭")) { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("transfer.identity.close")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .sheet(isPresented: $showingBindings) {
                DeviceBindingView(devices: model.devices, records: model.boundDevices, waiting: model.isBinding,
                                  bind: model.bindDevice, cancel: model.cancelBinding, unbind: model.unbindDevice,
                                  incoming: model.bindingRequest, decideIncoming: { model.decideBinding(accept: $0) })
            }
            .sheet(isPresented: $showingSupport) { SupportLimLinkView() }
            .sheet(isPresented: $showingPrivacy) { PrivacyPolicyView() }
            .sheet(isPresented: $showingTerms) { UsageTermsView() }
        }
    }

    private var validationMessage: LocalizedMessage? {
        do { _ = try DeviceNamePreference.validatedName(draft); return nil }
        catch { return L10n.error(error) }
    }

    private var canSave: Bool {
        guard !isSaving, model.canChangeDeviceName,
              let name = try? DeviceNamePreference.validatedName(draft) else { return false }
        return name != model.deviceName
    }

    private func save() {
        guard canSave else { return }
        editingName = false
        isSaving = true
        let proposed = draft
        Task {
            saveError = await model.saveDeviceName(proposed)
            isSaving = false
            if saveError == nil {
                draft = model.deviceName
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { saved = true }
            }
        }
    }
}

/// Where received files are saved. Choosing Files › Downloads once lets every later file go there.
@MainActor
private struct SaveFolderCard: View {
    let model: TransferModel
    @State private var choosing = false

    var body: some View {
        TransferCard(title: L10n.text("保存位置"), symbol: "folder") {
            if let folder = model.saveFolder {
                Label(L10n.text("收到的文件会自动保存到「{0}」", String(describing: folder.displayName)), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("transfer.saveFolder.current")
            } else {
                Label(L10n.text("收到的文件会自动保存到「{0}」", String(describing: model.defaultLocationName)), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("transfer.saveFolder.current")
                Text(L10n.text("在「文件」App 中可以找到。如需改存到「下载」，轻点下方按钮，在「浏览」中选择「下载」文件夹。"))
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
            }
            Button {
                choosing = true
            } label: {
                Label(model.saveFolder == nil ? L10n.text("改存到「下载」") : L10n.text("更改保存位置"), systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(TransferCapsuleButtonStyle(emphasis: .secondary))
            .accessibilityIdentifier("transfer.saveFolder.choose")
            if model.saveFolder != nil {
                Button(L10n.text("恢复默认（{0}）", String(describing: model.defaultLocationName))) { model.resetSaveFolder() }
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("transfer.saveFolder.reset")
            }
        }
        .sheet(isPresented: $choosing) {
            FolderPicker(pick: { url in Task { await model.chooseSaveFolder(url) } }, cancel: {})
                .ignoresSafeArea()
        }
    }
}
