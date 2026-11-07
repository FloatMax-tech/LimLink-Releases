import Foundation

public struct VolumeIdentity: Equatable, Sendable {
    public var id: String
    public var isMounted: Bool

    public init(id: String, isMounted: Bool) {
        self.id = id
        self.isMounted = isMounted
    }
}

/// Where a partial is written. Recorded in the registry for each save location the Kit has used.
public enum PartialWriteMode: String, Codable, Equatable, Sendable {
    /// Hidden `.limlink-partial/` inside the target folder. Same volume as the save location.
    case targetHidden
    /// `Application Support/LimLink/Partial/` because the save location is on that volume.
    case privateDirectory
    /// Private partial directory, then copy the whole file into the target after SHA-256.
    case privateThenCopy
}

/// Why a cross-volume target could not hold the partial (protocol 5.5).
public enum PartialFallbackReason: String, Codable, Equatable, Sendable {
    /// The hidden directory could not be created.
    case hiddenDirectoryUnusable
    /// An atomic rename inside the hidden directory failed or is not reliable.
    case renameUnreliable
    /// The volume cannot resume a write at a middle offset (open / seek / write).
    case resumeWriteUnsupported
}

public struct PartialPlacementDecision: Equatable, Sendable {
    public var directory: URL
    public var volumeID: String
    public var mode: PartialWriteMode
    public var fallbackReason: PartialFallbackReason?
    public var targetDirectory: URL?

    public init(
        directory: URL,
        volumeID: String,
        mode: PartialWriteMode,
        fallbackReason: PartialFallbackReason?,
        targetDirectory: URL?
    ) {
        self.directory = directory
        self.volumeID = volumeID
        self.mode = mode
        self.fallbackReason = fallbackReason
        self.targetDirectory = targetDirectory
    }
}

public enum PartialFileSystemError: Error, Equatable {
    case unavailable
}

/// Disk operations the placement probe and the post-verify copy need. Tests substitute a scripted one.
public protocol PartialFileSystem: Sendable {
    func createDirectory(_ url: URL) throws
    func write(_ bytes: [UInt8], to url: URL) throws
    func atomicRename(from source: URL, to destination: URL) throws
    /// Resume a file that already has `offset` bytes. Fails when the volume cannot seek and write.
    func write(atOffset offset: Int, bytes: [UInt8], to url: URL) throws
    func remove(_ url: URL) throws
    func copy(_ source: URL, to destination: URL) throws
}

public struct FileManagerPartialFileSystem: PartialFileSystem {
    public init() {}

    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ bytes: [UInt8], to url: URL) throws {
        try Data(bytes).write(to: url, options: .atomic)
    }

    public func atomicRename(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: source, to: destination)
    }

    public func write(atOffset offset: Int, bytes: [UInt8], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        handle.write(Data(bytes))
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func copy(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
    }
}

public enum PartialPlacement {
    public static let hiddenDirectoryName = ".limlink-partial"

    /// Same volume uses the private partial directory.
    /// A different volume tries `.limlink-partial/` in the target first (the caller starts security-scoped access).
    /// Any of: the hidden directory cannot be created, rename-into-place fails, or a middle-offset write fails,
    /// falls back to the private directory and copies the whole file across after verification.
    public static func choose(
        saveLocation: URL?,
        applicationSupport: URL,
        volumeOf: (URL) -> VolumeIdentity,
        fileSystem: any PartialFileSystem,
        beginSecurityScope: ((URL) -> Bool)? = nil
    ) -> PartialPlacementDecision {
        let privateDirectory = PartialFiles.directory(applicationSupport: applicationSupport)
        let privateVolume = volumeOf(applicationSupport)
        guard let saveLocation else {
            return PartialPlacementDecision(
                directory: privateDirectory,
                volumeID: privateVolume.id,
                mode: .privateDirectory,
                fallbackReason: nil,
                targetDirectory: nil
            )
        }
        let saveVolume = volumeOf(saveLocation)
        if saveVolume.isMounted, privateVolume.isMounted, saveVolume.id == privateVolume.id {
            return PartialPlacementDecision(
                directory: privateDirectory,
                volumeID: privateVolume.id,
                mode: .privateDirectory,
                fallbackReason: nil,
                targetDirectory: nil
            )
        }
        _ = beginSecurityScope?(saveLocation)
        let hidden = saveLocation.appendingPathComponent(hiddenDirectoryName, isDirectory: true)
        if saveVolume.isMounted, let reason = probe(hidden, fileSystem: fileSystem) {
            return fallback(privateDirectory, volumeID: privateVolume.id, reason: reason, target: saveLocation)
        }
        if !saveVolume.isMounted {
            return fallback(
                privateDirectory,
                volumeID: privateVolume.id,
                reason: .hiddenDirectoryUnusable,
                target: saveLocation
            )
        }
        return PartialPlacementDecision(
            directory: hidden,
            volumeID: saveVolume.id,
            mode: .targetHidden,
            fallbackReason: nil,
            targetDirectory: saveLocation
        )
    }

