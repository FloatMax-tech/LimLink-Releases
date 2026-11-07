import Foundation
import LimLinkKit
import SwiftUI
import UIKit

/// Minimal send/receive screen. Strings stay in the app; the Kit does not localize.
final class TransferLab: ObservableObject {
    @Published var devices: [DiscoveredService] = []
    @Published var diagnostics: [DiscoveredService] = []
    @Published var mismatch: [AppMismatchLogEntry] = []
    @Published var status = "正在准备"
    @Published var alertMessage: String?
    @Published var selectedName: String?
    @Published var manualHost = ""
    @Published var manualPort = "52470"
    @Published var chosenFile: String?
    @Published var executableWarning = false
    @Published var received: [String] = []
    @Published var trustedLabel = ""
    @Published var pendingFingerprint: String?
    @Published var pendingSessionID: String?
    @Published var ticketNotes: [String] = []

    private var configuration: LimLinkConfiguration?
    private var identity: IdentityMaterial?
    private var listener: LimLinkListener?
    private var browser: LimLinkBrowser?
    private var service: SingleFileService?
    private var logDirectory: URL?
    private var inbox: URL?
    private var trusted: Set<String> = []
    private var fileBytes: [UInt8] = []
    private var fileName = ""
    private var refresh: Task<Void, Never>?
    private var accept: Task<Void, Never>?

