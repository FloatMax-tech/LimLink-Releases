import Foundation
import LimLinkAppSupport

enum StartupState: Equatable {
    case stopped
    case starting
    case ready(port: UInt16)
    case failed(LocalizedMessage)
}

enum TransferProgressState: Equatable {
    case connecting
    case waitingForReceiver
    case sending
    case finishing
    case paused
    case completed
    case cancelled
    case failed(LocalizedMessage)

    /// Position on the four-step bar: connect → receiver approves → transfer → verify and save.
    var step: Int? {
        switch self {
        case .connecting: 0
        case .waitingForReceiver: 1
        case .sending, .paused: 2
        case .finishing: 3
        case .completed: 4
        case .cancelled, .failed: nil
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .cancelled, .failed: true
        default: false
        }
    }
}

struct TransferProgress {
    let fileName: String
    var bytesSent: Int
    let bytesTotal: Int
    var state: TransferProgressState {
        didSet { if let step = state.step { reachedStep = max(reachedStep, step) } }
    }
    var peerID: String? = nil
    var peerName: String? = nil
    /// Furthest step reached, so a failure can still show where it stopped.
    var reachedStep = 0
    var bytesPerSecond: Double? = nil
    /// Position in a multi-device send; 1 of 1 for a single recipient.
    var batchPosition = 1
    var batchCount = 1

    var fraction: Double {
        guard bytesTotal > 0 else { return state == .completed ? 1 : 0 }
        return min(max(Double(bytesSent) / Double(bytesTotal), 0), 1)
    }

    var secondsRemaining: Double? {
        guard let rate = bytesPerSecond, rate > 0, bytesTotal > bytesSent else { return nil }
        return Double(bytesTotal - bytesSent) / rate
    }
}

struct UserMessage: Identifiable {
    let id = UUID()
    let content: LocalizedMessage
    var text: String { content.text }
    init(text: LocalizedMessage) { content = text }
}

struct IncomingOffer: Identifiable {
    let id: String
    let senderName: String
    let fingerprint: String
    let fileName: String
    let size: Int
    var saveLocation: String? = nil
    var receivedAt = Date()
}

/// A completed outgoing transfer shown in 最近.
struct RecentSend: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let peer: String
    let date: Date
}
