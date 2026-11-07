import Foundation

public enum IdleSleepPolicy: Equatable, Sendable {
    /// Block idle sleep for the whole transfer.
    case prevent
    /// Block idle sleep only while the Mac is on AC power. On battery, allow it.
    case preventOnACPowerOnly
    /// Allow idle sleep. App Nap and termination are still blocked.
    case allow
}

public enum PowerSource: Equatable, Sendable {
    case acPower
    case battery
    case unknown
}

public struct IdleSleepPower: Sendable {
    public var current: @Sendable () -> PowerSource

    public init(_ current: @escaping @Sendable () -> PowerSource) {
        self.current = current
    }
}

/// Flags the macOS activity holds. App Nap and both termination switches are always on.
public struct MacIdleSleepOptions: Equatable, Sendable {
    public var allowsIdleSystemSleep: Bool
    public var blocksAppNap: Bool
    public var suddenTerminationDisabled: Bool
    public var automaticTerminationDisabled: Bool

    public static func holding(allowsIdleSystemSleep: Bool) -> MacIdleSleepOptions {
        MacIdleSleepOptions(
            allowsIdleSystemSleep: allowsIdleSystemSleep,
            blocksAppNap: true,
            suddenTerminationDisabled: true,
            automaticTerminationDisabled: true
        )
    }
}

public enum IdleSleepHoldChange: Equatable, Sendable {
    case none
    case acquire(MacIdleSleepOptions)
    case release
    case reacquire(MacIdleSleepOptions)
}

/// Decides the macOS activity for one transfer. `applies` is false on iOS, where the policy is ignored.
public struct IdleSleepActivitySession: Sendable {
    public var policy: IdleSleepPolicy
    public var applies: Bool
    public var power: IdleSleepPower
    public private(set) var isHolding = false
    public private(set) var options: MacIdleSleepOptions?

    public init(policy: IdleSleepPolicy, applies: Bool, power: IdleSleepPower) {
        self.policy = policy
        self.applies = applies
        self.power = power
    }

    public mutating func begin() -> IdleSleepHoldChange {
        guard applies, !isHolding else { return .none }
        isHolding = true
        let next = desired()
        options = next
        return .acquire(next)
    }

    public mutating func end() -> IdleSleepHoldChange {
        guard applies, isHolding else { return .none }
        isHolding = false
        options = nil
        return .release
    }

    public mutating func setPolicy(_ policy: IdleSleepPolicy) -> IdleSleepHoldChange {
        self.policy = policy
        return refresh()
    }

    /// The power-source notification. Re-acquires only when the held options change.
    public mutating func powerDidChange() -> IdleSleepHoldChange {
        refresh()
    }

    private mutating func refresh() -> IdleSleepHoldChange {
        guard applies, isHolding, let current = options else { return .none }
        let next = desired()
        guard next != current else { return .none }
        options = next
        return .reacquire(next)
    }

    private func desired() -> MacIdleSleepOptions {
        MacIdleSleepOptions.holding(allowsIdleSystemSleep: allowsIdleSleep)
    }

    private var allowsIdleSleep: Bool {
        switch policy {
        case .prevent:
            return false
        case .allow:
            return true
        case .preventOnACPowerOnly:
            return power.current() != .acPower
        }
    }
}