    /// Copies a verified file from the private partial directory into the target folder.
    public static func copyAfterVerification(
        _ decision: PartialPlacementDecision,
        bytes: [UInt8],
        fileName: String,
        fileSystem: any PartialFileSystem
    ) throws {
        guard decision.mode == .privateThenCopy, let target = decision.targetDirectory else { return }
        let source = decision.directory.appendingPathComponent(fileName)
        try fileSystem.createDirectory(decision.directory)
        try fileSystem.write(bytes, to: source)
        try fileSystem.copy(source, to: target.appendingPathComponent(fileName))
    }

    private static func fallback(
        _ directory: URL,
        volumeID: String,
        reason: PartialFallbackReason,
        target: URL
    ) -> PartialPlacementDecision {
        PartialPlacementDecision(
            directory: directory,
            volumeID: volumeID,
            mode: .privateThenCopy,
            fallbackReason: reason,
            targetDirectory: target
        )
    }

    /// Returns the first probe that failed. Nil means the hidden directory can hold a resumable partial.
    private static func probe(_ hidden: URL, fileSystem: any PartialFileSystem) -> PartialFallbackReason? {
        do {
            try fileSystem.createDirectory(hidden)
        } catch {
            return .hiddenDirectoryUnusable
        }
        let source = hidden.appendingPathComponent(".limlink-probe")
        let renamed = hidden.appendingPathComponent(".limlink-probe-renamed")
        do {
            try fileSystem.write([], to: source)
            try fileSystem.atomicRename(from: source, to: renamed)
        } catch {
            try? fileSystem.remove(source)
            return .renameUnreliable
        }
        try? fileSystem.remove(renamed)
        let resume = hidden.appendingPathComponent(".limlink-probe-resume")
        do {
            try fileSystem.write([0], to: resume)
        } catch {
            try? fileSystem.remove(resume)
            return .renameUnreliable
        }
        do {
            try fileSystem.write(atOffset: 1, bytes: [1], to: resume)
        } catch {
            try? fileSystem.remove(resume)
            return .resumeWriteUnsupported
        }
        try? fileSystem.remove(resume)
        return nil
    }
}

public struct PartialUseRecord: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var volumeID: String
    public var mode: PartialWriteMode
    public var fallbackReason: PartialFallbackReason?
    public var targetPath: String?

    public init(
        id: String,
        path: String,
        volumeID: String,
        mode: PartialWriteMode,
        fallbackReason: PartialFallbackReason?,
        targetPath: String?
    ) {
        self.id = id
        self.path = path
        self.volumeID = volumeID
        self.mode = mode
        self.fallbackReason = fallbackReason
        self.targetPath = targetPath
    }
}

/// Every partial directory the Kit has used. Cleanup skips a volume that is not mounted.
public struct PartialLibrary: Sendable {
    public let registryURL: URL

