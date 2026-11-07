import Foundation
import XCTest
@testable import LimLinkAppSupport

final class SupportPurchaseTests: XCTestCase {
    func testOnlyVerifiedActiveMatchingConsumablesCanFinish() {
        for id in SupportPurchasePolicy.productIDs {
            XCTAssertTrue(SupportPurchasePolicy.shouldFinish(productID: id, verified: true, consumable: true, revoked: false))
            XCTAssertFalse(SupportPurchasePolicy.shouldFinish(productID: id, verified: false, consumable: true, revoked: false))
            XCTAssertFalse(SupportPurchasePolicy.shouldFinish(productID: id, verified: true, consumable: false, revoked: false))
            XCTAssertFalse(SupportPurchasePolicy.shouldFinish(productID: id, verified: true, consumable: true, revoked: true))
        }
        XCTAssertFalse(SupportPurchasePolicy.shouldFinish(productID: "other.product", verified: true, consumable: true, revoked: false))
    }

    func testOldVerificationCannotCompleteOrUnlockNewPurchase() {
        var state = SupportPurchaseState()
        let old = UUID()
        XCTAssertTrue(state.begin(old))
        state.resolve(old, as: .completed)
        let current = UUID()
        XCTAssertTrue(state.begin(current))
        state.verifiedUpdate(for: old)
        state.resolve(old, as: .completed)
        XCTAssertEqual(state.outcome, .purchasing)
        XCTAssertFalse(state.canPurchase)
        state.resolve(current, as: .pending)
        state.verifiedUpdate(for: old)
        XCTAssertEqual(state.outcome, .pending)
        XCTAssertFalse(state.canPurchase)
        state.verifiedUpdate(for: current)
        XCTAssertEqual(state.outcome, .completed)
    }

    func testPendingReopenRequiresExplicitRetryAndNeverStartsPayment() {
        var state = SupportPurchaseState()
        let pending = UUID()
        XCTAssertTrue(state.begin(pending))
        state.resolve(pending, as: .pending)
        state.allowAnotherSupport()
        XCTAssertEqual(state.outcome, .pending)
        state.didReconcilePending()
        XCTAssertEqual(state.outcome, .pending)
        XCTAssertFalse(state.canPurchase)
        XCTAssertTrue(state.canRetryPending)
        state.allowAnotherSupport()
        XCTAssertEqual(state.outcome, .idle)
        XCTAssertTrue(state.canPurchase)
        // Approval arriving after an explicit retry decision cannot confirm the next attempt.
        let next = UUID()
        XCTAssertTrue(state.begin(next))
        state.verifiedUpdate(for: pending)
        XCTAssertEqual(state.outcome, .purchasing)
        XCTAssertFalse(state.canPurchase)
    }

    func testMatchingUpdateBeforePendingReturnWaitsForForegroundAttempt() {
        var state = SupportPurchaseState()
        let attempt = UUID()
        XCTAssertTrue(state.begin(attempt))
        state.verifiedUpdate(for: attempt)
        XCTAssertEqual(state.outcome, .purchasing)
        XCTAssertFalse(state.canPurchase)
        state.resolve(attempt, as: .pending)
        XCTAssertEqual(state.outcome, .completed)
        XCTAssertTrue(state.canPurchase)
    }

    func testBackgroundRecoveryDoesNotInventForegroundSuccess() {
        var state = SupportPurchaseState()
        state.verifiedUpdate(for: UUID())
        XCTAssertEqual(state.outcome, .idle)
        let attempt = UUID()
        XCTAssertTrue(state.begin(attempt))
        state.resolve(attempt, as: .cancelled)
        state.verifiedUpdate(for: attempt)
        XCTAssertEqual(state.outcome, .cancelled)
    }

    func testCatalogueContainsExactRepeatableTipIDsInTierOrder() {
        XCTAssertEqual(SupportPurchasePolicy.productIDs, ["com.limlink.tip.small", "com.limlink.tip.medium", "com.limlink.tip.large"])
    }
}
