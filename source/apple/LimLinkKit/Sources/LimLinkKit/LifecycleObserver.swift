import Foundation
import Network
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import IOKit.ps
#endif

enum SenderLifecycleCommand: Equatable, Sendable {
    case pause(reason: String, detail: [String: String]?)
    case resume(afterWake: Bool)
}

/// Kit-owned app lifecycle. The host does not register for background, foreground, sleep, or wake.
final class LifecycleObserver: @unchecked Sendable {
    static let shared = LifecycleObserver()

    private let lock = NSLock()
    // Serialize state reconciliation through callback delivery; callbacks may re-enter the observer.
    private let deliveryLock = NSRecursiveLock()
    private var planner: TransferLifecycle
    private var idleSleep: IdleSleepActivitySession
    private var installed = false
    private var transferIsActive = false
    private var receiverSessions: [UUID: Set<String>] = [:]
    private var receiverRevisions: [UUID: UInt64] = [:]
    private var senderDepth = 0
    private var receivers: [UUID: @Sendable (LifecycleDirective) -> Void] = [:]
    private var commands: [SenderLifecycleCommand] = []
    private var waiters: [CommandWaiter] = []
    private var observerTokens: [NSObjectProtocol] = []
    #if os(iOS)
    private var backgroundTasks = BackgroundTaskSession()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    #if os(macOS)
    private var activityToken: NSObjectProtocol?
    #endif

    private init() {
        #if os(iOS)
        planner = TransferLifecycle(platform: .iOS)
        idleSleep = IdleSleepActivitySession(policy: .prevent, applies: false, power: IdleSleepPower { .unknown })
        #elseif os(macOS)
        planner = TransferLifecycle(platform: .macOS)
        idleSleep = IdleSleepActivitySession(
            policy: .prevent,
            applies: true,
            power: IdleSleepPower { SystemPowerSource.current() }
        )
        #else
        planner = TransferLifecycle(platform: .iOS)
        idleSleep = IdleSleepActivitySession(policy: .prevent, applies: false, power: IdleSleepPower { .unknown })
        #endif
    }

    func install() {
        lock.lock()
        if installed {
            lock.unlock()
            return
        }
        installed = true
        lock.unlock()
        if PartialMaintenanceSchedule.purgesOnLaunch {
            Task.detached(priority: .utility) {
                await PartialFileMaintenance.purgeStale()
            }
        }
        Task { @MainActor in
            self.installNotifications()
        }
    }

    func adopt(_ configuration: LimLinkConfiguration) {
        let policy = configuration.idleSleepPolicy
        Task { @MainActor in
            let change = self.lock.withLock {
                self.idleSleep.setPolicy(policy)
            }
            self.applyHold(change)
        }
    }

    @discardableResult
    func addReceiver(_ body: @escaping @Sendable (LifecycleDirective) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        receivers[id] = body
        receiverSessions[id] = []
        receiverRevisions[id] = 0
        lock.unlock()
        install()
        return id
    }