    public init(registryURL: URL) throws {
        self.registryURL = registryURL
        try PartialFileTransactions.withLock(at: registryURL) {
            let parent = registryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: registryURL.path) {
                try Data("[]".utf8).write(to: registryURL, options: .atomic)
            }
        }
    }

    public func uses() throws -> [PartialUseRecord] {
        try PartialFileTransactions.withLock(at: registryURL) { try load() }
    }

    public func remember(_ decision: PartialPlacementDecision, id: String) throws {
        try PartialFileTransactions.withLock(at: registryURL) {
            var records = try load()
            let record = PartialUseRecord(
                id: id,
                path: decision.directory.path,
                volumeID: decision.volumeID,
                mode: decision.mode,
                fallbackReason: decision.fallbackReason,
                targetPath: decision.targetDirectory?.path
            )
            records.removeAll { $0.id == id }
            records.append(record)
            try save(records)
        }
    }

    public func partialFilesSize(
        expiredOnly: Bool = false,
        now: Date = Date(),
        isMounted: (String) -> Bool
    ) throws -> Int64 {
        var seen: Set<String> = []
        var total: Int64 = 0
        for record in try uses() where isMounted(record.volumeID) {
            guard seen.insert(record.path).inserted else { continue }
            total += try size(at: record.path, expiredOnly: expiredOnly, now: now)
        }
        return total
    }

    public func clearPartialFiles(now: Date, isMounted: (String) -> Bool) throws {
        var seen: Set<String> = []
        for record in try uses() where isMounted(record.volumeID) {
            guard seen.insert(record.path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: record.path) else { continue }
            let directory = try PartialDirectory(root: URL(fileURLWithPath: record.path, isDirectory: true))
            try directory.clearPartialFiles(now: now)
        }
    }

    public func purgeOlderThan24Hours(now: Date, isMounted: (String) -> Bool) throws {
        var seen: Set<String> = []
        for record in try uses() where isMounted(record.volumeID) {
            guard seen.insert(record.path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: record.path) else { continue }
            let directory = try PartialDirectory(root: URL(fileURLWithPath: record.path, isDirectory: true))
            try directory.purgeOlderThan24Hours(now: now)
        }
    }

    /// Sums partial bytes. Touches storage off the main thread. Not isolated to the main actor.
    public func partialFilesSize(
        expiredOnly: Bool = false,
        now: Date = Date(),
        isMounted: @escaping @Sendable (String) -> Bool
    ) async -> Int64 {
        let url = registryURL
        return await Task.detached(priority: .utility) {
            guard let library = try? PartialLibrary(registryURL: url) else { return Int64(0) }
            return (try? library.partialFilesSize(expiredOnly: expiredOnly, now: now, isMounted: isMounted)) ?? 0
        }.value
    }

    /// Deletes session-expired partials on mounted volumes. Touches storage off the main thread.
    /// Not isolated to the main actor. Active and not-yet-expired partials stay.
    public func clearPartialFiles(
        now: Date = Date(),
        isMounted: @escaping @Sendable (String) -> Bool
    ) async {
        let url = registryURL
        await Task.detached(priority: .utility) {
            guard let library = try? PartialLibrary(registryURL: url) else { return }
            try? library.clearPartialFiles(now: now, isMounted: isMounted)
        }.value
    }

    /// Drops partials whose last write is at least 24 hours ago. Touches storage off the main thread.
    /// Not isolated to the main actor. Unmounted volumes are left for the next time they appear.
    public func purgeOlderThan24Hours(
        now: Date = Date(),
        isMounted: @escaping @Sendable (String) -> Bool
    ) async {
        let url = registryURL
        await Task.detached(priority: .utility) {
            guard let library = try? PartialLibrary(registryURL: url) else { return }
            try? library.purgeOlderThan24Hours(now: now, isMounted: isMounted)
        }.value
    }

    private func size(at path: String, expiredOnly: Bool, now: Date) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let directory = try PartialDirectory(root: URL(fileURLWithPath: path, isDirectory: true))
        return try directory.partialFilesSize(expiredOnly: expiredOnly, now: now)
    }

    private func load() throws -> [PartialUseRecord] {
        let data = try Data(contentsOf: registryURL)
        guard let records = try? JSONDecoder().decode([PartialUseRecord].self, from: data) else {
            throw PartialDirectoryError.unreadable
        }
        return records
    }

    private func save(_ records: [PartialUseRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: registryURL, options: .atomic)
    }
}

public enum PartialMaintenanceSchedule {
    /// Launch sweeps partials older than 24 hours.
    public static let purgesOnLaunch = true

    /// Foreground and macOS wake sweep partials older than 24 hours. Other events do not.
    public static func purges(on event: LifecycleEvent) -> Bool {
        switch event {
        case .willEnterForeground, .didWake:
            return true
        case .didEnterBackground, .backgroundTimeExpired, .willSleep, .transferStarted, .transferEnded:
            return false
        }
    }
}
