import Foundation
import LimLinkAppSupport
import Observation

enum MacNotificationResponseHandler {
    static func handle(
        offerID: String?, actionIdentifier: String,
        decide: (String, Bool) -> Void, openWindow: () -> Void
    ) {
        if let offerID {
            switch actionIdentifier {
            case "ACCEPT": decide(offerID, true)
            case "REJECT": decide(offerID, false)
            default: break
            }
        }
        openWindow()
    }
}

struct SentTransferNotificationTracker {
    private var notifiedCompletionIDs: Set<UUID> = []

    mutating func unseenCompletions(_ completions: [RecentSend]) -> [RecentSend] {
        // History is newest first; a single observation may include several batch recipients.
        completions.reversed().filter { notifiedCompletionIDs.insert($0.id).inserted }
    }
}

struct ReceivedTransferCompletion: Identifiable {
    let id = UUID()
    let name: String
}

@MainActor @Observable
final class ReceiveCompletionHistory {
    private(set) var completions: [ReceivedTransferCompletion] = []

    func recordSaved(_ file: SavedFile) {
        completions.insert(ReceivedTransferCompletion(name: file.name), at: 0)
    }
}

/// These observers belong to the app delegate, so closing a window cannot stop them.
@MainActor
final class MacBindingRequestObserver {
    private let requestID: () -> String?
    private let isFrontmost: () -> Bool
    private let present: () -> Void
    private var previousID: String?

    init(requestID: @escaping () -> String?, isFrontmost: @escaping () -> Bool, present: @escaping () -> Void) {
        self.requestID = requestID
        self.isFrontmost = isFrontmost
        self.present = present
        observe()
    }

    private func observe() {
        let currentID = withObservationTracking { requestID() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        defer { previousID = currentID }
        if currentID != nil, currentID != previousID, !isFrontmost() { present() }
    }
}

@MainActor
final class MacReceiveCompletionObserver {
    private let history: ReceiveCompletionHistory
    private let notify: (String) -> Void
    private var notified: Set<UUID> = []

    init(history: ReceiveCompletionHistory, notify: @escaping (String) -> Void) {
        self.history = history
        self.notify = notify
        observe()
    }

    private func observe() {
        let completions = withObservationTracking { history.completions } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        for completion in completions.reversed() where notified.insert(completion.id).inserted {
            notify(completion.name)
        }
    }
}
