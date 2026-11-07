import Foundation

struct PartialSyncItem: Sendable {
    var id: String
    var bytes: [UInt8]
    var activity: PartialActivity
    var since: Date?
    var lastWrite: Date
    var remove: Bool
}

enum SystemVolumes {
    static func identify(_ url: URL) -> VolumeIdentity {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
        if let id = values?.volumeUUIDString {
            let mounted = mountedIDs().contains(id)
            return VolumeIdentity(id: id, isMounted: mounted)
        }
        return VolumeIdentity(id: localVolume, isMounted: true)
    }

    static func isMounted(_ volumeID: String) -> Bool {
        volumeID == localVolume || mountedIDs().contains(volumeID)
    }

    private static let localVolume = "local"

    private static func mountedIDs() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey]) ?? []
        return Set(urls.compactMap { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString })
    }
}

/// Partial directories, the registry, and the host storage APIs. File work stays off the main thread.
enum PartialFileMaintenance {
    private static let fileQueue = DispatchQueue(label: "com.limlink.partial-file-work", qos: .utility)
    private static let lock = NSLock()
    // Every access to this cache is protected by lock.
    nonisolated(unsafe) private static var decisions: [String: PartialPlacementDecision] = [:]

    static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func privatePartialURL() throws -> URL {
        let url = PartialFiles.directory(applicationSupport: applicationSupportDirectory())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        excludeFromBackup(url)
        return url
    }

    static func enqueue(_ items: [PartialSyncItem], saveLocation: URL?) {
        let captured = items
        let save = saveLocation
        enqueueFileWork {
            write(captured, saveLocation: save)
        }
    }

    /// Keeps a discarded session's deletion after every older queued partial write.
    static func enqueueFileWork(_ work: @escaping @Sendable () -> Void) {
        fileQueue.async(execute: work)
    }

    static func copyVerifiedIfNeeded(fileName: String, bytes: [UInt8], saveLocation: URL?) {
        let key = saveLocation?.path ?? ""
        lock.lock()
        let decision = decisions[key]
        lock.unlock()
        guard let decision, decision.mode == .privateThenCopy, let target = decision.targetDirectory else { return }
        access(target) {
            try? PartialPlacement.copyAfterVerification(
                decision,
                bytes: bytes,
                fileName: fileName,
                fileSystem: FileManagerPartialFileSystem()
            )
        }
    }

    /// Deletes partials whose last write is at least 24 hours ago, on volumes that are mounted.
    static func purgeStale() async {
        guard let library = try? openRegistry() else { return }
        await library.purgeOlderThan24Hours(now: Date(), isMounted: SystemVolumes.isMounted)
    }

    private static func write(_ items: [PartialSyncItem], saveLocation: URL?) {
        let decision = cachedDecision(saveLocation: saveLocation)
        guard let directory = try? PartialDirectory(root: decision.directory) else { return }
        excludeFromBackup(decision.directory)
        for item in items {
            if item.remove {
                try? directory.remove(id: item.id)
                continue
            }
            let record = PartialFileRecord(
                id: item.id,
                byteCount: Int64(item.bytes.count),
                lastWrite: item.lastWrite,
                activity: item.activity,
                since: item.since
            )
            try? directory.upsert(record, bytes: item.bytes)
        }
    }

    private static func cachedDecision(saveLocation: URL?) -> PartialPlacementDecision {
        let key = saveLocation?.path ?? ""
        lock.lock()
        if let existing = decisions[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()
        let support = applicationSupportDirectory()
        var scoped: URL?
        let decision = PartialPlacement.choose(
            saveLocation: saveLocation,
            applicationSupport: support,
            volumeOf: SystemVolumes.identify,
            fileSystem: FileManagerPartialFileSystem(),
            beginSecurityScope: { url in
                scoped = startScope(url) ? url : nil
                return scoped != nil
            }
        )
        if let scoped {
            stopScope(scoped)
        }
        if let library = try? openRegistry() {
            try? library.remember(decision, id: key.isEmpty ? "private" : key)
        }
        lock.lock()
        decisions[key] = decision
        lock.unlock()
        return decision
    }

    private static func openRegistry() throws -> PartialLibrary {
        let url = applicationSupportDirectory()
            .appendingPathComponent("LimLink", isDirectory: true)
            .appendingPathComponent("partial-registry.json")
        return try PartialLibrary(registryURL: url)
    }

    private static func access(_ url: URL, _ body: () -> Void) {
        let started = startScope(url)
        body()
        if started {
            stopScope(url)
        }
    }

    private static func startScope(_ url: URL) -> Bool {
        #if os(iOS)
        return url.startAccessingSecurityScopedResource()
        #else
        _ = url
        return false
        #endif
    }

    private static func stopScope(_ url: URL) {
        #if os(iOS)
        url.stopAccessingSecurityScopedResource()
        #else
        _ = url
        #endif
    }

    private static func excludeFromBackup(_ url: URL) {
        #if os(iOS) || os(macOS)
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
        #else
        _ = url
        #endif
    }
}

extension LimLink {
    /// Total size of partials on every mounted volume this Kit has used.
    /// Pass `expiredOnly: true` for the settings row (session-expired partials only).
    /// Touches storage. The work runs off the main thread. This method is not isolated to the main actor.
    public static func partialFilesSize(expiredOnly: Bool = false) async -> Int64 {
        await Task.detached(priority: .utility) {
            guard let library = try? PartialLibrary(
                registryURL: PartialFileMaintenance.registryURLForHost()
            ) else { return 0 }
            return (try? library.partialFilesSize(
                expiredOnly: expiredOnly,
                now: Date(),
                isMounted: SystemVolumes.isMounted
            )) ?? 0
        }.value
    }

    /// Deletes session-expired partials on every mounted volume this Kit has used.
    /// Active, paused, and not-yet-expired partials stay, so `partialFilesSize(expiredOnly: true)` is 0 afterward.
    /// Touches storage. The work runs off the main thread. This method is not isolated to the main actor.
    public static func clearPartialFiles() async {
        await Task.detached(priority: .utility) {
            guard let library = try? PartialLibrary(
                registryURL: PartialFileMaintenance.registryURLForHost()
            ) else { return }
            try? library.clearPartialFiles(now: Date(), isMounted: SystemVolumes.isMounted)
        }.value
    }
}

extension PartialFileMaintenance {
    static func registryURLForHost() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("LimLink", isDirectory: true)
            .appendingPathComponent("partial-registry.json")
    }
}
