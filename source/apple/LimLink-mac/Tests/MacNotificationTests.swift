import Foundation
import LimLinkAppSupport
import Observation
import UserNotifications
import XCTest

final class MacNotificationTests: XCTestCase {
    @MainActor
    func testBindingRequestPresentsWithoutAFrontmostWindow() async throws {
        let state = BindingNotificationState()
        var presented: [String] = []
        let observer = MacBindingRequestObserver(requestID: { state.requestID }, isFrontmost: { false },
            present: { if let id = state.requestID { presented.append(id) } })
        state.requestID = "binding-one"
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presented, ["binding-one"])
        withExtendedLifetime(observer) { }
    }

    @MainActor
    func testBindingObserverRearmsForTheNextRequestWithoutRepeatingTheFirst() async throws {
        let state = BindingNotificationState()
        var presented: [String] = []
        let observer = MacBindingRequestObserver(requestID: { state.requestID }, isFrontmost: { false },
            present: { if let id = state.requestID { presented.append(id) } })
        state.requestID = "binding-one"
        try await Task.sleep(for: .milliseconds(50))
        state.requestID = nil
        try await Task.sleep(for: .milliseconds(50))
        state.requestID = "binding-two"
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presented, ["binding-one", "binding-two"])
        withExtendedLifetime(observer) { }
    }

    @MainActor
    func testForegroundBindingUsesTheExistingWindowWithoutABackgroundPrompt() async throws {
        let state = BindingNotificationState()
        var presented = false
        let observer = MacBindingRequestObserver(requestID: { state.requestID }, isFrontmost: { true }, present: { presented = true })
        state.requestID = "binding-one"
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(presented)
        withExtendedLifetime(observer) { }
    }

    @MainActor
    func testCoalescedReceivesNotifyEverySavedCompletionInOrder() async throws {
        let history = ReceiveCompletionHistory()
        var notifications: [String] = []
        let observer = MacReceiveCompletionObserver(history: history) { notifications.append($0) }
        history.recordSaved(SavedFile(name: "first.txt", url: URL(fileURLWithPath: "/tmp/first.txt"), size: 1))
        history.recordSaved(SavedFile(name: "second.txt", url: URL(fileURLWithPath: "/tmp/second.txt"), size: 1))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(notifications, ["first.txt", "second.txt"])
        withExtendedLifetime(observer) { }
    }

    @MainActor
    func testReceivingSameNameAndURLAgainHasAnIndependentNotification() async throws {
        let history = ReceiveCompletionHistory()
        var notifications: [String] = []
        let observer = MacReceiveCompletionObserver(history: history) { notifications.append($0) }
        let file = SavedFile(name: "report.txt", url: URL(fileURLWithPath: "/tmp/report.txt"), size: 1)
        history.recordSaved(file)
        try await Task.sleep(for: .milliseconds(50))
        // Removing a row/file never records a save. A later save may reuse that exact URL.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(notifications, ["report.txt"])
        history.recordSaved(file)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(notifications, ["report.txt", "report.txt"])
        XCTAssertEqual(Set(history.completions.map(\.id)).count, 2)
        withExtendedLifetime(observer) { }
    }

    func testOpeningOfferNotificationDoesNotDecideConsent() {
        var decisions: [Bool] = []
        var opened = false

        MacNotificationResponseHandler.handle(
            offerID: "offer", actionIdentifier: UNNotificationDefaultActionIdentifier,
            decide: { _, accept in decisions.append(accept) },
            openWindow: { opened = true }
        )

        XCTAssertEqual(decisions, [])
        XCTAssertTrue(opened)
    }

    func testExplicitAcceptDecidesTheOffer() {
        var decidedID: String?
        var accepted: Bool?
        var opened = false

        MacNotificationResponseHandler.handle(
            offerID: "accept-offer", actionIdentifier: "ACCEPT",
            decide: { decidedID = $0; accepted = $1 },
            openWindow: { opened = true }
        )

        XCTAssertEqual(decidedID, "accept-offer")
        XCTAssertEqual(accepted, true)
        XCTAssertTrue(opened)
    }

    func testExplicitRejectDecidesTheOffer() {
        var decidedID: String?
        var accepted: Bool?

        MacNotificationResponseHandler.handle(
            offerID: "reject-offer", actionIdentifier: "REJECT",
            decide: { decidedID = $0; accepted = $1 }, openWindow: {}
        )

        XCTAssertEqual(decidedID, "reject-offer")
        XCTAssertEqual(accepted, false)
    }

    func testDismissAndUnknownActionsDoNotDecideConsent() {
        for action in [UNNotificationDismissActionIdentifier, "UNKNOWN"] {
            var decisions: [Bool] = []
            MacNotificationResponseHandler.handle(
                offerID: "offer", actionIdentifier: action,
                decide: { _, accept in decisions.append(accept) }, openWindow: {}
            )
            XCTAssertEqual(decisions, [], action)
        }
    }

    func testNotificationWithoutOfferOnlyOpensTheWindow() {
        var decisions: [Bool] = []
        var opened = false
        MacNotificationResponseHandler.handle(
            offerID: nil, actionIdentifier: "ACCEPT",
            decide: { _, accept in decisions.append(accept) },
            openWindow: { opened = true }
        )
        XCTAssertEqual(decisions, [])
        XCTAssertTrue(opened)
    }

    func testSameFileSentToSuccessiveRecipientsNotifiesEachCompletion() {
        var tracker = SentTransferNotificationTracker()
        let first = RecentSend(name: "report.pdf", peer: "iPhone", date: Date(timeIntervalSince1970: 1))
        let second = RecentSend(name: "report.pdf", peer: "iPad", date: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(tracker.unseenCompletions([first]).map(\.id), [first.id])
        let next = tracker.unseenCompletions([second, first])
        XCTAssertEqual(next.map(\.id), [second.id])
        XCTAssertEqual(next.map(\.peer), ["iPad"])
    }

    func testSameFileSentAgainToSameRecipientNotifiesAgain() {
        var tracker = SentTransferNotificationTracker()
        let first = RecentSend(name: "report.pdf", peer: "iPhone", date: Date(timeIntervalSince1970: 1))
        let second = RecentSend(name: "report.pdf", peer: "iPhone", date: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(tracker.unseenCompletions([first]).map(\.id), [first.id])
        XCTAssertEqual(tracker.unseenCompletions([second, first]).map(\.id), [second.id])
    }

    func testRepeatedCompletionSnapshotDoesNotNotifyAgain() {
        var tracker = SentTransferNotificationTracker()
        let completed = RecentSend(name: "report.pdf", peer: "iPhone", date: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(tracker.unseenCompletions([completed]).map(\.id), [completed.id])
        XCTAssertEqual(tracker.unseenCompletions([completed]), [])
        XCTAssertEqual(tracker.unseenCompletions([completed]), [])
    }

    func testCoalescedCompletionsNotifyEveryRecipientInCompletionOrder() {
        var tracker = SentTransferNotificationTracker()
        let first = RecentSend(name: "report.pdf", peer: "iPhone", date: Date(timeIntervalSince1970: 1))
        let second = RecentSend(name: "report.pdf", peer: "iPad", date: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(tracker.unseenCompletions([second, first]).map(\.id), [first.id, second.id])
        XCTAssertEqual(tracker.unseenCompletions([second, first]), [])
    }

    func testEmptyCompletionHistoryDoesNotNotify() {
        var tracker = SentTransferNotificationTracker()
        XCTAssertEqual(tracker.unseenCompletions([]), [])
    }
}

@MainActor @Observable
private final class BindingNotificationState {
    var requestID: String?
}
