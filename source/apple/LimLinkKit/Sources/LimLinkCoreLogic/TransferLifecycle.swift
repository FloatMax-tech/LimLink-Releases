import Foundation

public enum LifecyclePlatform: Equatable, Sendable {
    case iOS
    case macOS
}

public enum LifecycleEvent: Equatable, Sendable {
    case didEnterBackground
    case willEnterForeground
    case backgroundTimeExpired
    case willSleep
    case didWake
    case transferStarted
    case transferEnded
}

public enum LifecycleTaskAction: Equatable, Sendable {
    case none
    case begin
    case end
}

/// Tracks an iOS background task. `.begin` opens it and leaves it open. Only `.end` closes it.
public struct BackgroundTaskSession: Equatable, Sendable {
    public private(set) var isOpen: Bool

    public init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    public mutating func apply(_ action: LifecycleTaskAction) {
        switch action {
        case .begin:
            isOpen = true
        case .end:
            isOpen = false
        case .none:
            break
        }
    }
}

/// What the Kit should do for one lifecycle event. Linux tests build this without UIKit or AppKit.
public struct LifecycleDirective: Equatable, Sendable {
    public var flushHalfFile: Bool
    public var pauseReason: String?
    /// Copied into the pause body and then into `holds`. Absent for `app_background`.
    public var detail: [String: String]?
    public var resumeLocalHold: Bool
    /// Wake resumes retry after the path is up. A background return does not.
    public var afterWake: Bool
    public var backgroundTask: LifecycleTaskAction
    public var activity: LifecycleTaskAction

    public init(
        flushHalfFile: Bool = false,
        pauseReason: String? = nil,
        detail: [String: String]? = nil,
        resumeLocalHold: Bool = false,
        afterWake: Bool = false,
        backgroundTask: LifecycleTaskAction = .none,
        activity: LifecycleTaskAction = .none
    ) {
        self.flushHalfFile = flushHalfFile
        self.pauseReason = pauseReason
        self.detail = detail
        self.resumeLocalHold = resumeLocalHold
        self.afterWake = afterWake
        self.backgroundTask = backgroundTask
        self.activity = activity
    }

    /// A pause the sender should POST. `background_killed` never produces one.
    public var pauseToSend: (reason: String, detail: [String: String]?)? {
        guard let pauseReason else { return nil }
        return (pauseReason, detail)
    }
}

public enum WakeResumePlan: Equatable, Sendable {
    case send
    case waitForPathThenSend
    case fail
}

public enum WakeResume {
    /// A wake resume that dies before any HTTP response waits for a satisfied path and retries.
    /// Any other transport failure fails the send.
    public static func plan(afterWake: Bool, transportFailedBeforeResponse: Bool) -> WakeResumePlan {
        if transportFailedBeforeResponse {
            return afterWake ? .waitForPathThenSend : .fail
        }
        return .send
    }
}

/// Maps background, foreground, sleep, and wake onto flush, pause, and resume.
/// The host does not observe these events. `LifecycleObserver` applies the directive.
public struct TransferLifecycle: Sendable {
    public var platform: LifecyclePlatform
    private var transferActive = false
    private var inBackground = false
    private var sleeping = false
    private var cleanlyPaused = false

    public init(platform: LifecyclePlatform) {
        self.platform = platform
    }

    public mutating func handle(_ event: LifecycleEvent) -> LifecycleDirective {
        switch platform {
        case .iOS:
            return handleIOS(event)
        case .macOS:
            return handleMac(event)
        }
    }

    private mutating func handleIOS(_ event: LifecycleEvent) -> LifecycleDirective {
        switch event {
        case .transferStarted:
            transferActive = true
            guard inBackground else { return LifecycleDirective() }
            cleanlyPaused = true
            return LifecycleDirective(
                flushHalfFile: true,
                pauseReason: "app_background",
                backgroundTask: .begin
            )
        case .transferEnded:
            transferActive = false
            cleanlyPaused = false
            return LifecycleDirective(backgroundTask: .end)
        case .didEnterBackground:
            inBackground = true
            guard transferActive else { return LifecycleDirective() }
            cleanlyPaused = true
            return LifecycleDirective(
                flushHalfFile: true,
                pauseReason: "app_background",
                backgroundTask: .begin
            )
        case .willEnterForeground:
            inBackground = false
            let resume = transferActive && cleanlyPaused
            cleanlyPaused = false
            return LifecycleDirective(resumeLocalHold: resume, backgroundTask: .end)
        case .backgroundTimeExpired:
            // `background_killed` is local. Flush, do not POST pause, and the next launch resumes per 7.2.
            if transferActive, !cleanlyPaused {
                return LifecycleDirective(flushHalfFile: true, backgroundTask: .end)
            }
            return LifecycleDirective(backgroundTask: .end)
        case .willSleep, .didWake:
            return LifecycleDirective()
        }
    }

    private mutating func handleMac(_ event: LifecycleEvent) -> LifecycleDirective {
        switch event {
        case .transferStarted:
            transferActive = true
            guard !sleeping else {
                cleanlyPaused = true
                return LifecycleDirective(
                    flushHalfFile: true,
                    pauseReason: "system",
                    detail: ["systemReason": "sleep"]
                )
            }
            return LifecycleDirective(activity: .begin)
        case .transferEnded:
            transferActive = false
            cleanlyPaused = false
            return LifecycleDirective(activity: .end)
        case .willSleep:
            // TODO(protocol 7.2): a pause may not get out before lid-close sleep. The peer treats that as a disconnect, and wake resumes from committedBytes per 7.2.
            sleeping = true
            guard transferActive else { return LifecycleDirective(activity: .end) }
            cleanlyPaused = true
            return LifecycleDirective(
                flushHalfFile: true,
                pauseReason: "system",
                detail: ["systemReason": "sleep"],
                activity: .end
            )
        case .didWake:
            sleeping = false
            let resume = transferActive && cleanlyPaused
            cleanlyPaused = false
            var directive = LifecycleDirective(resumeLocalHold: resume, afterWake: true)
            if transferActive {
                directive.activity = .begin
            }
            return directive
        case .didEnterBackground, .willEnterForeground, .backgroundTimeExpired:
            return LifecycleDirective()
        }
    }
}
