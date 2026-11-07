import Foundation
import LimLinkAppSupport
import LimLinkKit
import Observation
import AppKit

/// App-owned consent and presentation. The Kit continues to own transfer lifecycle.
@MainActor @Observable
final class MacTransferModel {
    private(set) var startup: StartupState = .stopped
    private(set) var devices: [DiscoveredService] = []
    private(set) var selectedPeerID: String?
    /// Multi-device mode: clicking a device selects it instead of sending immediately.
    private(set) var multiSelectEnabled = false
    private(set) var selectedPeerIDs: Set<String> = []
    private(set) var selectedFile: TransferFile?
    private(set) var importing = false
    private(set) var isSending = false
    private(set) var receivingCount = 0
    private(set) var transfer: TransferProgress?
    private(set) var received: [SavedFile] = []
    private(set) var completion: FileTransferCompletion?

    func dismissCompletion(id: UUID) { if completion?.id == id { completion = nil } }
    @ObservationIgnored let receiveCompletions = ReceiveCompletionHistory()
    /// Completed outgoing transfers, newest first, for 最近.
    private(set) var recentSends: [RecentSend] = []
    var message: UserMessage?
    /// Technical summary of the last failed start, shown in the identity/settings panel.
    private(set) var lastStartupFailure: String?
    private(set) var ownFingerprint = ""
    private(set) var deviceName: String
    private(set) var updatingDeviceName = false
    private(set) var bindingRequest: IncomingDeviceBinding?
    private(set) var boundDevices: [DeviceBindingRecord] = []
    private(set) var isBinding = false
    @ObservationIgnored private var bindingController: DeviceBindingController?
    @ObservationIgnored private var bindingTask: Task<Void, Never>?
    @ObservationIgnored private var bindingConnection: LimLinkConnection?

    @ObservationIgnored private let deviceNames: DeviceNamePreference
    private var offers: [IncomingOffer] = []
    @ObservationIgnored private let files: TransferFileStore
    @ObservationIgnored private var configuration: LimLinkConfiguration?
    @ObservationIgnored private var identity: IdentityMaterial?
    @ObservationIgnored private var listener: LimLinkListener?
    @ObservationIgnored private var browser: LimLinkBrowser?
    @ObservationIgnored private var service: SingleFileService?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var acceptTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var outgoing: LimLinkConnection?
    @ObservationIgnored private var sendID: UUID?
    private var incoming: [UUID: LimLinkConnection] = [:]
    @ObservationIgnored private var incomingTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var offerTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var offerOwners: [String: UUID] = [:]
    @ObservationIgnored private var acceptedOffers: [String: IncomingOffer] = [:]
    @ObservationIgnored private var offerDestinations: [String: ReceiveFolderLease] = [:]

    @ObservationIgnored let folderStore: ReceiveFolderStore
    @ObservationIgnored private let receivedFiles = MacReceivedFileStore()
    @ObservationIgnored private var consent = MacReceiveConsent()
    private var sendPeerName = ""
    private var sendStartedAt = Date()
    @ObservationIgnored private var rateMeter = TransferRateMeter()

    init(folderStore: ReceiveFolderStore) {
        self.folderStore = folderStore
        let names = DeviceNamePreference()
        deviceNames = names
        let computer = Host.current().localizedName ?? "Mac"
        deviceName = names.resolvedName(fallback: (try? DeviceNamePreference.validatedName(computer)) ?? "Mac")
        files = TransferFileStore(inbox: folderStore.incomingDirectory)
        lastStartupFailure = UserDefaults.standard.string(forKey: Self.startupFailureKey)
    }

    var offer: IncomingOffer? { offers.first }
    var selectedPeer: DiscoveredService? {
        devices.first { peerID($0) == selectedPeerID }
    }
    var canSend: Bool {
        guard case .ready = startup else { return false }
        return selectedPeer != nil && selectedFile != nil && !importing && !isSending && !updatingDeviceName
    }

    /// Whether clicking a nearby device's “发送” can start a transfer right now.
    var canConnect: Bool {
        guard case .ready = startup else { return false }
        return selectedFile != nil && !importing && !isSending && !updatingDeviceName
    }

    /// Requests still waiting behind the one on screen.
    var queuedOfferCount: Int { max(offers.count - 1, 0) }

    var selectedPeers: [DiscoveredService] {
        devices.filter { selectedPeerIDs.contains(peerID($0)) }
    }

    var canMultiSelect: Bool { !isSending && selectedFile != nil }

    func setMultiSelect(_ enabled: Bool) {
        guard !isSending else { return }
        multiSelectEnabled = enabled && selectedFile != nil
        if !multiSelectEnabled { selectedPeerIDs.removeAll() }
    }

    func toggleMultiSelect() { setMultiSelect(!multiSelectEnabled) }