    func removeReceiver(_ id: UUID) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        lock.lock()
        receivers[id] = nil
        receiverSessions[id] = nil
        receiverRevisions[id] = nil
        let event = reconcileLocked()
        lock.unlock()
        if let event { deliver(event) }
    }

    /// Sessions in `accepted` or `paused`. The observer pauses only while this set or a sender is active.
    func setReceiverSessions(_ ids: Set<String>, receiverID: UUID, revision: UInt64? = nil) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        lock.lock()
        // Ignore callbacks from a service that has already been removed.
        guard receivers[receiverID] != nil else {
            lock.unlock()
            return
        }
        if let revision {
            guard revision > (receiverRevisions[receiverID] ?? 0) else {
                lock.unlock()
                return
            }
            receiverRevisions[receiverID] = revision
        }
        receiverSessions[receiverID] = ids
        let event = reconcileLocked()
        lock.unlock()
        if let event {
            deliver(event)
        }
    }

    func beginSenderInterest() {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        lock.lock()
        senderDepth += 1
        let event = reconcileLocked()
        lock.unlock()
        if let event {
            deliver(event)
        }
    }

    func endSenderInterest() {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        lock.lock()
        senderDepth = max(0, senderDepth - 1)
        let event = reconcileLocked()
        lock.unlock()
        if let event {
            deliver(event)
        }
    }

    func tryConsume() -> SenderLifecycleCommand? {
        lock.lock()
        defer { lock.unlock() }
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }

    func requeueFront(_ command: SenderLifecycleCommand) {
        lock.lock()
        let continuation: CheckedContinuation<SenderLifecycleCommand, Error>?
        if let waiter = waiters.first {
            continuation = waiter.takeContinuation()
            waiters.removeFirst()
        } else {
            continuation = nil
            commands.insert(command, at: 0)
        }
        lock.unlock()
        continuation?.resume(returning: command)
    }

    func waitForCommand() async throws -> SenderLifecycleCommand {
        let waiter = CommandWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SenderLifecycleCommand, Error>) in
                self.lock.lock()
                guard waiter.arm(continuation) else {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !self.commands.isEmpty {
                    let command = self.commands.removeFirst()
                    let recipient = waiter.takeContinuation()
                    self.lock.unlock()
                    recipient?.resume(returning: command)
                    return
                }
                self.waiters.append(waiter)
                self.lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            self.waiters.removeAll { $0 === waiter }
            let continuation = waiter.cancel()
            self.lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func reconcileLocked() -> LifecycleEvent? {
        let should = receiverSessions.values.contains { !$0.isEmpty } || senderDepth > 0
        if should == transferIsActive { return nil }
        transferIsActive = should
        return should ? .transferStarted : .transferEnded
    }

    private func deliver(_ event: LifecycleEvent) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        if PartialMaintenanceSchedule.purges(on: event) {
            Task.detached(priority: .utility) {
                await PartialFileMaintenance.purgeStale()
            }
        }
        lock.lock()
        let directive = planner.handle(event)
        let resumed = enqueueLocked(directive)
        let callbacks = Array(receivers.values)
        lock.unlock()
        // Submit effects before callbacks, which can recursively plan a newer event.
        DispatchQueue.main.async {
            self.applyBackground(directive.backgroundTask)
            self.applyActivity(directive.activity)
        }
        for (continuation, command) in resumed {
            continuation.resume(returning: command)
        }
        for callback in callbacks {
            callback(directive)
        }
    }

    private func enqueueLocked(_ directive: LifecycleDirective) -> [(CheckedContinuation<SenderLifecycleCommand, Error>, SenderLifecycleCommand)] {
        if let pause = directive.pauseToSend {
            return pushLocked(.pause(reason: pause.reason, detail: pause.detail))
        }
        if directive.resumeLocalHold {
            return pushLocked(.resume(afterWake: directive.afterWake))
        }
        return []
    }

    private func pushLocked(_ command: SenderLifecycleCommand) -> [(CheckedContinuation<SenderLifecycleCommand, Error>, SenderLifecycleCommand)] {
        if let waiter = waiters.first {
            waiters.removeFirst()
            if let continuation = waiter.takeContinuation() {
                return [(continuation, command)]
            }
        }
        commands.append(command)
        return []
    }

    @MainActor
    private func installNotifications() {
        #if os(iOS)
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deliver(.didEnterBackground)
        })
        observerTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deliver(.willEnterForeground)
        })
        #elseif os(macOS)
        let workspace = NSWorkspace.shared.notificationCenter
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deliver(.willSleep)
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deliver(.didWake)
        })
        SystemPowerSource.startObserving { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let change = self.lock.withLock {
                    self.idleSleep.powerDidChange()
                }
                self.applyHold(change)
            }
        }
        #endif
    }

    @MainActor
    private func applyBackground(_ action: LifecycleTaskAction) {
        #if os(iOS)
        let wasOpen = backgroundTasks.isOpen
        backgroundTasks.apply(action)
        if backgroundTasks.isOpen, !wasOpen {
            beginBackgroundTask()
        } else if wasOpen, !backgroundTasks.isOpen {
            endBackgroundTask()
        }
        #else
        _ = action
        #endif
    }

    @MainActor
    private func applyActivity(_ action: LifecycleTaskAction) {
        #if os(macOS)
        let change: IdleSleepHoldChange
        lock.lock()
        switch action {
        case .begin:
            change = idleSleep.begin()
        case .end:
            change = idleSleep.end()
        case .none:
            change = .none
        }
        lock.unlock()
        applyHold(change)
        #else
        _ = action
        #endif
    }

    @MainActor
    private func applyHold(_ change: IdleSleepHoldChange) {
        #if os(macOS)
        switch change {
        case .none:
            break
        case .acquire(let options), .reacquire(let options):
            endActivity()
            beginActivity(options)
        case .release:
            endActivity()
        }
        #else
        _ = change
        #endif
    }

    #if os(iOS)
    @MainActor
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LimLink") { [weak self] in
            self?.deliver(.backgroundTimeExpired)
        }
    }

    @MainActor
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
    #endif

    #if os(macOS)
    @MainActor
    private func beginActivity(_ options: MacIdleSleepOptions) {
        guard activityToken == nil else { return }
        var flags: ProcessInfo.ActivityOptions = []
        if options.allowsIdleSystemSleep {
            flags.insert(.userInitiatedAllowingIdleSystemSleep)
        } else {
            flags.insert(.userInitiated)
        }
        if options.suddenTerminationDisabled {
            flags.insert(.suddenTerminationDisabled)
        }
        if options.automaticTerminationDisabled {
            flags.insert(.automaticTerminationDisabled)
        }
        activityToken = ProcessInfo.processInfo.beginActivity(options: flags, reason: "LimLink transfer")
    }

    @MainActor
    private func endActivity() {
        guard let activityToken else { return }
        ProcessInfo.processInfo.endActivity(activityToken)
        self.activityToken = nil
    }
    #endif
}

