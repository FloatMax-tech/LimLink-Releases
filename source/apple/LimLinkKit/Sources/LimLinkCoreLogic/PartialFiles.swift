import Foundation

public enum PartialActivity: String, Codable, Equatable, Sendable {
    case transferring
    case paused
    case disconnected
}

public struct PartialFileRecord: Codable, Equatable, Sendable {
    public var id: String
    public var byteCount: Int64
    public var lastWrite: Date
    public var activity: PartialActivity
    /// When `paused` or `disconnected` began. Session expiry is 30 minutes from here.
    public var since: Date?

    public init(id: String, byteCount: Int64, lastWrite: Date, activity: PartialActivity, since: Date?) {
        self.id = id
        self.byteCount = byteCount
        self.lastWrite = lastWrite
        self.activity = activity
        self.since = since
    }
}

/// Which partials a manual clear may delete. Active, paused, and not-yet-expired records stay.
public struct PartialStore: Equatable, Sendable {
    public static let sessionExpiry: TimeInterval = 30 * 60
    public static let maxAge: TimeInterval = 24 * 60 * 60
    public private(set) var records: [PartialFileRecord]

    public init(records: [PartialFileRecord] = []) {
        self.records = records
    }

    /// `expiredOnly` is the settings row. The default total is what storage stats count.
    public func partialFilesSize(expiredOnly: Bool = false, now: Date = Date()) -> Int64 {
        records.reduce(0) { total, record in
            if expiredOnly, !isSessionExpired(record, now: now) { return total }
            return total + record.byteCount
        }
    }

    public func isSessionExpired(_ record: PartialFileRecord, now: Date) -> Bool {
        switch record.activity {
        case .transferring:
            return false
        case .paused, .disconnected:
            guard let since = record.since else { return false }
            return now.timeIntervalSince(since) >= Self.sessionExpiry
        }
    }

    /// Drops partials paused or disconnected for 30 minutes. Everything else stays.
    @discardableResult
    public mutating func clearPartialFiles(now: Date) -> [String] {
        let removed = records.filter { isSessionExpired($0, now: now) }.map(\.id)
        let expired = Set(removed)
        records.removeAll { expired.contains($0.id) }
        return removed
    }

    /// Launch and foreground. Drops partials whose last write is at least 24 hours ago.
    @discardableResult
    public mutating func purgeOlderThan24Hours(now: Date) -> [String] {
        let removed = records.filter { now.timeIntervalSince($0.lastWrite) >= Self.maxAge }.map(\.id)
        let expired = Set(removed)
        records.removeAll { expired.contains($0.id) }
        return removed
    }

    public mutating func upsert(_ record: PartialFileRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
    }

    public mutating func remove(id: String) {
        records.removeAll { $0.id == id }
    }
}

public enum PartialFiles {
    /// Under Application Support. Not Documents, and not a Files-visible directory.
    public static let relativeDirectory = "LimLink/Partial"

    public static func directory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(relativeDirectory, isDirectory: true)
    }

    public static func isFilesVisiblePath(_ path: String) -> Bool {
        let folded = path.replacingOccurrences(of: "\\", with: "/")
        return folded.contains("/Documents") || folded.contains("/Documents/")
    }
}

public enum PartialDirectoryError: Error, Equatable {
    case unreadable
}

/// Coordinates complete file transactions across independently opened instances.
/// The pool lock only protects bookkeeping; unrelated paths can perform I/O concurrently.
enum PartialFileTransactions {
    private final class Entry {
        let lock = NSLock()
        var users = 0
    }

    private static let poolLock = NSLock()
    // Entries and their user counts are accessed only while poolLock is held.
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    static func withLock<T>(at url: URL, _ body: () throws -> T) rethrows -> T {
        let path = canonicalPath(for: url)
        let entry = poolLock.withLock {
            let entry = entries[path] ?? Entry()
            entry.users += 1
            entries[path] = entry
            return entry
        }
        defer {
            poolLock.withLock {
                entry.users -= 1
                if entry.users == 0 { entries[path] = nil }
            }
        }
        return try entry.lock.withLock(body)
    }

    private static func canonicalPath(for url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        // Foundation may leave the entire path unresolved when its final component
        // is missing. Resolve an existing ancestor so creation cannot change the key.
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var canonical = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return canonical.path
    }
}

/// On-disk partials. The manifest records the injected clock; file bytes are the partial itself.
public struct PartialDirectory: Sendable {
    public let root: URL
    private let manifestName = "manifest.json"

    public init(root: URL) throws {
        self.root = root
        try PartialFileTransactions.withLock(at: root) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: manifestURL.path) {
                try save(PartialStore())
            }
        }
    }

    public func partialFilesSize(expiredOnly: Bool = false, now: Date = Date()) throws -> Int64 {
        try PartialFileTransactions.withLock(at: root) {
            let store = try load()
            var total: Int64 = 0
            for record in store.records {
                if expiredOnly, !store.isSessionExpired(record, now: now) { continue }
                let url = fileURL(record.id)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }
    }

    public func records() throws -> [PartialFileRecord] {
        try PartialFileTransactions.withLock(at: root) { try load().records }
    }

    public func upsert(_ record: PartialFileRecord, bytes: [UInt8]) throws {
        try PartialFileTransactions.withLock(at: root) {
            var store = try load()
            var stored = record
            stored.byteCount = Int64(bytes.count)
            store.upsert(stored)
            try Data(bytes).write(to: fileURL(record.id), options: .atomic)
            try save(store)
        }
    }

    public func clearPartialFiles(now: Date) throws {
        try PartialFileTransactions.withLock(at: root) {
            var store = try load()
            let removed = store.clearPartialFiles(now: now)
            try save(store)
            for id in removed {
                try? FileManager.default.removeItem(at: fileURL(id))
            }
        }
    }

    public func purgeOlderThan24Hours(now: Date) throws {
        try PartialFileTransactions.withLock(at: root) {
            var store = try load()
            let removed = store.purgeOlderThan24Hours(now: now)
            try save(store)
            for id in removed {
                try? FileManager.default.removeItem(at: fileURL(id))
            }
        }
    }

    public func remove(id: String) throws {
        try PartialFileTransactions.withLock(at: root) {
            var store = try load()
            store.remove(id: id)
            try save(store)
            try? FileManager.default.removeItem(at: fileURL(id))
        }
    }

    private var manifestURL: URL {
        root.appendingPathComponent(manifestName)
    }

    private func fileURL(_ id: String) -> URL {
        root.appendingPathComponent(id).appendingPathExtension("bin")
    }

    private func load() throws -> PartialStore {
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let records = try? decoder.decode([PartialFileRecord].self, from: data) else {
            throw PartialDirectoryError.unreadable
        }
        return PartialStore(records: records)
    }

    private func save(_ store: PartialStore) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(store.records)
        try data.write(to: manifestURL, options: .atomic)
    }
}
