import AppKit
import Foundation
import LimLinkAppSupport
import StoreKit
import StoreKitTest
import XCTest

/// Cloud-only, app-hosted integration test. Keep this out of the unhosted logic-test target.
/// SupportTips.storekit is a test-bundle resource; StoreKit calls run inside the LimLink host app.
@MainActor
final class SupportStoreKitTests: XCTestCase {
    // Exists only in SupportTips.storekit. Never register this ID in App Store Connect.
    private let localCatalogueProbeID = "com.limlink.testing.local-catalogue-probe"

    func testConsumableCanBePurchasedRepeatedlyAndFinished() async throws {
        // Cloud enables XCTest timeouts; bound a blocked StoreKit IPC/async request too.
        executionTimeAllowance = 120
        checkpoint("BEGIN host and configuration validation")
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "com.limlink.dev",
              ProcessInfo.processInfo.environment["LIMLINK_ISOLATED_STOREKIT_HOST"] == "1" else {
            XCTFail("StoreKit integration requires the isolated LimLink app host (LIMLINK_ISOLATED_STOREKIT_HOST=1); actual process bundle: \(Bundle.main.bundleURL.path), identifier: \(Bundle.main.bundleIdentifier ?? "nil")")
            return
        }
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SupportTips", withExtension: "storekit"))
        checkpoint("END host and configuration validation: \(Bundle.main.bundleIdentifier ?? "nil"), \(configuration.lastPathComponent)")
        checkpoint("BEGIN SKTestSession initialization")
        let session = try SKTestSession(contentsOf: configuration)
        checkpoint("END SKTestSession initialization")
        checkpoint("BEGIN session.resetToDefaultState")
        session.resetToDefaultState()
        checkpoint("END session.resetToDefaultState")
        checkpoint("BEGIN session.disableDialogs")
        session.disableDialogs = true
        checkpoint("END session.disableDialogs")
        checkpoint("BEGIN initial session.clearTransactions")
        session.clearTransactions()
        checkpoint("END initial session.clearTransactions")
        defer {
            checkpoint("BEGIN cleanup session.clearTransactions")
            session.clearTransactions()
            checkpoint("END cleanup session.clearTransactions")
        }
        // Real support IDs also exist in App Store Connect, so their availability cannot
        // establish that this process is using the local, account-free test catalogue.
        // Throw before starting the coordinator or attempting any purchase if isolation
        // cannot be demonstrated. An assertion alone would allow execution to continue.
        checkpoint("BEGIN local-only catalogue isolation probe")
        guard !SupportPurchasePolicy.productIDs.contains(localCatalogueProbeID) else {
            XCTFail("The local catalogue probe must never be a supported purchase SKU")
            return
        }
        let probes = try await Product.products(for: [localCatalogueProbeID])
        _ = try XCTUnwrap(probes.first(where: { $0.id == localCatalogueProbeID }),
                          "Local StoreKit catalogue is inactive; refusing to attempt any supported-SKU purchase or account authorization")
        checkpoint("END local-only catalogue isolation probe")
        checkpoint("BEGIN coordinator startup")
        let support = SupportPurchases.shared
        support.start()
        checkpoint("END coordinator startup")
        checkpoint("BEGIN unfinished recovery and product catalogue load")
        await support.loadProducts()
        checkpoint("END unfinished recovery and product catalogue load: \(support.products.map(\.id)), loadFailed=\(support.loadFailed)")
        XCTAssertFalse(support.loadFailed, "StoreKit catalogue unavailable in host \(Bundle.main.bundleIdentifier ?? "nil"); config: \(configuration.path)")
        XCTAssertEqual(support.products.map(\.id), SupportPurchasePolicy.productIDs)
        let product = try XCTUnwrap(support.products.first)
        XCTAssertEqual(product.type, .consumable)
        XCTAssertFalse(product.displayPrice.isEmpty)
        checkpoint("BEGIN local transaction ledger baseline")
        var purchasedTransactionIDs = Set(session.allTransactions().map(\.identifier))
        checkpoint("END local transaction ledger baseline: \(purchasedTransactionIDs.count)")
        guard purchasedTransactionIDs.isEmpty else {
            XCTFail("Local StoreKit ledger must be empty before the first purchase")
            return
        }
        for number in 1...2 {
            checkpointPurchaseState(number: number, phase: "before await", session: session, support: support)
            checkpoint("BEGIN purchase \(number): \(product.id)")
            // Product.purchase and receive/finish are private coordinator boundaries.
            // Observe only public test-session state while that await is pending.
            let clock = ContinuousClock()
            let purchaseStarted = clock.now
            let pendingDiagnostics = Task { @MainActor in
                for elapsed in [5, 20] {
                    do { try await clock.sleep(until: purchaseStarted.advanced(by: .seconds(elapsed))) } catch { return }
                    guard !Task.isCancelled else { return }
                    self.checkpointPurchaseState(number: number, phase: "pending \(elapsed)s", session: session, support: support)
                }
            }
            defer { pendingDiagnostics.cancel() }
            await support.purchase(product)
            pendingDiagnostics.cancel()
            checkpoint("END purchase \(number): \(support.outcome)")
            guard support.outcome == .completed else {
                XCTFail("Local StoreKit purchase \(number) did not complete: \(support.outcome)")
                return
            }
            checkpoint("BEGIN purchase \(number) local transaction verification")
            // Finished consumables are absent from Transaction.latest by default.
            // The local test ledger remains available without changing the app's plist.
            let transactions = session.allTransactions().filter { $0.productIdentifier == product.id }
            let transactionIDs = Set(transactions.map(\.identifier))
            guard transactions.count == number, transactionIDs.count == number,
                  purchasedTransactionIDs.isSubset(of: transactionIDs) else {
                XCTFail("Expected \(number) distinct purchases in the local StoreKit ledger; refusing another purchase")
                return
            }
            purchasedTransactionIDs = transactionIDs
            checkpoint("END purchase \(number) local transaction verification: \(transactionIDs.sorted())")
        }
        // StoreKit must have no unfinished matching transaction after the coordinator returns.
        checkpoint("BEGIN final Transaction.unfinished enumeration")
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result {
                checkpoint("Final unfinished transaction: \(transaction.productID)")
                XCTAssertEqual(transaction.environment, .xcode,
                               "Any available StoreKit transaction must belong to the local Xcode environment")
                XCTAssertFalse(SupportPurchasePolicy.productIDs.contains(transaction.productID))
            }
        }
        checkpoint("END final Transaction.unfinished enumeration")
    }

    /// Diagnostics contain only application/session state and local transaction counts.
    /// Separate markers identify a blocked diagnostic IPC without exposing receipt data.
    private func checkpointPurchaseState(number: Int, phase: String, session: SKTestSession, support: SupportPurchases) {
        let app = NSApplication.shared
        checkpoint("Purchase \(number) \(phase): appActive=\(app.isActive), appHidden=\(app.isHidden), keyWindow=\(app.keyWindow != nil), mainWindow=\(app.mainWindow != nil), modalWindow=\(app.modalWindow != nil), visibleWindows=\(app.windows.filter(\.isVisible).count), outcome=\(support.outcome)")
        checkpoint("BEGIN purchase \(number) \(phase) dialog-setting read")
        let disabled = session.disableDialogs
        checkpoint("END purchase \(number) \(phase) dialog-setting read: disabled=\(disabled)")
        checkpoint("BEGIN purchase \(number) \(phase) local ledger snapshot")
        let transactions = session.allTransactions()
        let states = Dictionary(grouping: transactions, by: { $0.state.rawValue })
            .map { "\($0.key):\($0.value.count)" }.sorted()
        let supportedCount = transactions.filter { SupportPurchasePolicy.productIDs.contains($0.productIdentifier) }.count
        checkpoint("END purchase \(number) \(phase) local ledger snapshot: total=\(transactions.count), supported=\(supportedCount), states=\(states), issues=\(transactions.filter(\.hasPurchaseIssue).count), pendingApproval=\(transactions.filter(\.pendingAskToBuyConfirmation).count)")
    }

    /// Synchronous named markers survive even if the following StoreKit call never returns.
    private func checkpoint(_ message: String) {
        let line = "[SupportStoreKit] \(Date().timeIntervalSince1970) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        XCTContext.runActivity(named: message) { activity in
            let attachment = XCTAttachment(string: line)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