#if os(macOS)
private final class PowerNotifyBox: @unchecked Sendable {
    let fire: @Sendable () -> Void
    init(_ fire: @escaping @Sendable () -> Void) { self.fire = fire }
}

enum SystemPowerSource {
    @MainActor
    private static var box: PowerNotifyBox?

    static func current() -> PowerSource {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .acPower }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else {
            return .acPower
        }
        var sawBattery = false
        for item in list {
            guard let raw = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any] else { continue }
            let state = raw[kIOPSPowerSourceStateKey as String] as? String
            if state == kIOPSACPowerValue as String { return .acPower }
            if state == kIOPSBatteryPowerValue as String { sawBattery = true }
        }
        return sawBattery ? .battery : .unknown
    }

    @MainActor
    static func startObserving(_ body: @escaping @Sendable () -> Void) {
        let held = PowerNotifyBox(body)
        box = held
        let context = Unmanaged.passUnretained(held).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerNotifyBox>.fromOpaque(context).takeUnretainedValue().fire()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}
#endif

protocol PathSatisfactionMonitoring: Sendable {
    func start(onSatisfied: @escaping @Sendable () -> Void)
    func cancel()
}

extension NWPathMonitor: PathSatisfactionMonitoring {
    func start(onSatisfied: @escaping @Sendable () -> Void) {
        pathUpdateHandler = { path in
            if path.status == .satisfied { onSatisfied() }
        }
        start(queue: DispatchQueue(label: "limlink.wake-path"))
    }
}

enum PathSatisfaction {
    static func waitUntilSatisfied(monitor: any PathSatisfactionMonitoring = NWPathMonitor()) async throws {
        let waiter = PathWaiter(monitor: monitor)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation)
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
    }
}

