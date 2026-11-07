public struct DiscoveredService: Hashable, Sendable {
    public var instanceName: String
    public var fields: TXTFields
    /// Resolved addresses, when the browse result has them. Empty defers the same-device check until `hello`.
    public var addresses: [String]

    public init(instanceName: String, fields: TXTFields, addresses: [String] = []) {
        self.instanceName = instanceName
        self.fields = fields
        self.addresses = addresses
    }

    public var app: String { fields.normalizedApp }
}

public struct DiscoveryPartition: Equatable, Sendable {
    /// In the allow-list and not another app on this device. These are the hello targets.
    public var visible: [DiscoveredService]
    /// TXT `app` is outside the allow-list. Grey in diagnostics. Do not hello them.
    public var diagnosticOnly: [DiscoveredService]

    public init(visible: [DiscoveredService], diagnosticOnly: [DiscoveredService]) {
        self.visible = visible
        self.diagnosticOnly = diagnosticOnly
    }

    public var helloTargets: [DiscoveredService] { visible }
}

/// Filter discovery results. Own fingerprint is removed (protocol 3.3).
/// Allow-list runs before same-device. Another in-group app on this device is in neither list.
/// A new TXT record is applied by calling this again.
public func partitionDiscoveredServices(
    _ services: [DiscoveredService],
    host: HostAppIdentity,
    selfFingerprint: String?,
    localAddresses: Set<String> = []
) -> DiscoveryPartition {
    var visible: [DiscoveredService] = []
    var diagnosticOnly: [DiscoveredService] = []
    for service in services {
        if let selfFingerprint, service.fields.fingerprint == selfFingerprint {
            continue
        }
        let decision = TxtPrefilter.decide(
            peerApp: service.fields.entries["app"] != nil ? service.fields.app : nil,
            addresses: service.addresses,
            localAddresses: localAddresses,
            host: host,
            path: .browse
        )
        switch decision.placement {
        case .visible:
            visible.append(service)
        case .diagnosticOnly:
            diagnosticOnly.append(service)
        case .hidden:
            break
        }
    }
    return DiscoveryPartition(visible: visible, diagnosticOnly: diagnosticOnly)
}

public enum TxtBrowseChange: Equatable, Sendable {
    /// `NWBrowser.Result.Change.changed`. The new TXT replaces the previous one.
    case changed(old: DiscoveredService, new: DiscoveredService)
}

/// Full browse roster, including peers the filter has parked or hidden.
/// Applying `.changed` only re-runs the filter. It never opens a connection.
public struct TxtBrowseRoster: Equatable, Sendable {
    public private(set) var services: [DiscoveredService]

    public init(services: [DiscoveredService] = []) {
        self.services = services
    }

    public mutating func applyChanges(
        _ changes: [TxtBrowseChange],
        host: HostAppIdentity,
        selfFingerprint: String?,
        localAddresses: Set<String> = []
    ) -> (partition: DiscoveryPartition, connects: Bool) {
        for change in changes {
            switch change {
            case .changed(let old, let new):
                if let index = services.firstIndex(where: { samePeer($0, old) }) {
                    services[index] = new
                } else {
                    services.append(new)
                }
            }
        }
        let partition = partitionDiscoveredServices(
            services,
            host: host,
            selfFingerprint: selfFingerprint,
            localAddresses: localAddresses
        )
        return (partition, false)
    }
}

private func samePeer(_ lhs: DiscoveredService, _ rhs: DiscoveredService) -> Bool {
    if let left = lhs.fields.fingerprint, let right = rhs.fields.fingerprint, !left.isEmpty, left == right {
        return true
    }
    return lhs.instanceName == rhs.instanceName
}