    func toggleSelection(_ peer: DiscoveredService) {
        guard multiSelectEnabled, !isSending else { return }
        let id = peerID(peer)
        if selectedPeerIDs.contains(id) { selectedPeerIDs.remove(id) } else { selectedPeerIDs.insert(id) }
    }

    var canChangeDeviceName: Bool {
        if case .starting = startup { return false }
        return !updatingDeviceName && !isSending && incoming.isEmpty
    }

    /// Saves before restarting discovery, without disturbing an active transfer.
    /// No suspension is allowed between the busy check and stopping the old listener.
    func saveDeviceName(_ proposed: String) async -> LocalizedMessage? {
        guard canChangeDeviceName else { return L10n.message("正在连接或传输，请结束后再修改名称。") }
        do {
            let name = try DeviceNamePreference.validatedName(proposed)
            guard name != deviceName else { return nil }
            updatingDeviceName = true
            defer { updatingDeviceName = false }
            deviceName = try deviceNames.save(name)
            stop()
            await start()
            return nil
        } catch {
            return L10n.error(error)
        }
    }

    func peerID(_ peer: DiscoveredService) -> String {
        peer.fields.fingerprint ?? "\(peer.app)|\(peer.instanceName)"
    }

    func select(_ peer: DiscoveredService) {
        guard !isSending else { return }
        selectedPeerID = peerID(peer)
    }

    #if DEBUG
    /// Fixed UI states for screenshots and manual checks; no network or keychain access.
    private func applyPreviewScenario() -> Bool {
        guard let scenario = ProcessInfo.processInfo.environment["LIMLINK_UI_TEST_SCENARIO"],
              ["empty", "devices", "sending", "incoming"].contains(scenario) else { return false }
        let storeScreenshots = ProcessInfo.processInfo.environment["LIMLINK_STORE_SCREENSHOTS"] == "1"
        if storeScreenshots { deviceName = "Mac" }
        startup = .ready(port: 52470)
        ownFingerprint = OpaqueToken.encode([UInt8](repeating: 1, count: 32))
        if scenario != "empty" {
            devices = [("Office PC", "windows", 2), (storeScreenshots ? "iPhone" : "Jun 的 iPhone", "iphone", 3), ("Pixel 9", "android", 4), (storeScreenshots ? "iPad" : "客厅 iPad", "ipad", 5)].map {
                DiscoveredService(instanceName: $0.0, fields: TXTFields(entries: [
                    "app": "limlink", "dt": $0.1, "fp": OpaqueToken.encode([UInt8](repeating: $0.2, count: 32))
                ]))
            }
            selectedFile = TransferFile(name: storeScreenshots ? "LimLink.pdf" : "设计稿-v3.fig", bytes: Array("preview".utf8))
        }
        if ProcessInfo.processInfo.environment["LIMLINK_UI_TEST_MULTI"] == "1", selectedFile != nil {
            multiSelectEnabled = true
            selectedPeerIDs = Set(devices.prefix(2).map { peerID($0) })
        }
        if scenario == "sending", let peer = devices.first {
            transfer = TransferProgress(fileName: "设计稿-v3.fig", bytesSent: 94_000_000, bytesTotal: 248_000_000,
                                        state: .sending, peerID: peerID(peer), peerName: peer.instanceName,
                                        reachedStep: 2, bytesPerSecond: 94_000_000)
            isSending = true
        }
        if scenario == "incoming" {
            offers = [IncomingOffer(id: "preview", senderName: "Pixel 9", fingerprint: "preview",
                                    fileName: "IMG_2041.HEIC", size: 3_200_000)]
        }
        return true
    }
    #endif

