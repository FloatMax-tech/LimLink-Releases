import Foundation
import LimLinkAppSupport
import LimLinkKit

enum ShareSendError: LocalizedError {
    case noDevices
    case notDelivered(String)

    var errorDescription: String? {
        switch self {
        case .noDevices: L10n.text("没有找到附近设备")
        case .notDelivered(let reason): reason
        }
    }
}

/// Discovers peers and sends one file from inside the share extension, so the person does not
/// have to switch to the app first.
enum ShareSender {
    static func discover() async throws -> [DiscoveredService] {
        let (configuration, identity) = try await prepare()
        let browser = LimLinkBrowser(host: configuration.hostApp, selfFingerprint: identity.fingerprint.base64URL)
        browser.setInterfaceAddresses(InterfaceAddresses.current())
        browser.start()
        defer { browser.stop() }

        for _ in 0..<16 {
            let peers = NearbyPeerSelection.visible(browser.partition.visible, ownFingerprint: identity.fingerprint.base64URL)
            if !peers.isEmpty {
                return peers.sorted { $0.instanceName.localizedStandardCompare($1.instanceName) == .orderedAscending }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return []
    }

    static func send(fileURL: URL, name: String, to peer: DiscoveredService) async throws {
        let (configuration, identity) = try await prepare()
        guard let announced = peer.fields.fingerprint,
              let expected = Fingerprint(base64URL: announced) else { throw ShareSendError.notDelivered(L10n.text("设备信息不完整")) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimLinkShareSend-\(UUID().uuidString)", isDirectory: true)
        let store = TransferFileStore(inbox: staging)
        let file = try await store.load(fileURL)
        defer {
            withExtendedLifetime(file) {}
            try? FileManager.default.removeItem(at: staging)
        }

        let connection = try await LimLinkConnection.connect(
            serviceName: peer.instanceName, identity: identity, trust: .allowListed([expected])
        )
        defer { connection.cancel() }

        let host = connection.remoteHost ?? peer.instanceName
        let client = SingleFileClient(
            local: configuration.hostApp,
            localAlias: configuration.deviceName,
            localDevType: configuration.deviceType.rawValue,
            localPort: Int(LimLinkProtocol.primaryPort),
            peerHost: host,
            peerAddressIsLocal: LocalAddressMatch.isLocal(host, interfaceAddresses: InterfaceAddresses.current()),
            txtAppRaw: peer.fields.app,
            txtAppPresent: peer.fields.entries["app"] != nil,
            deviceName: peer.instanceName,
            intent: .userTap,
            timestamp: DiagnosticTimestamps.format(Date()),
            fileID: withUnsafeBytes(of: UUID().uuid) { OpaqueToken.encode(Array($0)) },
            relativePath: name,
            source: file.source,
            clientSessionKey: UUID().uuidString
        )
        let tick = try await SingleFileExchange.run(
            connection: connection,
            client: client,
            responseLimits: HTTPResponseLimits(maximumHeaderBytes: 16 * 1024, maximumBodyBytes: 64 * 1024),
            idleTimeout: .seconds(120)
        ) { _ in }
        if case .failed(let error) = tick.status {
            throw ShareSendError.notDelivered(error.localizedDescription)
        }
        guard case .completed = tick.status else {
            throw ShareSendError.notDelivered(L10n.text("对方没有确认接收"))
        }
    }

    private static func prepare() async throws -> (LimLinkConfiguration, IdentityMaterial) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.limlink.dev.share"
        let config = try LimLinkConfiguration.make(
            bundleIdentifier: bundleID,
            deviceName: L10n.text("LimLink 分享"),
            deviceType: .iphone
        )
        let store = KeychainDeviceIdentity(configuration: config)
        let identity = try await Task.detached(priority: .userInitiated) {
            try store.loadOrCreate()
        }.value
        return (config, identity)
    }
}