private final class PathWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let monitor: any PathSatisfactionMonitoring
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    init(monitor: any PathSatisfactionMonitoring) { self.monitor = monitor }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        // Cancellation can finish the wait before its operation registers.
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        // Register/start while locked so cancellation cannot stop the monitor
        // and then race with a later start. Network delivers updates asynchronously.
        monitor.start { [weak self] in self?.finish(.success(())) }
        lock.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        // A queued path update may still arrive after cancellation; the result
        // above makes it harmless, and the callback does not retain this waiter.
        monitor.cancel()
        continuation?.resume(with: result)
    }
}

private final class CommandWaiter: @unchecked Sendable {
    // Every access is protected by LifecycleObserver.lock, including arming,
    // enqueueing, cancellation, and claiming a command for delivery.
    private var cancelled = false
    private var continuation: CheckedContinuation<SenderLifecycleCommand, Error>?

    func arm(_ continuation: CheckedContinuation<SenderLifecycleCommand, Error>) -> Bool {
        guard !cancelled else { return false }
        self.continuation = continuation
        return true
    }

    func takeContinuation() -> CheckedContinuation<SenderLifecycleCommand, Error>? {
        let continuation = continuation
        self.continuation = nil
        return continuation
    }

    func cancel() -> CheckedContinuation<SenderLifecycleCommand, Error>? {
        cancelled = true
        return takeContinuation()
    }
}

/// Sends one file and applies Kit lifecycle between requests. The host does not watch background or sleep.
public enum SingleFileExchange {
    /// `approvalTimeout` bounds the initial session approval polls, independently
    /// of transport idleness. It does not limit the accepted file transfer.
    /// `completionTimeout` bounds final verification and disk publication, which
    /// can outlast an ordinary request when saving a large file to a slow volume.
    public static func run(
        connection: LimLinkConnection,
        client initial: SingleFileClient,
        responseLimits: HTTPResponseLimits = .unlimited,
        idleTimeout: Duration? = nil,
        approvalTimeout: Duration = .seconds(120),
        completionTimeout: Duration = .seconds(1800),
        onTick: @escaping @Sendable (SingleFileClientTick) -> Void = { _ in }
    ) async throws -> SingleFileClientTick {
        try await run(
            client: initial,
            idleTimeout: idleTimeout,
            approvalTimeout: approvalTimeout,
            completionTimeout: completionTimeout,
            exchange: { request, afterWake, timeout in
                try await transact(connection, request, afterWake: afterWake, responseLimits: responseLimits, idleTimeout: timeout)
            },
            onTick: onTick
        )
    }