    func start() async {
        #if DEBUG
        if applyPreviewScenario() { return }
        #endif
        if case .starting = startup { return }
        if case .ready = startup { return }
        stop()
        let run = generation
        startup = .starting
        folderStore.refresh()
        reclaimReceiveStaging()
        do {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.limlink.dev"
            let type: DeviceType = .mac
            let config = try LimLinkConfiguration.make(
                bundleIdentifier: bundleID,
                deviceName: deviceName,
                deviceType: type,
                capabilities: ["binding-v1"]
            )
            let store = KeychainDeviceIdentity(configuration: config)
            let material = try await Task.detached(priority: .userInitiated) {
                try store.loadOrCreate()
            }.value
            try Task.checkCancellation()
            guard generation == run else { return }
            ownFingerprint = material.fingerprint.base64URL
            identity = material
            configuration = config
            let incomingDirectory = TransferStagingDirectories.shared.incoming
                .appendingPathComponent(run.uuidString, isDirectory: true)
            let bindingURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LimLink", isDirectory: true).appendingPathComponent("device-bindings-v1.json")
            do {
                let bindingStore = try DeviceBindingStore(url: bindingURL, ownFingerprint: ownFingerprint)
                let controller = DeviceBindingController(store: bindingStore, alias: config.deviceName, deviceType: config.deviceType.rawValue)
                controller.onChange = { [weak self, weak controller] _ in
                    Task { @MainActor in
                        guard let self, self.generation == run else { return }
                        self.bindingRequest = controller?.pending
                        self.boundDevices = controller?.store.all ?? []
                    }
                }
                bindingController = controller
                boundDevices = bindingStore.all
            } catch {
                bindingController = nil; boundDevices = []
                message = UserMessage(text: L10n.message("无法保存设备绑定，请继续逐文件确认。"))
            }
            let receiver = SingleFileService(configuration: config, maximumRetainedSessions: 4,
                                             deviceBinding: bindingController,
                                             receiveDirectory: incomingDirectory,
                                             maximumFileBytes: TransferLimits.maximumFileBytes)
            let endpoint = try await startListener(configuration: config, identity: material, run: run)
            guard generation == run, !Task.isCancelled else {
                endpoint.stop()
                if generation == run { startup = .stopped }
                return
            }
            service = receiver
            listener = endpoint
            let browse = LimLinkBrowser(host: config.hostApp, selfFingerprint: ownFingerprint)
            browse.setInterfaceAddresses(InterfaceAddresses.current())
            browse.start()
            browser = browse
            startup = .ready(port: endpoint.port)
            Self.clearStartupFailure()
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.generation == run else { return }
                    self.pullDevices()
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                }
            }
            acceptTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let connection = try await endpoint.nextConnection(timeout: .seconds(30))
                        guard let self, self.generation == run, !Task.isCancelled else {
                            connection.cancel()
                            return
                        }
                        // Limit held TLS connections, including connections awaiting a person.
                        guard self.incoming.count < 4 else {
                            connection.cancel()
                            continue
                        }
                        let id = UUID()
                        self.incoming[id] = connection
                        self.incomingTasks[id] = Task { [weak self] in
                            await self?.serveIncoming(connection, id: id, receiver: receiver, run: run)
                        }
                    } catch {
                        if Task.isCancelled { return }
                        if let failure = error as? TransportFailure, failure == .timedOut { continue }
                        guard let self, self.generation == run else { return }
                        self.stop()
                        self.startup = .failed(Self.networkMessage(error))
                        return
                    }
                }
            }
        } catch {
            guard generation == run else { return }
            if Task.isCancelled {
                stop()
            } else {
                stop()
                if let failure = error as? StartupFailure {
                    lastStartupFailure = Self.recordStartupFailure(Self.failureCode(failure))
                    startup = .failed(StartupRecovery.localizedMessage(for: failure))
                } else {
                    startup = .failed(Self.networkMessage(error))
                }
            }
        }
    }

    /// Retries bind failures that clear up on their own (Local Network permission prompt, Wi-Fi still
    /// coming up) instead of showing a failure that only a manual retry would fix.
    private func startListener(
        configuration: LimLinkConfiguration, identity: IdentityMaterial, run: UUID
    ) async throws -> LimLinkListener {
        var attempt = 0
        while true {
            do {
                return try await LimLinkListener.start(
                    configuration: configuration,
                    identity: identity,
                    trust: .acceptAndReport,
                    scope: .localNetwork,
                    advertise: BonjourAdvertisement(instanceName: configuration.deviceName)
                )
            } catch {
                guard let failure = Self.startupFailure(error), failure.isTransient,
                      attempt < StartupRecovery.retryDelays(for: failure).count else { throw error }
                let delays = StartupRecovery.retryDelays(for: failure)
                try await Task.sleep(for: delays[min(attempt, delays.count - 1)])
                guard generation == run else { throw CancellationError() }
                attempt += 1
            }
        }
    }

    static func startupFailure(_ error: Error) -> StartupFailure? {
        guard let failure = error as? TransportFailure else { return nil }
        switch failure {
        case .addressInUse: return .addressInUse
        case .timedOut, .notReady: return .timedOut
        case .dns(let code): return StartupRecovery.classify(dnsCode: code)
        case .posix(let code): return StartupRecovery.classify(posixCode: code)
        case .cancelled, .tls, .tlsRejected, .metadataMissing, .identityKey, .identityCertificate, .identityNotFound, .keychain:
            return nil
        }
    }

    /// Keeps the last startup failure across launches so it can be reported from 本机身份.
    private static let startupFailureKey = "limlink.lastStartupFailure"

    private static func recordStartupFailure(_ detail: String) -> String {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        let entry = "\(stamp) · \(detail)"
        UserDefaults.standard.set(entry, forKey: startupFailureKey)
        return entry
    }

    private static func clearStartupFailure() {
        UserDefaults.standard.removeObject(forKey: startupFailureKey)
    }

    private static func failureCode(_ failure: StartupFailure) -> String {
        switch failure {
        case .localNetworkPermission: L10n.text("本地网络权限 (-65570)")
        case .timedOut: L10n.text("超时")
        case .addressInUse: L10n.text("端口占用")
        case .networkDown: L10n.text("网络不可用")
        case .other(let detail): detail
        }
    }

    func bindDevice(_ peer: DiscoveredService) {
        guard !isBinding, bindingRequest == nil, !boundDevices.contains(where: { $0.peerFingerprint == peer.fields.fingerprint }), peer.fields.app == "limlink", let identity, let configuration, let controller = bindingController,
              let selectedFingerprint = peer.fields.fingerprint, let expected = Fingerprint(base64URL: selectedFingerprint), selectedFingerprint != ownFingerprint, controller.beginOutgoing() else { return }
        let run = generation
        isBinding = true
        bindingTask = Task { [weak self] in
            guard let self else { return }
            var link: LimLinkConnection?
            defer {
                controller.endOutgoing()
                link?.cancel()
                if self.generation == run { self.isBinding = false; self.bindingConnection = nil; self.bindingTask = nil }
            }
            do {
                let connection = try await LimLinkConnection.connect(serviceName: peer.instanceName, identity: identity, trust: .allowListed([expected]))
                link = connection
                try Task.checkCancellation()
                guard self.generation == run else { return }
                self.bindingConnection = connection
                let record = try await DeviceBindingClient.bind(connection: connection, selectedFingerprint: expected.base64URL, store: controller.store, alias: configuration.deviceName, deviceType: configuration.deviceType.rawValue)
                guard self.generation == run, !Task.isCancelled else {
                    try? controller.store.remove(peer: record.peerFingerprint, bindingID: record.bindingID)
                    return
                }
                self.boundDevices = controller.store.all
                self.message = UserMessage(text: L10n.message("设备已绑定，双方将自动接收文件。"))
            } catch {
                guard self.generation == run, !Task.isCancelled else { return }
                self.message = UserMessage(text: L10n.message("绑定未完成：对方拒绝、超时、连接中断或无法保存。请重试。"))
            }
        }
    }

    func decideBinding(accept: Bool) {
        guard let request = bindingRequest else { return }
        bindingController?.decide(pairID: request.id, accept: accept)
        bindingRequest = nil
    }

    func cancelBinding() {
        bindingTask?.cancel(); bindingTask = nil
        bindingConnection?.cancel(); bindingConnection = nil
        isBinding = false
    }

    func unbindDevice(_ record: DeviceBindingRecord) {
        guard let controller = bindingController else { return }
        do { try controller.unbind(record); boundDevices = controller.store.all }
        catch { boundDevices = controller.store.all; message = UserMessage(text: L10n.message("无法保存设备绑定，请继续逐文件确认。")); return }
        guard let peer = devices.first(where: { $0.fields.fingerprint == record.peerFingerprint }), let identity,
              let expected = Fingerprint(base64URL: record.peerFingerprint) else { return }
        Task {
            guard let connection = try? await LimLinkConnection.connect(serviceName: peer.instanceName, identity: identity, trust: .allowListed([expected])) else { return }
            defer { connection.cancel() }
            try? await DeviceBindingClient.revoke(connection: connection, record: record)
        }
    }

    func stop() {
        cancelBinding()
        bindingController?.stop()
        bindingRequest = nil
        bindingController = nil
        generation = UUID()
        cancelSend()
        refreshTask?.cancel()
        acceptTask?.cancel()
        refreshTask = nil
        acceptTask = nil
        for task in incomingTasks.values { task.cancel() }
        for connection in incoming.values { connection.cancel() }
        incomingTasks.removeAll()
        incoming.removeAll()
        listener?.stop()
        browser?.stop()
        listener = nil
        browser = nil
        service = nil
        configuration = nil
        identity = nil
        for timer in offerTimers.values { timer.cancel() }
        offerTimers.removeAll()
        offers.removeAll()
        offerOwners.removeAll()
        acceptedOffers.removeAll()
        offerDestinations.removeAll()
        consent = MacReceiveConsent()
        receivingCount = 0
        devices.removeAll()
        selectedPeerID = nil
        startup = .stopped
    }

    func importFile(_ url: URL) async {
        guard !isSending, !importing else { return }
        importing = true
        defer { importing = false }
        do {
            selectedFile = try await files.load(url)
        } catch is CancellationError {
            return
        } catch {
            selectedFile = nil
            message = UserMessage(text: Self.fileMessage(error))
        }
    }

    func reportImportFailure(_ error: Error) {
        if (error as? CocoaError)?.code == .userCancelled || error is CancellationError { return }
        message = UserMessage(text: L10n.message("无法选择这个文件，请重试。"))
    }

    var canChangeReceiveFolder: Bool { incoming.isEmpty }

    func chooseReceiveFolder(_ url: URL) throws {
        guard canChangeReceiveFolder else { throw ReceiveFailure.requestExpired }
        try folderStore.choose(folder: url)
        reclaimReceiveStaging()
    }

    private func reclaimReceiveStaging() {
        let destination = folderStore.incomingDirectory
        Task { [receivedFiles] in
            try? await receivedFiles.reclaimAbandonedFiles(in: destination)
        }
    }

    func removeSelectedFile() {
        guard !isSending && !importing else { return }
        selectedFile = nil
    }

    func dismissMessage() { message = nil }

    /// Moves a received file to the Trash, so it can still be restored from there.
    func deleteReceived(_ file: SavedFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already removed in Finder; just drop the row.
        } catch {
            message = UserMessage(text: L10n.message("无法删除「{0}」，请在 Finder 中删除。", String(describing: file.name)))
            return
        }
        received.removeAll { $0.url == file.url }
    }

    func decideOffer(id: String, accept: Bool) {
        guard let index = offers.firstIndex(where: { $0.id == id }), let service else { return }
        let selected = offers.remove(at: index)
        offerTimers.removeValue(forKey: id)?.cancel()
        let applied = service.decide(sessionID: id, accept: accept)
        consent.decide(sessionID: id, accept: accept && applied)
        if accept && applied {
            acceptedOffers[id] = selected
            receivingCount = acceptedOffers.count
        } else {
            offerDestinations.removeValue(forKey: id)
            if accept { message = UserMessage(text: L10n.message("这个文件请求已失效，请让对方重新发送。")) }
        }
    }

    func send() {
        if let peer = selectedPeer { send(to: [peer]) }
    }

    func send(to peer: DiscoveredService) { send(to: [peer]) }

    /// Sends to every selected device, one at a time, in list order.
    func sendToSelected() { send(to: selectedPeers) }

    private func send(to peers: [DiscoveredService]) {
        guard canConnect, !peers.isEmpty, let file = selectedFile,
              let identity, let configuration else { return }
        let id = UUID()
        sendID = id
        isSending = true
        sendPeerName = peers[0].instanceName
        sendStartedAt = Date()
        rateMeter = TransferRateMeter()
        multiSelectEnabled = false
        selectedPeerID = peerID(peers[0])
        transfer = TransferProgress(fileName: file.name, bytesSent: 0, bytesTotal: file.size, state: .connecting,
                                    peerID: peerID(peers[0]), peerName: peers[0].instanceName,
                                    batchPosition: 1, batchCount: peers.count)
        sendTask = Task { [weak self] in
            await self?.transmitBatch(peers: peers, file: file, identity: identity, configuration: configuration, id: id)
        }
    }

    /// Clears a finished transfer. The selected file is kept.
    func dismissTransfer() {
        guard !isSending, transfer?.state.isFinished ?? true else { return }
        if transfer?.state == .completed {
            selectedFile = nil
            selectedPeerID = nil
        }
        transfer = nil
    }

    func cancelSend() {
        sendID = nil
        outgoing?.cancel()
        outgoing = nil
        sendTask?.cancel()
        sendTask = nil
        if isSending { transfer?.state = .cancelled }
        isSending = false
    }

    private func transmitBatch(
        peers: [DiscoveredService], file: TransferFile, identity: IdentityMaterial,
        configuration: LimLinkConfiguration, id: UUID
    ) async {
        defer {
            withExtendedLifetime(file) {}
            if sendID == id {
                outgoing = nil
                isSending = false
                sendTask = nil
                sendID = nil
            }
        }
        for (index, peer) in peers.enumerated() {
            guard sendID == id, !Task.isCancelled else { return }
            if index > 0 {
                sendPeerName = peer.instanceName
                sendStartedAt = Date()
                rateMeter = TransferRateMeter()
                selectedPeerID = peerID(peer)
                transfer = TransferProgress(fileName: file.name, bytesSent: 0, bytesTotal: file.size, state: .connecting,
                                            peerID: peerID(peer), peerName: peer.instanceName,
                                            batchPosition: index + 1, batchCount: peers.count)
            }
            guard await transmit(peer: peer, file: file, identity: identity, configuration: configuration, id: id) else { return }
        }
        guard sendID == id else { return }
        selectedFile = nil
        selectedPeerID = nil
        selectedPeerIDs.removeAll()
        if peers.count > 1 { message = UserMessage(text: L10n.message("已发送到 {0} 台设备。", String(describing: peers.count))) }
    }

    /// One device in a batch. Returns true only when the receiver confirmed and saved the file.
    private func transmit(
        peer: DiscoveredService, file: TransferFile, identity: IdentityMaterial,
        configuration: LimLinkConfiguration, id: UUID
    ) async -> Bool {
        var link: LimLinkConnection?
        defer { link?.cancel() }
        do {
            guard let announced = peer.fields.fingerprint,
                  let expected = Fingerprint(base64URL: announced) else { throw TransportFailure.tlsRejected }
            let connection = try await LimLinkConnection.connect(
                serviceName: peer.instanceName, identity: identity, trust: .allowListed([expected])
            )
            link = connection
            guard sendID == id, !Task.isCancelled else { return false }
            outgoing = connection
            let pin = connection.peerFingerprint.base64URL
            guard pin != ownFingerprint else {
                throw TransferFailure.sameDevice
            }
            transfer?.state = .waitingForReceiver
            let host = connection.remoteHost ?? peer.instanceName
            var client = SingleFileClient(
                local: configuration.hostApp,
                localAlias: configuration.deviceName,
                localDevType: configuration.deviceType.rawValue,
                localPort: Int(listener?.port ?? LimLinkProtocol.primaryPort),
                peerHost: host,
                peerAddressIsLocal: LocalAddressMatch.isLocal(host, interfaceAddresses: InterfaceAddresses.current()),
                txtAppRaw: peer.fields.app,
                txtAppPresent: peer.fields.entries["app"] != nil,
                deviceName: peer.instanceName,
                intent: .userTap,
                timestamp: DiagnosticTimestamps.format(Date()),
                fileID: withUnsafeBytes(of: UUID().uuid) { OpaqueToken.encode(Array($0)) },
                relativePath: file.name,
                source: file.source,
                clientSessionKey: UUID().uuidString
            )
            client.bindingID = bindingController?.store.record(for: pin)?.bindingID
            let tick = try await SingleFileExchange.run(
                connection: connection, client: client,
                responseLimits: HTTPResponseLimits(maximumHeaderBytes: 16 * 1024, maximumBodyBytes: 64 * 1024),
                idleTimeout: .seconds(120)
            ) { [weak self] tick in
                // Queued UI updates must never retain the request's file chunk.
                let status = tick.status
                let bytesSent = tick.bytesSent
                let method = tick.request?.method
                let target = tick.request?.target
                Task { @MainActor in
                    self?.updateProgress(status: status, bytesSent: bytesSent, method: method, target: target, id: id)
                }
            }
            updateProgress(status: tick.status, bytesSent: tick.bytesSent,
                           method: tick.request?.method, target: tick.request?.target, id: id)
            if case .completed = tick.status { return true }
            return false
        } catch {
            guard sendID == id, !Task.isCancelled else { return false }
            let text = Self.networkMessage(error)
            transfer?.state = .failed(text)
            message = UserMessage(text: text)
            return false
        }
    }

    private func serveIncoming(
        _ connection: LimLinkConnection, id: UUID, receiver: SingleFileService, run: UUID
    ) async {
        let pin = connection.peerFingerprint.base64URL
        defer {
            connection.cancel()
            if generation == run {
                consent.disconnect(connectionID: id)
                incoming.removeValue(forKey: id)
                incomingTasks.removeValue(forKey: id)
                // Cleanup belongs to this TLS connection, including when another connection
                // uses the same certificate or a new listener generation has already started.
                let owned = Set(offerOwners.filter { $0.value == id }.map(\.key))
                let interrupted = acceptedOffers.keys.contains { owned.contains($0) }
                for offerID in owned {
                    offerTimers.removeValue(forKey: offerID)?.cancel()
                    acceptedOffers.removeValue(forKey: offerID)
                    offerDestinations.removeValue(forKey: offerID)
                    offerOwners.removeValue(forKey: offerID)
                }
                offers.removeAll { owned.contains($0.id) }
                receivingCount = acceptedOffers.count
                if interrupted {
                    message = UserMessage(text: L10n.message("接收已中断，文件尚未保存。请让对方保持 LimLink 在前台后重新发送。"))
                }
            }
        }
        guard pin != ownFingerprint, generation == run else { return }
        guard !Task.isCancelled else { return }
        receiver.trust(pin)
        // Admit this TLS identity for metadata; each file still awaits the recipient's consent.
        await receiver.serve(
            connection,
            requestLimits: HTTPRequestLimits(maximumHeaderBytes: 16 * 1024, maximumBodyBytes: TransferLimits.chunkBytes),
            idleTimeout: .seconds(120),
            discardSessionsOnDisconnect: true,
            onPending: { [weak self] pending in
                Task { @MainActor in self?.receiveOffer(pending, connectionID: id, run: run) }
            },
            onPublished: { [weak self] file in
                guard let self else { throw ReceiveFailure.requestExpired }
                return try await self.saveVerifiedFile(file, connectionID: id, run: run)
            }
        )
    }

    private func receiveOffer(_ pending: PendingSession, connectionID: UUID, run: UUID) {
        guard generation == run, let service, let connection = incoming[connectionID],
              connection.peerFingerprint.base64URL == pending.fingerprint,
              offerOwners[pending.sessionID] == nil else { return }
        offerOwners[pending.sessionID] = connectionID
        guard let name = pending.fileName, !name.isEmpty, let size = pending.size,
              size >= 0, size <= TransferLimits.maximumFileBytes else {
            service.decide(sessionID: pending.sessionID, accept: false)
            message = UserMessage(text: L10n.message("无法接收这个文件：文件信息不完整，或超过 5 GB。"))
            return
        }
        guard offers.count + acceptedOffers.count < 4 else {
            service.decide(sessionID: pending.sessionID, accept: false)
            return
        }
        guard consent.register(pending, connectionID: connectionID) else {
            service.decide(sessionID: pending.sessionID, accept: false)
            return
        }
        let discoveredName = devices.first { $0.fields.fingerprint == pending.fingerprint }?.instanceName
        let sender = [pending.senderName, discoveredName].compactMap { $0 }
            .compactMap { try? DeviceNamePreference.validatedName($0) }.first ?? L10n.text("附近设备")
        let destination = folderStore.acquireDestination()
        offerDestinations[pending.sessionID] = destination
        offers.append(IncomingOffer(
            id: pending.sessionID, senderName: sender, fingerprint: pending.fingerprint, fileName: name, size: size,
            saveLocation: destination.displayName
        ))
        if bindingController?.permits(peer: pending.fingerprint, bindingID: pending.bindingID) == true {
            decideOffer(id: pending.sessionID, accept: true)
            return
        }
        offerTimers[pending.sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(120))
                guard let self, self.generation == run else { return }
                self.decideOffer(id: pending.sessionID, accept: false)
            } catch { }
        }
    }

    private func saveVerifiedFile(_ file: PublishedFile, connectionID: UUID, run: UUID) async throws -> String {
        guard generation == run, consent.permits(file, connectionID: connectionID), offerOwners[file.sessionID] == connectionID,
              let approved = acceptedOffers[file.sessionID],
              approved.fingerprint == file.fingerprint, approved.size == file.size,
              let destination = offerDestinations[file.sessionID],
              let verifiedURL = file.fileURL else {
            throw ReceiveFailure.requestExpired
        }
        defer { withExtendedLifetime(destination) { } }
        do {
            let published = try await receivedFiles.save(name: file.fileName, verifiedURL: verifiedURL, size: file.size, destination: destination.url)
            let saved = SavedFile(name: published.name, url: published.url, size: published.size, accessRoot: destination.url)
            if !received.contains(where: { $0.url == saved.url }) { received.insert(saved, at: 0) }
            receiveCompletions.recordSaved(saved)
            completion = FileTransferCompletion(fileName: saved.name, direction: .receiving)
            ReceivedPhotoLibrary.shared.didReceive(saved, sourceAccess: destination)
            if generation == run {
                consent.remove(sessionID: file.sessionID)
                acceptedOffers.removeValue(forKey: file.sessionID)
                offerDestinations.removeValue(forKey: file.sessionID)
                receivingCount = acceptedOffers.count
            }
            return saved.name
        } catch {
            message = UserMessage(text: Self.fileMessage(error))
            if generation == run {
                consent.remove(sessionID: file.sessionID)
                acceptedOffers.removeValue(forKey: file.sessionID)
                offerDestinations.removeValue(forKey: file.sessionID)
                receivingCount = acceptedOffers.count
            }
            throw error
        }
    }

    private func pullDevices() {
        browser?.setInterfaceAddresses(InterfaceAddresses.current())
        devices = NearbyPeerSelection.visible(browser?.partition.visible ?? [], ownFingerprint: ownFingerprint)
            .sorted { $0.instanceName.localizedStandardCompare($1.instanceName) == .orderedAscending }
        if selectedPeer == nil { selectedPeerID = nil }
        if !selectedPeerIDs.isEmpty {
            selectedPeerIDs.formIntersection(Set(devices.map(peerID)))
        }
    }

    private func updateProgress(
        status: SingleFileClientStatus, bytesSent: Int, method: String?, target: String?, id: UUID
    ) {
        guard sendID == id else { return }
        transfer?.bytesSent = bytesSent
        updateRate(bytesSent: bytesSent)
        switch status {
        case .completed:
            if transfer?.state != .completed, let transfer {
                completion = FileTransferCompletion(fileName: transfer.fileName, direction: .sending)
                recentSends.insert(RecentSend(name: transfer.fileName, peer: sendPeerName, date: Date()), at: 0)
            }
            transfer?.state = .completed
        case .failed(let error):
            let text = Self.hostMessage(error)
            transfer?.state = .failed(text)
            message = UserMessage(text: text)
        case .paused:
            transfer?.state = .paused
        case .inProgress:
            if method == "PUT" {
                transfer?.state = .sending
            } else if let target,
                      target.contains("/complete") || target.contains("/finish") {
                transfer?.state = .finishing
            } else {
                transfer?.state = .waitingForReceiver
            }
        }
    }

    var progressSnapshot: BatchProgressSnapshot {
        let phase: BatchProgressPhase
        if let transfer {
            switch transfer.state {
            case .connecting, .waitingForReceiver, .finishing: phase = .indeterminate
            case .sending: phase = .active
            case .paused: phase = .paused(reason: L10n.text("已暂停"))
            case .completed: phase = .completed(verified: true)
            case .cancelled: phase = .failed(summary: L10n.text("已取消"))
            case .failed(let text): phase = .failed(summary: text.text)
            }
            if isSending || receivingCount == 0 {
                let elapsed = max(0.001, Date().timeIntervalSince(sendStartedAt))
                let speed = Double(transfer.bytesSent) / elapsed
                return BatchProgressSnapshot(direction: .sending, peerName: sendPeerName,
                    bytesTransferred: Int64(transfer.bytesSent), totalBytes: Int64(transfer.bytesTotal),
                    totalBytesKnown: true, speedBytesPerSecond: speed > 0 ? speed : nil,
                    secondsRemaining: speed > 0 ? Double(transfer.bytesTotal - transfer.bytesSent) / speed : nil,
                    currentIndex: 1, totalCount: 1, phase: phase)
            }
        }
        if let receiving = acceptedOffers.values.first {
            return BatchProgressSnapshot(direction: .receiving, peerName: receiving.senderName,
                bytesTransferred: 0, totalBytes: Int64(receiving.size), totalBytesKnown: true,
                speedBytesPerSecond: nil, secondsRemaining: nil, currentIndex: 1,
                totalCount: receivingCount, phase: .indeterminate)
        }
        return BatchProgressSnapshot(direction: .sending, peerName: L10n.text("附近设备"), bytesTransferred: 0,
            totalBytes: nil, totalBytesKnown: false, speedBytesPerSecond: nil, secondsRemaining: nil,
            currentIndex: 0, totalCount: 0, phase: .idle)
    }

    private func updateRate(bytesSent: Int) {
        // Compute first: assigning through `transfer?` while reading `transfer` is an exclusivity violation.
        let speed = rateMeter.record(bytes: bytesSent)
        transfer?.bytesPerSecond = speed
    }

    private enum TransferFailure: Error { case sameDevice }
    private enum ReceiveFailure: Error { case requestExpired }

    private static func networkMessage(_ error: Error) -> LocalizedMessage {
        if error is TransferFailure { return L10n.message("这是本机，不能发送给自己。") }
        if let host = error as? TransferHostError { return hostMessage(host) }
        if let failure = error as? TransportFailure {
            switch failure {
            case .timedOut: return L10n.message("连接超时，请确认对方仍在同一 Wi-Fi 上，并打开了 LimLink。")
            case .tlsRejected: return L10n.message("设备连接信息已变化，请刷新附近设备后重试。")
            case .identityKey, .identityCertificate, .identityNotFound, .keychain:
                return L10n.message("无法读取本机身份，请重试或检查应用签名。")
            case .cancelled: return L10n.message("连接已断开，请让双方保持 LimLink 在前台后重试。")
            default: break
            }
        }
        return L10n.message("局域网连接失败。请检查本地网络权限，让双方保持 LimLink 在前台后重试。")
    }

    private static func hostMessage(_ error: TransferHostError) -> LocalizedMessage {
        switch error {
        case .sameDeviceOtherApp: return L10n.message("这是本机上的另一个 App，不能互传。")
        case .appNotInInteropGroup: return L10n.message("对方应用暂不支持互传。")
        case .inviteTicketInvalid: return L10n.message("邀请已失效，请重新连接。")
        case .wire(let error):
            switch error.code {
            case .rejected: return L10n.message("对方拒绝接收这个文件。")
            case .notPaired: return L10n.message("对方版本仍需要配对，请将两台设备更新到最新版。")
            case .checksumMismatch: return L10n.message("文件校验失败，请重新发送。")
            default: return L10n.message("文件传输失败，请重新发送。")
            }
        }
    }

    private static func fileMessage(_ error: Error) -> LocalizedMessage {
        guard let failure = error as? TransferFileStoreError else { return L10n.message("文件操作失败，请重试。") }
        switch failure {
        case .fileTooLarge: return L10n.message("单个文件最大支持 5 GB，请选择较小的文件。")
        case .notRegularFile: return L10n.message("请选择单个普通文件，文件夹暂不支持。")
        case .invalidFileName: return L10n.message("文件名包含不支持的字符，请重命名后重试。")
        case .readFailed: return L10n.message("读不到这个文件，请重新选择并确认访问权限。")
        case .saveFailed: return L10n.message("收到的文件未能保存，请检查本机剩余空间后重新发送。")
        case .listFailed: return L10n.message("暂时无法读取已接收文件，请重试。")
        case .sizeMismatch: return L10n.message("文件大小发生变化，请重新发送。")
        }
    }
}
