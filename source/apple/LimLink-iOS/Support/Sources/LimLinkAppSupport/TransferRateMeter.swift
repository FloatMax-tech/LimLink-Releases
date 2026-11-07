import Foundation

/// Smoothed transfer speed from progress samples at least `interval` apart.
public struct TransferRateMeter: Sendable {
    private var sample: (time: Date, bytes: Int)?
    public private(set) var bytesPerSecond: Double?
    private let interval: TimeInterval
    private let weight: Double

    public init(interval: TimeInterval = 0.5, weight: Double = 0.3) {
        self.interval = interval
        self.weight = weight
    }

    /// Records progress and returns the current smoothed speed, or nil until one is known.
    @discardableResult
    public mutating func record(bytes: Int, at time: Date = Date()) -> Double? {
        guard let previous = sample else {
            sample = (time, bytes)
            return bytesPerSecond
        }
        let elapsed = time.timeIntervalSince(previous.time)
        guard elapsed >= interval else { return bytesPerSecond }
        sample = (time, bytes)
        guard bytes > previous.bytes else { return bytesPerSecond }
        let instant = Double(bytes - previous.bytes) / elapsed
        bytesPerSecond = bytesPerSecond.map { $0 * (1 - weight) + instant * weight } ?? instant
        return bytesPerSecond
    }
}
