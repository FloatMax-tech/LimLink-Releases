@_exported import LimLinkCoreLogic
import Foundation
import Security

/// Host-facing configuration. `LimLinkConfig` is the same type.
/// The Kit owns transfer lifecycle; the host does not register for it.
public typealias LimLinkConfig = LimLinkConfiguration

public struct LimLinkConfiguration: Sendable, Equatable {
    public var hostApp: HostAppIdentity
    public var bundleIdentifier: String
    public var keychainService: String
    public var keychainAccessGroup: String?
    public var deviceName: String
    public var deviceType: DeviceType
    public var inviting: Bool
    public var capabilities: [String]
    /// macOS only. iOS ignores this and does not hold an idle-sleep activity.
    public var idleSleepPolicy: IdleSleepPolicy
    /// Folder finished files are saved into. Nil keeps partials in the private directory.
    public var saveLocation: URL?

    public init(
        hostApp: HostAppIdentity,
        bundleIdentifier: String,
        keychainService: String,
        keychainAccessGroup: String? = nil,
        deviceName: String,
        deviceType: DeviceType,
        inviting: Bool = false,
        capabilities: [String] = [],
        idleSleepPolicy: IdleSleepPolicy = .prevent,
        saveLocation: URL? = nil
    ) {
        self.hostApp = hostApp
        self.bundleIdentifier = bundleIdentifier
        self.keychainService = keychainService
        self.keychainAccessGroup = keychainAccessGroup
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.inviting = inviting
        self.capabilities = capabilities
        self.idleSleepPolicy = idleSleepPolicy
        self.saveLocation = saveLocation
    }

    public static func make(
        app: String = LimLinkProtocol.defaultApp,
        allowedPeerApps: Set<String>? = nil,
        bundleIdentifier: String = LimLinkProtocol.temporaryBundleIdentifier,
        keychainService: String? = nil,
        keychainAccessGroup: String? = nil,
        deviceName: String,
        deviceType: DeviceType,
        inviting: Bool = false,
        capabilities: [String] = [],
        idleSleepPolicy: IdleSleepPolicy = .prevent,
        saveLocation: URL? = nil
    ) throws -> LimLinkConfiguration {
        let hostApp = try HostAppIdentity(app: app, allowedPeers: allowedPeerApps)
        let service = keychainService ?? "\(bundleIdentifier).limlink.identity"
        return LimLinkConfiguration(
            hostApp: hostApp,
            bundleIdentifier: bundleIdentifier,
            keychainService: service,
            keychainAccessGroup: keychainAccessGroup,
            deviceName: deviceName,
            deviceType: deviceType,
            inviting: inviting,
            capabilities: capabilities,
            idleSleepPolicy: idleSleepPolicy,
            saveLocation: saveLocation
        )
    }
}

public enum DeviceType: String, Sendable, Equatable, CaseIterable {
    case android
    case windows
    case iphone
    case ipad
    case mac
}

public enum TransportScope: Sendable, Equatable {
    /// Ordinary LAN listener or connection.
    case localNetwork
    /// Dial `127.0.0.1` and do not advertise Bonjour.
    /// The listener is `NWListener(using:on:)` with `acceptLocalOnly` and no
    /// `requiredLocalEndpoint`. Combining those, or passing port 0 as a host
    /// endpoint, makes `start` return POSIX EINVAL.
    case loopback
}

public enum TLSClientCap: Sendable, Equatable {
    case only13
    case only12
}

public enum TransportFailure: Error, Sendable, Equatable {
    case addressInUse
    case posix(Int32)
    case dns(Int32)
    case tls(Int32)
    case timedOut
    case cancelled
    case tlsRejected
    case metadataMissing
    /// Every candidate port failed before a listener became ready.
    case notReady
    case identityKey(OSStatus)
    case identityCertificate
    case identityNotFound
    case keychain(OSStatus)
}

public struct VerifyBlockObservation: Sendable, Equatable {
    public var negotiatedVersionRaw: UInt16
    public var versionWasAvailable: Bool
    public var earlyDataAccepted: Bool
    public var sawCertificate: Bool
    public var acceptedFingerprint: Bool
}