    func start() async {
        guard listener == nil else { return }
        trusted = Set(UserDefaults.standard.stringArray(forKey: Self.trustKey) ?? [])
        let idiom = UIDevice.current.userInterfaceIdiom
        let deviceType: DeviceType = idiom == .pad ? .ipad : .iphone
        do {
            let configuration = try LimLinkConfiguration.make(
                deviceName: UIDevice.current.name,
                deviceType: deviceType
            )
            self.configuration = configuration
            let store = KeychainDeviceIdentity(configuration: configuration)
            let material = try store.loadOrCreate()
            identity = material
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            logDirectory = support
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let inbox = documents.appendingPathComponent("LimLinkInbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            self.inbox = inbox
            let service = SingleFileService(
                configuration: configuration,
                trustedFingerprints: trusted,
                onPending: { [weak self] pending in
                    self?.incomingNeedsDecision(pending)
                },
                onDiagnostic: { [weak self] note in
                    DispatchQueue.main.async {
                        self?.ticketNotes.append(note.message)
                    }
                },
                onPublished: { [weak self] name, bytes in
                    self?.save(name: name, bytes: bytes)
                }
            )
            self.service = service
            let listener = try await LimLinkListener.start(
                configuration: configuration,
                identity: material,
                trust: .acceptAndReport,
                scope: .localNetwork,
                advertise: BonjourAdvertisement(instanceName: configuration.deviceName)
            )
            self.listener = listener
            let browser = LimLinkBrowser(host: configuration.hostApp, selfFingerprint: material.fingerprint.base64URL)
            browser.setInterfaceAddresses(InterfaceAddresses.current())
            browser.start()
            self.browser = browser
            status = "正在监听 \(listener.port)"
            reloadLog()
            refresh = Task { [weak self] in
                while !Task.isCancelled {
                    self?.pullBrowser()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            accept = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let listener = self.listener, let service = self.service else { return }
                    do {
                        let connection = try await listener.nextConnection(timeout: .seconds(30))
                        self.autoTrustIncoming(connection.peerFingerprint.base64URL)
                        Task { await service.serve(connection) }
                    } catch {
                        continue
                    }
                }
            }
        } catch {
            status = "启动失败"
            alertMessage = String(describing: error)
        }
    }

    func select(_ service: DiscoveredService) {
        selectedName = service.instanceName
        trustedLabel = service.fields.fingerprint.map { "指纹 \($0)" } ?? "没有指纹"
    }

    func trustSelected() {
        let fingerprint = selectedName.flatMap { name in
            devices.first { $0.instanceName == name }?.fields.fingerprint
        } ?? pendingFingerprint
        guard let fingerprint, !fingerprint.isEmpty else {
            alertMessage = "没有指纹，不能连接"
            return
        }
        trusted.insert(fingerprint)
        UserDefaults.standard.set(Array(trusted), forKey: Self.trustKey)
        service?.trust(fingerprint)
        pendingFingerprint = nil
        trustedLabel = "已信任 \(fingerprint)"
    }

    func acceptPending() {
        guard let pendingSessionID else { return }
        service?.decide(sessionID: pendingSessionID, accept: true)
        self.pendingSessionID = nil
    }

    /// `LimLinkTransferLab` Debug only. The LimLink-iOS target does not define this flag.
    private func autoTrustIncoming(_ fingerprint: String) {
        #if LIMLINK_TEST_AUTOTRUST
        // TODO(protocol §4.3): remove when SAS lands
        guard !fingerprint.isEmpty else { return }
        trusted.insert(fingerprint)
        UserDefaults.standard.set(Array(trusted), forKey: Self.trustKey)
        service?.trust(fingerprint)
        DispatchQueue.main.async {
            self.trustedLabel = "已信任 \(fingerprint)"
        }
        #endif
    }

    private func incomingNeedsDecision(_ pending: PendingSession) {
        #if LIMLINK_TEST_AUTOTRUST
        // TODO(protocol §4.3): remove when SAS lands
        service?.trust(pending.fingerprint)
        service?.decide(sessionID: pending.sessionID, accept: true)
        #else
        DispatchQueue.main.async {
            self.pendingSessionID = pending.sessionID
            self.status = "等待接收"
        }
        #endif
    }

    func takeFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            alertMessage = "读不到这个文件"
            return
        }
        fileBytes = [UInt8](data)
        fileName = url.lastPathComponent
        chosenFile = "\(fileName)（\(Self.decimalSize(fileBytes.count))）"
        executableWarning = FileNameSafety.warnsExecutable(fileName)
    }

    func sendSelected() {
        guard !fileBytes.isEmpty else {
            alertMessage = "先选择文件"
            return
        }
        guard let name = selectedName,
              let peer = devices.first(where: { $0.instanceName == name }) else {
            alertMessage = "先选择一台设备"
            return
        }
        guard let fingerprint = peer.fields.fingerprint, trusted.contains(fingerprint) else {
            alertMessage = "先信任此指纹"
            return
        }
        let raw = peer.fields.app
        let present = peer.fields.entries["app"] != nil
        Task {
            await self.transmit(
                serviceName: peer.instanceName,
                host: nil,
                port: LimLinkProtocol.primaryPort,
                fingerprint: fingerprint,
                txtApp: raw,
                txtPresent: present,
                deviceName: peer.instanceName
            )
        }
    }

    func sendManual() {
        guard !fileBytes.isEmpty else {
            alertMessage = "先选择文件"
            return
        }
        guard let port = UInt16(manualPort), !manualHost.isEmpty else {
            alertMessage = "先填写地址和端口"
            return
        }
        Task {
            await self.transmit(
                serviceName: nil,
                host: self.manualHost,
                port: port,
                fingerprint: nil,
                txtApp: nil,
                txtPresent: false,
                deviceName: self.manualHost
            )
        }
    }

    func clearDiagnostics() {
        guard let logDirectory else { return }
        let directory = logDirectory
        mismatch = []
        ticketNotes = []
        Task {
            try? await LimLink.clearDiagnosticsLog(at: directory)
        }
    }

    private func transmit(
        serviceName: String?,
        host: String?,
        port: UInt16,
        fingerprint: String?,
        txtApp: String?,
        txtPresent: Bool,
        deviceName: String
    ) async {
        guard let identity, let configuration else { return }
        do {
            let connection: LimLinkConnection
            if let serviceName {
                guard let fingerprint, let peer = Fingerprint(base64URL: fingerprint) else {
                    await show("没有指纹，不能连接")
                    return
                }
                connection = try await LimLinkConnection.connect(
                    serviceName: serviceName,
                    identity: identity,
                    trust: .allowListed([peer])
                )
            } else if let host {
                connection = try await LimLinkConnection.connect(
                    host: host,
                    port: port,
                    identity: identity,
                    trust: .acceptAndReport
                )
                let seen = connection.peerFingerprint.base64URL
                guard trusted.contains(seen) else {
                    connection.cancel()
                    await MainActor.run { self.pendingFingerprint = seen }
                    await show("先信任此指纹")
                    return
                }
            } else {
                return
            }
            let peerAddress = connection.remoteHost ?? host ?? ""
            let onThisDevice = LocalAddressMatch.isLocal(
                peerAddress,
                interfaceAddresses: InterfaceAddresses.current()
            )
            let client = SingleFileClient(
                local: configuration.hostApp,
                localAlias: configuration.deviceName,
                localDevType: configuration.deviceType.rawValue,
                localPort: Int(listener?.port ?? port),
                peerHost: peerAddress.isEmpty ? (serviceName ?? deviceName) : peerAddress,
                peerAddressIsLocal: onThisDevice,
                txtAppRaw: txtApp,
                txtAppPresent: txtPresent,
                deviceName: deviceName,
                intent: .userTap,
                timestamp: DiagnosticTimestamps.format(Date()),
                fileID: OpaqueToken.encode(Array(UUID().uuidString.utf8.prefix(16))),
                relativePath: fileName,
                bytes: fileBytes,
                clientSessionKey: UUID().uuidString
            )
            let tick = try await SingleFileExchange.run(connection: connection, client: client) { tick in
                if let entry = tick.logEntry {
                    self.record(entry)
                }
                let sent = tick.bytesSent
                let total = tick.bytesTotal
                DispatchQueue.main.async {
                    self.status = "正在发送 \(sent)/\(total)（\(Self.decimalSize(total))）"
                }
            }
            connection.cancel()
            switch tick.status {
            case .completed(let finalName):
                await MainActor.run { self.status = "发送完成 \(finalName)" }
            case .failed(let error):
                await show(Self.prompt(error))
            case .paused(let committedBytes):
                await MainActor.run { self.status = "已暂停 \(committedBytes)" }
            case .inProgress:
                break
            }
        } catch {
            await show(String(describing: error))
        }
    }

    private func save(name: String, bytes: [UInt8]) {
        guard let inbox else { return }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        let unique = FileNameSafety.uniqueName(name, existing: Set(existing))
        let url = inbox.appendingPathComponent(unique)
        do {
            try Data(bytes).write(to: url, options: .atomic)
            DispatchQueue.main.async {
                self.received.append(unique)
                self.status = "已保存到本机 \(unique)"
            }
        } catch {
            DispatchQueue.main.async {
                self.alertMessage = "保存失败"
            }
        }
    }

    private func pullBrowser() {
        browser?.setInterfaceAddresses(InterfaceAddresses.current())
        let part = browser?.partition
        DispatchQueue.main.async {
            self.devices = part?.visible ?? []
            self.diagnostics = part?.diagnosticOnly ?? []
        }
    }

    private func record(_ entry: AppMismatchLogEntry) {
        guard let logDirectory, let store = try? DiagnosticLogFile(directory: logDirectory) else { return }
        try? store.record(entry, clock: DiagnosticClock(now: Date()))
        reloadLog()
    }

    private func reloadLog() {
        guard let logDirectory, let store = try? DiagnosticLogFile(directory: logDirectory) else { return }
        let entries = (try? store.load(clock: DiagnosticClock(now: Date())).entries) ?? []
        DispatchQueue.main.async { self.mismatch = entries }
    }

    private func show(_ message: String) async {
        await MainActor.run {
            self.alertMessage = message
            self.status = message
        }
    }

    private static let trustKey = "limlink.trustedFingerprints"

    static func decimalSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unit])
    }

    static func prompt(_ error: TransferHostError) -> String {
        switch error {
        case .sameDeviceOtherApp:
            return "这是本机上的另一个 App，不能互传"
        case .appNotInInteropGroup:
            return "对方是另一个 App，暂不支持互传"
        case .inviteTicketInvalid:
            return "邀请已失效，请重新生成邀请码，让对方再输入一次"
        case .wire(let error):
            return error.code.rawValue
        }
    }
}
