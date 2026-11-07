import XCTest
import LimLinkCoreLogic
@testable import LimLinkAppSupport

@MainActor
final class ManualVerificationTests: XCTestCase {
    private let firstPin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let secondPin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE"

    func testRejectionNeverMakesPeerTrusted() async throws {
        let queue = ManualVerificationQueue()
        let attempt = Task { await queue.verify(fingerprint: firstPin, name: "手机", address: "192.168.1.2") }
        await waitForPrompt(queue)
        let prompt = try XCTUnwrap(queue.current)
        XCTAssertEqual(prompt.fingerprint, firstPin)
        XCTAssertFalse(queue.contains(firstPin))
        queue.reject(id: prompt.id)
        let accepted = await attempt.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(queue.contains(firstPin))
        XCTAssertNil(queue.current)
    }

    func testExplicitConfirmationTrustsOnlyTheActualFullFingerprint() async throws {
        let queue = ManualVerificationQueue()
        let attempt = Task { await queue.verify(fingerprint: firstPin, name: "手机", address: "192.168.1.2") }
        await waitForPrompt(queue)
        queue.confirm(id: try XCTUnwrap(queue.current).id)
        let accepted = await attempt.value
        XCTAssertTrue(accepted)
        XCTAssertTrue(queue.contains(firstPin))
        XCTAssertFalse(queue.contains(secondPin))
        let known = await queue.verify(fingerprint: firstPin, name: "改了名字", address: "192.168.1.3")
        XCTAssertTrue(known)
        XCTAssertNil(queue.current)
    }

    func testMalformedOrAbbreviatedFingerprintsAreNeverTrusted() async {
        let queue = ManualVerificationQueue()
        for pin in ["", "AAAA-AAAA-AAAA-AAAA", firstPin + "=", "not-a-fingerprint"] {
            let result = await queue.verify(fingerprint: pin, name: "手机", address: "")
            XCTAssertFalse(result)
            XCTAssertFalse(queue.contains(pin))
        }
        XCTAssertNil(queue.current)
    }

    func testSecondPromptDoesNotOverwriteFirstAndStaleApprovalIsIgnored() async throws {
        let queue = ManualVerificationQueue()
        let first = Task { await queue.verify(fingerprint: firstPin, name: "甲", address: "") }
        await waitForPrompt(queue)
        let firstID = try XCTUnwrap(queue.current).id
        let second = Task { await queue.verify(fingerprint: secondPin, name: "乙", address: "") }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(queue.current?.id, firstID)
        queue.reject(id: firstID)
        let rejected = await first.value
        XCTAssertFalse(rejected)
        XCTAssertEqual(queue.current?.fingerprint, secondPin)
        queue.confirm(id: firstID)
        XCTAssertFalse(queue.contains(secondPin))
        queue.confirm(id: try XCTUnwrap(queue.current).id)
        let accepted = await second.value
        XCTAssertTrue(accepted)
    }

    func testCancellationBeforeRegistrationCannotLeaveAPromptOrTrust() async {
        let queue = ManualVerificationQueue()
        let attempt = Task { await queue.verify(fingerprint: firstPin, name: "甲", address: "") }
        attempt.cancel()
        let accepted = await attempt.value
        XCTAssertFalse(accepted)
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.contains(firstPin))
    }

    func testCancellationWhileWaitingResolvesWithoutApproval() async {
        let queue = ManualVerificationQueue()
        let attempt = Task { await queue.verify(fingerprint: firstPin, name: "甲", address: "") }
        await waitForPrompt(queue)
        attempt.cancel()
        let accepted = await attempt.value
        XCTAssertFalse(accepted)
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.contains(firstPin))
    }

    func testStaleConfirmImmediatelyAfterCancellationCannotGrantTrust() async throws {
        let queue = ManualVerificationQueue()
        let attempt = Task { await queue.verify(fingerprint: firstPin, name: "甲", address: "") }
        await waitForPrompt(queue)
        let promptID = try XCTUnwrap(queue.current).id
        attempt.cancel()
        // The cancellation handler's MainActor task has not run yet. A queued button
        // action must not confirm an already cancelled verification.
        queue.confirm(id: promptID)
        let accepted = await attempt.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(queue.contains(firstPin))
        XCTAssertNil(queue.current)
    }

    func testTimeoutDeclinesAndClearsPendingPrompt() async {
        let queue = ManualVerificationQueue(decisionTimeout: .milliseconds(15))
        let accepted = await queue.verify(fingerprint: firstPin, name: "甲", address: "")
        XCTAssertFalse(accepted)
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.contains(firstPin))
    }

    func testQueueCapacityRejectsExtraConnectionWithoutReplacingCurrentPrompt() async throws {
        let queue = ManualVerificationQueue(maximumPending: 1)
        let first = Task { await queue.verify(fingerprint: firstPin, name: "甲", address: "") }
        await waitForPrompt(queue)
        let currentID = try XCTUnwrap(queue.current).id
        let extra = await queue.verify(fingerprint: secondPin, name: "乙", address: "")
        XCTAssertFalse(extra)
        XCTAssertEqual(queue.current?.id, currentID)
        XCTAssertFalse(queue.contains(secondPin))
        queue.reject(id: currentID)
        let firstAccepted = await first.value
        XCTAssertFalse(firstAccepted)
    }

    func testClearCancelsPendingAndRemovesRunScopedTrust() async throws {
        let queue = ManualVerificationQueue()
        let first = Task { await queue.verify(fingerprint: firstPin, name: "甲", address: "") }
        await waitForPrompt(queue)
        queue.confirm(id: try XCTUnwrap(queue.current).id)
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
        let second = Task { await queue.verify(fingerprint: secondPin, name: "乙", address: "") }
        await waitForPrompt(queue)
        queue.clear()
        let secondAccepted = await second.value
        XCTAssertFalse(secondAccepted)
        XCTAssertFalse(queue.contains(firstPin))
        XCTAssertNil(queue.current)
    }

    private func waitForPrompt(_ queue: ManualVerificationQueue) async {
        for _ in 0..<100 {
            if queue.current != nil { return }
            await Task.yield()
        }
        XCTFail("verification did not present a pending request")
    }
}
