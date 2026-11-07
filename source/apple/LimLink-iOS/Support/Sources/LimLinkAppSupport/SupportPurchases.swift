import Foundation
import Observation
import StoreKit

public enum SupportPurchaseOutcome: Equatable, Sendable {
    case idle, purchasing, pending, cancelled, failed, unverified, unknown, completed
}

/// Attempt-scoped presentation state. StoreKit appAccountToken correlates later approval updates
/// with this random purchase attempt; it is not a LimLink account or a stored user identifier.
public struct SupportPurchaseState: Equatable, Sendable {
    public private(set) var outcome: SupportPurchaseOutcome = .idle
    private var currentAttempt: UUID?
    private var activePurchase = false
    private var verifiedCurrentAttempt = false
    private var pendingReconciled = false
    public init() {}
    public var canPurchase: Bool { !activePurchase && outcome != .pending }
    public var canRetryPending: Bool { !activePurchase && outcome == .pending && pendingReconciled }

    @discardableResult
    public mutating func begin(_ attempt: UUID) -> Bool {
        guard canPurchase else { return false }
        activePurchase = true
        verifiedCurrentAttempt = false
        currentAttempt = attempt
        pendingReconciled = false
        outcome = .purchasing
        return true
    }

    public mutating func resolve(_ attempt: UUID, as result: SupportPurchaseOutcome) {
        guard activePurchase, currentAttempt == attempt else { return }
        activePurchase = false
        outcome = result == .pending && verifiedCurrentAttempt ? .completed : result
    }

    public mutating func verifiedUpdate(for attempt: UUID?) {
        guard let attempt, currentAttempt == attempt else { return }
        verifiedCurrentAttempt = true
        if !activePurchase && outcome == .pending { outcome = .completed }
    }

    public mutating func didReconcilePending() {
        if outcome == .pending { pendingReconciled = true }
    }

    /// Explicit user decision only; never starts a StoreKit purchase automatically.
    public mutating func allowAnotherSupport() {
        guard canRetryPending else { return }
        currentAttempt = nil
        pendingReconciled = false
        outcome = .idle
    }
}

public enum SupportPurchasePolicy {
    public static let productIDs = ["com.limlink.tip.small", "com.limlink.tip.medium", "com.limlink.tip.large"]

    public static func shouldFinish(productID: String, verified: Bool, consumable: Bool, revoked: Bool) -> Bool {
        verified && consumable && !revoked && productIDs.contains(productID)
    }
}

/// App-lifetime observer; product fetching happens only when the support screen opens.
@MainActor @Observable
public final class SupportPurchases {
    public static let shared = SupportPurchases()
    public private(set) var products: [Product] = []
    public private(set) var loading = false
    public private(set) var loadFailed = false
    public private(set) var state = SupportPurchaseState()
    public var outcome: SupportPurchaseOutcome { state.outcome }
    public var canPurchase: Bool { state.canPurchase }
    public var canRetryPending: Bool { state.canRetryPending }
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var handled = Set<UInt64>()
    @ObservationIgnored private var finishing: [UInt64: Task<Void, Never>] = [:]

    private init() {}

    public func start() {
        guard updates == nil else { return }
        updates = Task {
            for await result in Transaction.updates {
                await self.receive(result)
            }
        }
        recoverUnfinished()
    }

    @discardableResult
    private func recoverUnfinished() -> Task<Void, Never> {
        if let recovery { return recovery }
        let task = Task {
            for await result in Transaction.unfinished {
                await self.receive(result)
            }
            self.recovery = nil
        }
        recovery = task
        return task
    }

    public func allowAnotherSupport() { state.allowAnotherSupport() }

    public func loadProducts() async {
        start()
        await recoverUnfinished().value
        state.didReconcilePending()
        guard !loading else { return }
        loading = true
        loadFailed = false
        defer { loading = false }
        do {
            let available = try await Product.products(for: SupportPurchasePolicy.productIDs)
            products = SupportPurchasePolicy.productIDs.compactMap { id in
                available.first { $0.id == id && $0.type == .consumable }
            }
            loadFailed = products.count != SupportPurchasePolicy.productIDs.count
        } catch {
            products = []
            loadFailed = true
        }
    }

    public func purchase(_ product: Product) async {
        guard products.contains(where: { $0.id == product.id }), product.type == .consumable else { return }
        let attempt = UUID()
        guard state.begin(attempt) else { return }
        do {
            switch try await product.purchase(options: [.appAccountToken(attempt)]) {
            case .success(let result):
                let completed = await receive(result)
                if case .verified(let transaction) = result, transaction.appAccountToken != attempt {
                    state.resolve(attempt, as: .unknown)
                } else {
                    state.resolve(attempt, as: completed ? .completed : .unverified)
                }
            case .pending: state.resolve(attempt, as: .pending)
            case .userCancelled: state.resolve(attempt, as: .cancelled)
            @unknown default: state.resolve(attempt, as: .unknown)
            }
        } catch {
            state.resolve(attempt, as: .failed)
        }
    }

    @discardableResult
    private func receive(_ result: VerificationResult<Transaction>) async -> Bool {
        switch result {
        case .unverified:
            return false
        case .verified(let transaction):
            guard SupportPurchasePolicy.shouldFinish(productID: transaction.productID, verified: true,
                                                     consumable: transaction.productType == .consumable,
                                                     revoked: transaction.revocationDate != nil) else { return false }
            // Background deliveries finish safely but never release the foreground purchase guard.
            if !handled.contains(transaction.id) {
                let finish: Task<Void, Never>
                if let existing = finishing[transaction.id] {
                    finish = existing
                } else {
                    finish = Task { await transaction.finish() }
                    finishing[transaction.id] = finish
                }
                await finish.value
                handled.insert(transaction.id)
                finishing[transaction.id] = nil
            }
            state.verifiedUpdate(for: transaction.appAccountToken)
            return true
        }
    }
}
