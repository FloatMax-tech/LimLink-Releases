import Foundation

/// Local mismatch record. Fields are the device name, IP, TXT `app`, TLS `app`, and timestamp.
/// The log is not uploaded. Call `clearDiagnosticsLog()` to drop every entry.
/// Local note that is not uploaded. `clearDiagnosticsLog()` drops these with the mismatch rows.
public struct DiagnosticNote: Codable, Equatable, Sendable {
    public static let ticketVerificationUnimplemented = "ticket verification isn't implemented yet"
    public var message: String
    public var timestamp: String

    public init(message: String, timestamp: String) {
        self.message = message
        self.timestamp = timestamp
    }
}

public struct AppMismatchLogEntry: Codable, Equatable, Sendable {
    public var deviceName: String
    public var ip: String
    public var txtApp: String
    public var tlsApp: String
    public var timestamp: String

    public init(deviceName: String, ip: String, txtApp: String, tlsApp: String, timestamp: String) {
        self.deviceName = deviceName
        self.ip = ip
        self.txtApp = txtApp
        self.tlsApp = tlsApp
        self.timestamp = timestamp
    }
}

public enum DiagnosticAppLabel {
    public static func render(raw: String?, present: Bool) -> String {
        guard present else { return LimLinkProtocol.defaultApp }
        switch HostAppIdentity.observe(raw) {
        case .implicitLimlink:
            return LimLinkProtocol.defaultApp
        case .named(let app):
            return app
        case .unrecognized:
            return raw ?? ""
        }
    }
}

public struct LocalDiagnosticLog: Equatable, Sendable {
    public static let capacity = 100
    /// An entry older than this, measured by its `timestamp`, is dropped.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    public private(set) var entries: [AppMismatchLogEntry]

    public init(entries: [AppMismatchLogEntry] = []) {
        self.entries = entries
    }

    /// Prunes expired rows, appends, then enforces the 100-entry cap.
    public mutating func record(_ entry: AppMismatchLogEntry, clock: DiagnosticClock) {
        entries.append(entry)
        prune(clock: clock)
    }

    /// Drops entries whose timestamp is at least `retention` before `clock.now`, then keeps the latest 100.
    public mutating func prune(clock: DiagnosticClock) {
        entries.removeAll { entry in
            guard let recorded = DiagnosticTimestamps.parse(entry.timestamp) else { return true }
            return clock.now.timeIntervalSince(recorded) >= Self.retention
        }
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Read path. Same pruning rules as `record`.
    public mutating func entries(clock: DiagnosticClock) -> [AppMismatchLogEntry] {
        prune(clock: clock)
        return entries
    }

    public mutating func clearDiagnosticsLog() {
        entries.removeAll()
    }
}

/// Injected clock so a test can move "now" without waiting.
public struct DiagnosticClock: Equatable, Sendable {
    public var now: Date

    public init(now: Date) {
        self.now = now
    }

    public init?(rfc3339: String) {
        guard let date = DiagnosticTimestamps.parse(rfc3339) else { return nil }
        self.now = date
    }
}

public enum DiagnosticTimestamps {
    public static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.date(from: value)
    }

    public static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }
}

/// Namespaced the same way as Android `LimLink.clearDiagnosticsLog()`.
public enum LimLink {
    public static func clearDiagnosticsLog(_ log: inout LocalDiagnosticLog) {
        log.clearDiagnosticsLog()
    }

    /// Deletes every on-disk diagnostics entry in `directory`.
    /// Touches storage. The work runs off the main thread. This method is not isolated to the main actor.
    public static func clearDiagnosticsLog(at directory: URL) async throws {
        try await Task.detached(priority: .utility) {
            try DiagnosticLogFile(directory: directory).clearDiagnosticsLog()
        }.value
    }
}

public enum DiagnosticLogStoreError: Error, Equatable {
    case unreadable
}

/// File-backed log in a directory the host picks. There is no upload method.
public final class DiagnosticLogFile: @unchecked Sendable {
    public static let fileName = "app-mismatch-log.json"
    public let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data("[]".utf8).write(to: fileURL, options: .atomic)
        }
    }

    /// Prunes expired entries and writes the surviving rows back.
    public func load(clock: DiagnosticClock) throws -> LocalDiagnosticLog {
        lock.lock()
        defer { lock.unlock() }
        var log = try readUnlocked()
        log.prune(clock: clock)
        try writeUnlocked(log)
        return log
    }

    public func record(_ entry: AppMismatchLogEntry, clock: DiagnosticClock) throws {
        lock.lock()
        defer { lock.unlock() }
        var log = try readUnlocked()
        log.record(entry, clock: clock)
        try writeUnlocked(log)
    }

    public func clearDiagnosticsLog() throws {
        lock.lock()
        defer { lock.unlock() }
        try writeUnlocked(LocalDiagnosticLog())
    }

    private func readUnlocked() throws -> LocalDiagnosticLog {
        let data = try Data(contentsOf: fileURL)
        guard let decoded = try? JSONDecoder().decode([AppMismatchLogEntry].self, from: data) else {
            throw DiagnosticLogStoreError.unreadable
        }
        return LocalDiagnosticLog(entries: decoded)
    }

    private func writeUnlocked(_ log: LocalDiagnosticLog) throws {
        let data = try JSONEncoder().encode(log.entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
