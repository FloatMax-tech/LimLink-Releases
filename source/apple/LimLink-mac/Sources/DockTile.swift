import Foundation

enum DockRingStyle: Equatable {
    case active
    case paused
    case indeterminateGap
}

enum DockTileVisual: Equatable {
    case systemIcon
    case ring(fraction: Double, style: DockRingStyle)
    case checkmark
}

/// Dock 和菜单栏共用的小环状态。多个会话合计；不确定态是静止缺口，不转圈。
struct DockTileReducer {
    var completedHold: TimeInterval
    /// 静止缺口环盖住的比例。剩下的一段是缺口。
    var indeterminateFraction: Double

    private var checkmarkUntil: Date?
    private var holdConsumed = false

    var nextUpdateDate: Date? { checkmarkUntil }

    /// Private stored state makes the synthesized memberwise initializer private,
    /// so callers outside this file only see this initializer.
    init(completedHold: TimeInterval = 3, indeterminateFraction: Double = 0.75) {
        self.completedHold = completedHold
        self.indeterminateFraction = indeterminateFraction
    }

    mutating func present(sessions: [BatchProgressSnapshot], now: Date) -> DockTileVisual {
        let relevant = sessions.filter { snapshot in
            switch snapshot.phase {
            case .active, .indeterminate, .paused:
                return true
            case .idle, .completed, .failed:
                return false
            }
        }

        if relevant.isEmpty {
            let completed = sessions.contains { snapshot in
                if case .completed = snapshot.phase { return true }
                return false
            }
            if completed && !holdConsumed {
                if checkmarkUntil == nil {
                    checkmarkUntil = now.addingTimeInterval(completedHold)
                }
                if let until = checkmarkUntil, now < until {
                    return .checkmark
                }
                holdConsumed = true
                checkmarkUntil = nil
            }
            if !completed {
                holdConsumed = false
                checkmarkUntil = nil
            }
            return .systemIcon
        }

        holdConsumed = false
        checkmarkUntil = nil

        if relevant.contains(where: { snapshot in
            if case .indeterminate = snapshot.phase { return true }
            return false
        }) {
            return .ring(fraction: indeterminateFraction, style: .indeterminateGap)
        }

        let allPaused = relevant.allSatisfy { snapshot in
            if case .paused = snapshot.phase { return true }
            return false
        }
        var done: Int64 = 0
        var total: Int64 = 0
        var known = true
        for item in relevant {
            done += max(0, item.bytesTransferred)
            if item.totalBytesKnown, let itemTotal = item.totalBytes, itemTotal > 0 {
                total += itemTotal
            } else {
                known = false
            }
        }
        let fraction: Double
        if known, total > 0 {
            fraction = min(1, max(0, Double(done) / Double(total)))
        } else {
            fraction = 0
        }
        return .ring(fraction: fraction, style: allPaused ? .paused : .active)
    }
}

/// 重画限制在大约每秒 1 次，或者进度变了 1% 就画（Mac 方案 3.7）。
struct DisplayThrottle {
    var minimumInterval: TimeInterval = 1
    var minimumFractionDelta: Double = 0.01
    private var lastDraw: Date?
    private var lastFraction: Double?
    private var lastStyle: DockRingStyle?

    mutating func shouldDisplay(visual: DockTileVisual, now: Date) -> Bool {
        switch visual {
        case .systemIcon, .checkmark:
            lastDraw = now
            lastFraction = nil
            lastStyle = nil
            return true
        case .ring(let fraction, let style):
            if lastStyle != style || lastDraw == nil {
                record(fraction: fraction, style: style, now: now)
                return true
            }
            if style == .indeterminateGap {
                return false
            }
            let fractionChanged = abs((lastFraction ?? fraction) - fraction) >= minimumFractionDelta
            let timeElapsed = lastDraw.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
            if fractionChanged || timeElapsed {
                record(fraction: fraction, style: style, now: now)
                return true
            }
            return false
        }
    }

    private mutating func record(fraction: Double, style: DockRingStyle, now: Date) {
        lastDraw = now
        lastFraction = fraction
        lastStyle = style
    }
}
