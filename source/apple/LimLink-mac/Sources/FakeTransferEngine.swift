import LimLinkAppSupport
import Foundation

/// 不联网的传输模拟。界面用它驱动仪表盘，第 2 步换成 LimLinkKit 的快照。
struct FakeTransferEngine: Equatable {
    var peerName: String
    var direction: TransferDirection
    var totalBytes: Int64
    var totalCount: Int
    var bytesTransferred: Int64
    var phase: BatchProgressPhase
    var totalBytesKnown: Bool
    var verifiedOnComplete: Bool
    private var samples: [Sample]

    struct Sample: Equatable {
        var date: Date
        var bytes: Int64
    }

    init(
        peerName: String = L10n.text("示例设备"),
        direction: TransferDirection = .receiving,
        totalBytes: Int64 = 80_000_000,
        totalCount: Int = 8
    ) {
        self.peerName = peerName
        self.direction = direction
        self.totalBytes = totalBytes
        self.totalCount = totalCount
        self.bytesTransferred = 0
        self.phase = .idle
        self.totalBytesKnown = true
        self.verifiedOnComplete = true
        self.samples = []
    }

    mutating func start(now: Date) {
        bytesTransferred = 0
        totalBytesKnown = true
        phase = .active
        samples = [Sample(date: now, bytes: 0)]
    }

    mutating func advance(bytes: Int64, at now: Date) {
        guard bytes > 0 else { return }
        switch phase {
        case .active, .indeterminate:
            break
        case .idle, .paused, .completed, .failed:
            return
        }
        if totalBytesKnown, case .active = phase {
            bytesTransferred = min(totalBytes, bytesTransferred + bytes)
        } else {
            bytesTransferred += bytes
        }
        samples.append(Sample(date: now, bytes: bytesTransferred))
        let cutoff = now.addingTimeInterval(-3)
        samples.removeAll { $0.date < cutoff }
        if totalBytesKnown, bytesTransferred >= totalBytes, case .active = phase {
            phase = .completed(verified: verifiedOnComplete)
        }
    }

    mutating func pause(reason: String) {
        switch phase {
        case .active, .indeterminate:
            phase = .paused(reason: reason)
        case .idle, .paused, .completed, .failed:
            break
        }
    }

    mutating func resume() {
        guard case .paused = phase else { return }
        phase = totalBytesKnown ? .active : .indeterminate
    }

    mutating func markIndeterminate() {
        totalBytesKnown = false
        if case .paused = phase {
            return
        }
        if case .completed = phase {
            return
        }
        if case .failed = phase {
            return
        }
        phase = .indeterminate
    }

    mutating func complete() {
        if totalBytesKnown {
            bytesTransferred = totalBytes
        }
        phase = .completed(verified: verifiedOnComplete)
    }

    mutating func fail(summary: String) {
        phase = .failed(summary: summary)
    }

    func snapshot(now: Date) -> BatchProgressSnapshot {
        let speed = computedSpeed(now: now)
        let remaining: TimeInterval?
        if totalBytesKnown, case .active = phase, let speed, speed > 1 {
            remaining = Double(max(0, totalBytes - bytesTransferred)) / speed
        } else {
            remaining = nil
        }
        return BatchProgressSnapshot(
            direction: direction,
            peerName: peerName,
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytesKnown ? totalBytes : nil,
            totalBytesKnown: totalBytesKnown,
            speedBytesPerSecond: speed,
            secondsRemaining: remaining,
            currentIndex: currentIndex,
            totalCount: totalCount,
            phase: phase
        )
    }

    private var currentIndex: Int {
        guard totalCount > 0 else { return 0 }
        if case .completed = phase {
            return totalCount
        }
        guard totalBytesKnown, totalBytes > 0 else {
            return min(totalCount, 1)
        }
        let doneFiles = Int((Double(bytesTransferred) / Double(totalBytes) * Double(totalCount)).rounded(.down))
        return min(totalCount, max(1, doneFiles + 1))
    }

    private func computedSpeed(now: Date) -> Double? {
        let window = samples.filter { now.timeIntervalSince($0.date) <= 3 }
        guard let first = window.first, let last = window.last, last.date > first.date else {
            return nil
        }
        let deltaBytes = last.bytes - first.bytes
        let deltaTime = last.date.timeIntervalSince(first.date)
        guard deltaTime > 0, deltaBytes >= 0 else { return nil }
        return Double(deltaBytes) / deltaTime
    }
}
