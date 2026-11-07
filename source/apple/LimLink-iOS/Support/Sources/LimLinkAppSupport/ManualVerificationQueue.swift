import Foundation
import Observation
import LimLinkCoreLogic

public struct VerificationRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let address: String
    /// Full, canonical SHA-256 fingerprint obtained from the TLS certificate.
    public let fingerprint: String
}

/// Holds connections before the host starts any file protocol.
/// Trust lasts only for this queue's lifetime and is granted only by confirm.
@MainActor @Observable
public final class ManualVerificationQueue {
    public private(set) var current: VerificationRequest?
    @ObservationIgnored private var confirmed: Set<String> = []
    @ObservationIgnored private var pending: [Entry] = []
    @ObservationIgnored private let decisionTimeout: Duration
    @ObservationIgnored private let maximumPending: Int

    private struct Entry {
        let request: VerificationRequest
        let continuation: CheckedContinuation<Bool, Never>
        let timer: Task<Void, Never>
        let cancellation: CancellationFlag
    }

    /// Task cancellation can arrive from any executor before its MainActor cleanup runs.
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isCancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }

    public init(decisionTimeout: Duration = .seconds(120), maximumPending: Int = 4) {
        self.decisionTimeout = decisionTimeout
        self.maximumPending = max(1, maximumPending)
    }

    public func contains(_ fingerprint: String) -> Bool {
        confirmed.contains(fingerprint)
    }

    public func verify(fingerprint: String, name: String, address: String) async -> Bool {
        guard let parsed = Fingerprint(base64URL: fingerprint),
              parsed.base64URL == fingerprint,
              !Task.isCancelled else { return false }
        if confirmed.contains(fingerprint) { return true }
        guard pending.count < maximumPending else { return false }
        let request = VerificationRequest(id: UUID(), name: name, address: address, fingerprint: fingerprint)
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can precede registration; do not lose that cancellation.
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let timeout = decisionTimeout
                let timer = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        self?.reject(id: request.id)
                    } catch { }
                }
                pending.append(Entry(request: request, continuation: continuation, timer: timer, cancellation: cancellation))
                current = pending.first?.request
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.reject(id: request.id)
            }
        }
    }

    public func confirm(id: UUID) {
        guard let entry = pending.first(where: { $0.request.id == id }) else { return }
        guard !entry.cancellation.isCancelled else {
            resolve(id: id, accepted: false)
            return
        }
        confirmed.insert(entry.request.fingerprint)
        resolve(id: id, accepted: true)
    }

    public func reject(id: UUID) {
        resolve(id: id, accepted: false)
    }

    public func clear() {
        let entries = pending
        pending.removeAll()
        current = nil
        confirmed.removeAll()
        for entry in entries {
            entry.timer.cancel()
            entry.continuation.resume(returning: false)
        }
    }

    private func resolve(id: UUID, accepted: Bool) {
        guard let index = pending.firstIndex(where: { $0.request.id == id }) else { return }
        let entry = pending.remove(at: index)
        entry.timer.cancel()
        current = pending.first?.request
        entry.continuation.resume(returning: accepted)
    }
}
