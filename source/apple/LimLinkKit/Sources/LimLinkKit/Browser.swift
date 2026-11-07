import Foundation
@preconcurrency import Network

/// Opt-in name for the Bonjour browse test. GitHub-hosted macOS runners cannot approve
/// the Local Network privacy prompt, so the workflow does not set this variable.
public enum LimLinkBonjourProbe {
    public static let optInEnvironmentVariable = "LIMLINK_BONJOUR_TEST"
}

/// Browses `_limlink._tcp` and splits results into the normal list and the diagnostics list.
/// Advertising and browsing use Bonjour. Loopback TLS tests do not start a browser.
public final class LimLinkBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let host: HostAppIdentity
    private let selfFingerprint: String?
    private let lock = NSLock()
    /// Unfiltered roster. Peers rejected by the TXT pre-filter stay here so a later `.changed` can bring them back.
    private var services: [DiscoveredService] = []
    private var interfaceAddresses: Set<String> = []
    private var waiters: [PartitionWaiter] = []

    public init(host: HostAppIdentity, selfFingerprint: String?) {
        self.host = host
        self.selfFingerprint = selfFingerprint
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        browser = NWBrowser(
            // Discovery filtering and fingerprint verification require the TXT fields.
            for: .bonjourWithTXTRecord(type: LimLinkProtocol.serviceType, domain: nil),
            using: parameters
        )
    }

    /// NIC addresses used only for the same-device TXT check. Setting this does not open a connection.
    public func setInterfaceAddresses(_ addresses: Set<String>) {
        lock.lock()
        interfaceAddresses = addresses
        lock.unlock()
    }

    public var partition: DiscoveryPartition {
        snapshot().partition
    }

    public func start() {
        let queue = DispatchQueue(label: "limlink.browser")
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.apply(results: results, changes: changes)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.fail(TransportFailure(nw: error))
            }
        }
        browser.start(queue: queue)
    }

    public func stop() {
        browser.cancel()
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(with: .failure(TransportFailure.cancelled))
        }
    }

    /// Returns when `predicate` matches the current partition, the browser fails, or `timeout` elapses.
    public func waitFor(
        timeout: Duration = .seconds(8),
        where predicate: @escaping @Sendable (DiscoveryPartition) -> Bool
    ) async throws -> DiscoveryPartition {
        let current = partition
        if predicate(current) {
            return current
        }
        let holder = WaiterHolder()
        return try await withTimeout(timeout) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let waiter = PartitionWaiter(continuation: continuation, predicate: predicate)
                    holder.waiter = waiter
                    self.enqueue(waiter)
                }
            } onCancel: {
                holder.waiter?.resume(with: .failure(TransportFailure.timedOut))
            }
        }
    }

    /// Passive. `.changed` re-runs the TXT filter for every peer in the roster, including ones
    /// the previous filter had removed from the device list. This method does not connect.
    private func apply(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        var roster = TxtBrowseRoster(services: results.compactMap(discoveredService))
        var events: [TxtBrowseChange] = []
        for change in changes {
            if case .changed(let old, let new, _) = change,
               let previous = discoveredService(old),
               let updated = discoveredService(new) {
                events.append(.changed(old: previous, new: updated))
            }
        }
        lock.lock()
        let addresses = interfaceAddresses
        lock.unlock()
        let outcome = roster.applyChanges(
            events,
            host: host,
            selfFingerprint: selfFingerprint,
            localAddresses: addresses
        )
        lock.lock()
        services = roster.services
        let pending = waiters
        lock.unlock()
        for waiter in pending where waiter.offer(outcome.partition) {
            lock.lock()
            waiters.removeAll { $0 === waiter }
            lock.unlock()
        }
    }

    private func snapshot() -> (partition: DiscoveryPartition, connects: Bool) {
        lock.lock()
        let services = self.services
        let addresses = interfaceAddresses
        lock.unlock()
        var roster = TxtBrowseRoster(services: services)
        return roster.applyChanges([], host: host, selfFingerprint: selfFingerprint, localAddresses: addresses)
    }

    private func fail(_ error: Error) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(with: .failure(error))
        }
    }

    private func enqueue(_ waiter: PartitionWaiter) {
        let snapshot = partition
        if waiter.offer(snapshot) {
            return
        }
        lock.lock()
        waiters.append(waiter)
        lock.unlock()
        // A result may have arrived between the snapshot and the append.
        if waiter.offer(partition) {
            lock.lock()
            waiters.removeAll { $0 === waiter }
            lock.unlock()
        }
    }
}

private func discoveredService(_ result: NWBrowser.Result) -> DiscoveredService? {
    let name: String
    switch result.endpoint {
    case .service(let serviceName, _, _, _):
        name = serviceName
    default:
        return nil
    }
    let record: NWTXTRecord
    if case .bonjour(let txtRecord) = result.metadata {
        record = txtRecord
    } else {
        record = NWTXTRecord()
    }
    return DiscoveredService(instanceName: name, fields: txtFields(record))
}

private func txtFields(_ record: NWTXTRecord) -> TXTFields {
    var entries: [String: String] = [:]
    for key in ["pv", "fp", "dt", "cap", "app", "inv"] {
        if let value = record[key] {
            entries[key] = value
        }
    }
    return TXTFields(entries: entries)
}

private final class PartitionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DiscoveryPartition, Error>?
    private let predicate: @Sendable (DiscoveryPartition) -> Bool

    init(
        continuation: CheckedContinuation<DiscoveryPartition, Error>,
        predicate: @escaping @Sendable (DiscoveryPartition) -> Bool
    ) {
        self.continuation = continuation
        self.predicate = predicate
    }

    func offer(_ partition: DiscoveryPartition) -> Bool {
        guard predicate(partition) else { return false }
        resume(with: .success(partition))
        return true
    }

    func resume(with result: Result<DiscoveryPartition, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class WaiterHolder: @unchecked Sendable {
    var waiter: PartitionWaiter?
}