    static func run(
        client initial: SingleFileClient,
        idleTimeout: Duration? = nil,
        approvalTimeout: Duration = .seconds(120),
        completionTimeout: Duration = .seconds(1800),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        exchange: @escaping @Sendable (HTTPRequest, Bool, Duration?) async throws -> HTTPResponse,
        onTick: @escaping @Sendable (SingleFileClientTick) -> Void = { _ in }
    ) async throws -> SingleFileClientTick {
        let hub = LifecycleObserver.shared
        hub.install()
        hub.beginSenderInterest()
        defer { hub.endSenderInterest() }
        var client = initial
        var tick = client.start()
        var approvalDeadline: ContinuousClock.Instant?
        onTick(tick)
        while true {
            if let command = hub.tryConsume() {
                if accepts(command, client: client) {
                    let afterWake = resumeFollowsWake(command)
                    tick = apply(command, client: &client)
                    onTick(tick)
                    if let request = tick.request {
                        let response = try await exchange(request, afterWake, idleTimeout)
                        tick = client.receive(response)
                        onTick(tick)
                    }
                    continue
                }
                if case .resume = command, !client.placedLocalHold {
                    // The receiver drops its own hold. This sender has nothing to remove.
                } else {
                    hub.requeueFront(command)
                }
            }
            if let request = tick.request {
                let response: HTTPResponse
                if client.isAwaitingApproval {
                    let deadline = approvalDeadline ?? now().advanced(by: approvalTimeout)
                    approvalDeadline = deadline
                    let remaining = now().duration(to: deadline)
                    guard remaining > .zero else { throw TransportFailure.timedOut }
                    let timeout = min(idleTimeout ?? remaining, remaining)
                    // An idle timer resets whenever bytes arrive. Bound the whole
                    // poll as well, so a trickling response cannot extend approval.
                    response = try await withTimeout(remaining) {
                        try await exchange(request, false, timeout)
                    }
                    guard now() < deadline else { throw TransportFailure.timedOut }
                } else if request.method == "POST", request.target.hasSuffix("/complete") {
                    approvalDeadline = nil
                    response = try await withTimeout(completionTimeout) {
                        try await exchange(request, false, completionTimeout)
                    }
                } else {
                    approvalDeadline = nil
                    response = try await exchange(request, false, idleTimeout)
                }
                tick = client.receive(response)
                onTick(tick)
                // The current receiver responds to pending polls immediately. Avoid
                // hammering the network and host approval queue while a person decides.
                if request.method == "GET", request.target.contains("?wait="), response.status == 202 {
                    var delay = Duration.milliseconds(250)
                    if let approvalDeadline {
                        let remaining = now().duration(to: approvalDeadline)
                        guard remaining > .zero else { throw TransportFailure.timedOut }
                        delay = min(delay, remaining)
                    }
                    try await Task.sleep(for: delay)
                }
                continue
            }
            switch tick.status {
            case .paused(let committedBytes):
                if client.placedLocalHold {
                    let command = try await hub.waitForCommand()
                    hub.requeueFront(command)
                    continue
                }
                _ = committedBytes
                // TODO(protocol §6.2): an in-flight PUT body is not aborted mid-frame. The next loop posts pause, and a paused PUT is rejected.
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellation()
                tick = client.continueAfterPeer()
                onTick(tick)
                continue
            case .inProgress, .completed, .failed:
                return tick
            }
        }
    }

    private static func resumeFollowsWake(_ command: SenderLifecycleCommand) -> Bool {
        if case .resume(let afterWake) = command { return afterWake }
        return false
    }

    private static func transact(
        _ connection: LimLinkConnection,
        _ request: HTTPRequest,
        afterWake: Bool,
        responseLimits: HTTPResponseLimits,
        idleTimeout: Duration?
    ) async throws -> HTTPResponse {
        do {
            return try await FramedExchange.transact(connection, request, responseLimits: responseLimits, idleTimeout: idleTimeout)
        } catch {
            let down = isNetworkDown(error)
            switch WakeResume.plan(afterWake: afterWake, transportFailedBeforeResponse: down) {
            case .waitForPathThenSend:
                try await PathSatisfaction.waitUntilSatisfied()
                return try await FramedExchange.transact(connection, request, responseLimits: responseLimits, idleTimeout: idleTimeout)
            case .fail, .send:
                throw error
            }
        }
    }

    private static func isNetworkDown(_ error: Error) -> Bool {
        guard let failure = error as? TransportFailure else { return false }
        switch failure {
        case .posix, .dns, .timedOut, .notReady, .cancelled:
            return true
        default:
            return false
        }
    }

    private static func accepts(_ command: SenderLifecycleCommand, client: SingleFileClient) -> Bool {
        switch command {
        case .pause:
            return client.canPlacePause
        case .resume:
            return client.canPlaceResume
        }
    }

    private static func apply(_ command: SenderLifecycleCommand, client: inout SingleFileClient) -> SingleFileClientTick {
        switch command {
        case .pause(let reason, let detail):
            return client.pause(reason: reason, detail: detail)
        case .resume:
            return client.resume()
        }
    }
}
