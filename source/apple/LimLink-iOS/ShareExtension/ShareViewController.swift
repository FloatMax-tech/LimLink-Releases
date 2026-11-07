import LimLinkAppSupport
import LimLinkKit
import UIKit
import UniformTypeIdentifiers

/// Share extension with a small action list, in the spirit of WeChat's share sheet:
/// send to a nearby device right here, keep the file for later, or close.
final class ShareViewController: UIViewController {
    private var file: SharedFile?
    private var devices: [DiscoveredService] = []
    private var operationTask: Task<Void, Never>?
    private var providerLoad: Progress?
    private var finished = false
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stack = UIStackView()
    private let content = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildHeader()
        buildBody()
        receiveSharedItem()
    }

    // MARK: Layout

    private func buildHeader() {
        let close = UIButton(type: .system)
        close.setTitle(L10n.text("关闭"), for: .normal)
        close.titleLabel?.font = .preferredFont(forTextStyle: .body)
        close.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let title = UILabel()
        title.text = "LimLink"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center

        let header = UIView()
        [close, title].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
        ])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(content)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func buildBody() {
        content.axis = .vertical
        content.spacing = 0
        showLoading(L10n.text("正在准备文件…"))
    }

    private func clearContent() {
        for subview in content.arrangedSubviews {
            content.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
    }

    private func showLoading(_ text: String) {
        clearContent()
        let row = UIStackView(arrangedSubviews: [spinner, label(text, style: .subheadline, color: .secondaryLabel)])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 40, left: 20, bottom: 20, right: 20)
        spinner.startAnimating()
        content.addArrangedSubview(row)
    }

    // MARK: Receiving the item

    private func receiveSharedItem() {
        guard !finished else { return }
        guard let provider = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap({ $0.attachments ?? [] })
            .first(where: { $0.hasItemConformingToTypeIdentifier(UTType.item.identifier) }) else {
            showError(L10n.text("没有可发送的文件。"))
            return
        }
        let type = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .item) == true
        } ?? UTType.item.identifier
        let suggested = provider.suggestedName

        providerLoad = provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] (url: URL?, error: Error?) in
            guard let self else { return }
            guard let url else {
                DispatchQueue.main.async { self.showError(L10n.text("无法读取这个项目，请重试。")) }
                return
            }
            do {
                let copy = try Self.copyToScratch(url, name: suggested ?? url.lastPathComponent)
                DispatchQueue.main.async { self.didReceive(copy) }
            } catch {
                DispatchQueue.main.async { self.showError(Self.message(for: error)) }
            }
        }
    }

    private func didReceive(_ file: SharedFile) {
        // Providers may finish after their Progress was cancelled. The unused lease cleans up.
        guard !finished else { return }
        providerLoad = nil
        spinner.stopAnimating()
        guard file.size <= TransferLimits.maximumFileBytes else {
            showError(L10n.text("单个文件最大支持 5 GB。"))
            return
        }
        self.file = file
        showActions()
    }

    // MARK: Actions

    private func showActions() {
        clearContent()
        guard let file else { return }
        content.addArrangedSubview(fileCard(file))
        content.addArrangedSubview(actionRow(icon: "paperplane", title: L10n.text("发送给附近设备"),
                                             subtitle: L10n.text("不用打开 LimLink"), action: #selector(chooseDevice)))
        content.addArrangedSubview(actionRow(icon: "tray.and.arrow.down", title: L10n.text("保存到 LimLink"),
                                             subtitle: L10n.text("打开 LimLink 后继续"), action: #selector(saveForLater)))
        content.addArrangedSubview(separator())
    }

    private func fileCard(_ file: SharedFile) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "doc"))
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .label
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let name = label(file.name, style: .body, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        let size = label(L10n.byteCount(Int64(file.size)),
                         style: .caption1, color: .secondaryLabel)
        let meta = UIStackView(arrangedSubviews: [name, size])
        meta.axis = .vertical
        meta.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, meta])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        return row
    }

    private func actionRow(icon: String, title: String, subtitle: String, action: Selector) -> UIView {
        let button = UIButton(type: .system)
        button.addTarget(self, action: action, for: .touchUpInside)
        let image = UIImageView(image: UIImage(systemName: icon))
        image.tintColor = .label
        image.contentMode = .scaleAspectFit
        image.widthAnchor.constraint(equalToConstant: 24).isActive = true
        image.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let titleLabel = label(title, style: .body)
        let subtitleLabel = label(subtitle, style: .caption1, color: .secondaryLabel)
        let meta = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        meta.axis = .vertical
        meta.spacing = 2
        let row = UIStackView(arrangedSubviews: [image, meta])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        row.isUserInteractionEnabled = false
        button.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: button.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -16),
        ])
        let wrapper = UIView()
        button.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            button.topAnchor.constraint(equalTo: wrapper.topAnchor),
            button.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        wrapper.addSubview(separator())
        wrapper.subviews.last?.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wrapper.subviews.last!.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 20),
            wrapper.subviews.last!.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            wrapper.subviews.last!.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    private func separator() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return view
    }

    private func label(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight = .regular,
                       color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style).withWeight(weight)
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    @objc private func saveForLater() {
        guard let file else { return }
        do {
            try SharedInbox.stage(file.url, name: file.name)
            showMessage(title: L10n.text("已保存到 LimLink"),
                        text: L10n.text("打开 LimLink 会自动选中这个文件，选择设备即可发送。"))
        } catch {
            showError(Self.message(for: error))
        }
    }

    @objc private func chooseDevice() {
        guard !finished, let file else { return }
        showLoading(L10n.text("正在查找附近设备…"))
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { withExtendedLifetime(file) {}; self.operationTask = nil }
            do {
                let devices = try await ShareSender.discover()
                try Task.checkCancellation()
                guard !self.finished else { return }
                self.spinner.stopAnimating()
                if devices.isEmpty {
                    self.showError(L10n.text("没有找到附近设备。请让另一台设备打开 LimLink，并连接同一 Wi-Fi。"))
                } else {
                    self.showDevices(devices, file: file)
                }
            } catch {
                guard !Task.isCancelled, !self.finished else { return }
                self.showError(L10n.text("无法访问本地网络，请在系统设置中允许 LimLink 分享使用本地网络。"))
            }
        }
    }

    private func showDevices(_ devices: [LimLinkKit.DiscoveredService], file: SharedFile) {
        self.devices = devices
        clearContent()
        content.addArrangedSubview(fileCard(file))
        content.addArrangedSubview(label(L10n.text("选择接收设备"), style: .headline).padded())
        for device in devices {
            let button = UIButton(type: .system)
            button.addTarget(self, action: #selector(deviceTapped(_:)), for: .touchUpInside)
            let icon = UIImageView(image: UIImage(systemName: Self.symbol(for: device)))
            icon.tintColor = .label
            icon.contentMode = .scaleAspectFit
            icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let name = label(device.instanceName, style: .body, weight: .medium)
            let kind = label(Self.kind(for: device), style: .caption1, color: .secondaryLabel)
            let meta = UIStackView(arrangedSubviews: [name, kind])
            meta.axis = .vertical
            meta.spacing = 2
            let row = UIStackView(arrangedSubviews: [icon, meta])
            row.axis = .horizontal
            row.spacing = 14
            row.alignment = .center
            row.isUserInteractionEnabled = false
            row.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 20),
                row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -20),
                row.topAnchor.constraint(equalTo: button.topAnchor, constant: 16),
                row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -16),
            ])
            button.accessibilityIdentifier = "share.peer.\(device.fields.fingerprint ?? device.instanceName)"
            button.tag = devices.firstIndex { $0.fields.fingerprint == device.fields.fingerprint } ?? 0
            content.addArrangedSubview(button)
            content.addArrangedSubview(separator())
        }
    }

    @objc private func deviceTapped(_ sender: UIButton) {
        guard !finished, let file, devices.indices.contains(sender.tag) else { return }
        let peer = devices[sender.tag]
        showProgress(file: file)
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { withExtendedLifetime(file) {}; self.operationTask = nil }
            do {
                try await ShareSender.send(fileURL: file.url, name: file.name, to: peer)
                try Task.checkCancellation()
                guard !self.finished else { return }
                self.showSent(file: file)
            } catch {
                guard !Task.isCancelled, !self.finished else { return }
                self.showError(L10n.text("发送失败：{0}", String(describing: error.localizedDescription)))
            }
        }
    }

    private func showProgress(file: SharedFile) {
        clearContent()
        content.addArrangedSubview(fileCard(file))
        let text = label(L10n.text("正在发送…"), style: .subheadline, color: .secondaryLabel)
        let row = UIStackView(arrangedSubviews: [spinner, text])
        row.axis = .horizontal
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        spinner.startAnimating()
        content.addArrangedSubview(row)
    }

    private func showSent(file: SharedFile) {
        showMessage(title: L10n.text("已发送"), text: L10n.text("对方确认后会保存「{0}」。", String(describing: file.name)), doneTitle: L10n.text("完成"))
    }

    private func showMessage(title: String, text: String, doneTitle: String = L10n.text("完成")) {
        clearContent()
        content.addArrangedSubview(label(title, style: .title3, weight: .semibold).padded())
        content.addArrangedSubview(label(text, style: .subheadline, color: .secondaryLabel).padded())
        let done = UIButton(type: .system)
        done.setTitle(doneTitle, for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.backgroundColor = .label
        done.setTitleColor(.systemBackground, for: .normal)
        done.layer.cornerRadius = 22
        done.heightAnchor.constraint(equalToConstant: 44).isActive = true
        done.addTarget(self, action: #selector(finishNow), for: .touchUpInside)
        let wrapper = UIView()
        done.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(done)
        NSLayoutConstraint.activate([
            done.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 20),
            done.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -20),
            done.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 24),
            done.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -24),
        ])
        content.addArrangedSubview(wrapper)
    }

    private func showError(_ text: String) {
        guard !finished else { return }
        spinner.stopAnimating()
        showMessage(title: L10n.text("无法分享"), text: text, doneTitle: L10n.text("关闭"))
    }

    @objc private func cancel() {
        finishNow()
    }

    @objc private func finishNow() {
        guard !finished else { return }
        finished = true
        providerLoad?.cancel()
        providerLoad = nil
        operationTask?.cancel()
        operationTask = nil
        // An in-flight operation retains its lease until its cancellation has unwound.
        file = nil
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: Helpers

    nonisolated private static func copyToScratch(_ url: URL, name: String) throws -> SharedFile {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ShareInboxError.notAFile }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= TransferLimits.maximumFileBytes else { throw ShareInboxError.tooLarge }

        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let destination = directory.appendingPathComponent(
            safeName.isEmpty || safeName == "." || safeName == ".." ? url.lastPathComponent : safeName
        )
        do {
            try manager.copyItem(at: url, to: destination)
            return SharedFile(url: destination, name: destination.lastPathComponent, size: size, directory: directory)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? ShareInboxError {
        case .tooLarge: L10n.text("单个文件最大支持 5 GB。")
        case .notAFile: L10n.text("请选择一个文件。")
        case .unavailable: L10n.text("共享空间不可用。请使用「发送给附近设备」，或在 LimLink 中选择文件。")
        default: L10n.text("无法读取这个项目，请重试。")
        }
    }

    private static func symbol(for peer: LimLinkKit.DiscoveredService) -> String {
        switch peer.fields.deviceType?.lowercased() {
        case "ipad": "ipad"
        case "mac": "laptopcomputer"
        case "iphone", "android": "iphone"
        default: "desktopcomputer"
        }
    }

    private static func kind(for peer: LimLinkKit.DiscoveredService) -> String {
        switch peer.fields.deviceType?.lowercased() {
        case "ipad": "iPad"
        case "mac": "Mac"
        case "iphone": "iPhone"
        case "android": "Android"
        case "windows": "Windows"
        default: peer.fields.app ?? "LimLink"
        }
    }
}

private final class SharedFile: Sendable {
    let url: URL
    let name: String
    let size: Int
    private let directory: URL

    init(url: URL, name: String, size: Int, directory: URL) {
        self.url = url
        self.name = name
        self.size = size
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private extension UIView {
    func padded() -> UIView {
        let wrapper = UIView()
        translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 20),
            trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -20),
            topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -8),
        ])
        return wrapper
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(weight == .semibold ? .traitBold : []) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
