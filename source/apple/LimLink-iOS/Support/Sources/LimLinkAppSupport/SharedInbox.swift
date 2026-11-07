import Foundation

/// One file handed over by the share extension, waiting in the App Group container.
public struct PendingShare: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let size: Int
    public let createdAt: Date

    public init(url: URL, name: String, size: Int, createdAt: Date) {
        self.url = url
        self.name = name
        self.size = size
        self.createdAt = createdAt
    }
}

/// The App Group inbox used by the share extension and the app. The extension copies the shared
/// file here; the app imports it on launch, foreground activation, or `limlink://share`.
public enum SharedInbox {
    public static let appGroup = "group.com.limlink.dev"
    public static let openURL = URL(string: "limlink://share")!
    static let folderName = "ShareInbox"

    public static func defaultContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Stages a file on disk for the app; rejects nonregular files and files above 5 GB.
    @discardableResult
    public static func stage(_ source: URL, name: String, container: URL? = nil) throws -> URL {
        try stage(source, name: name, container: container, copyFile: FileManager.default.copyItem(at:to:))
    }

    static func stage(
        _ source: URL, name: String, container: URL?,
        copyFile: (URL, URL) throws -> Void
    ) throws -> URL {
        guard let base = container ?? defaultContainer() else { throw ShareInboxError.unavailable }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ShareInboxError.notAFile
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= TransferLimits.maximumFileBytes else { throw ShareInboxError.tooLarge }

        let safeName = safe(name.isEmpty ? source.lastPathComponent : name, fileExtension: source.pathExtension)
        let inbox = base.appendingPathComponent(folderName, isDirectory: true)
        removeAbandonedStaging(in: inbox)
        let identifier = UUID().uuidString
        let directory = inbox.appendingPathComponent("." + identifier, isDirectory: true)
        let published = inbox.appendingPathComponent(identifier, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(safeName)
        do {
            try copyFile(source, destination)
            // A foreground app only sees the directory after the complete disk copy exists.
            try manager.moveItem(at: directory, to: published)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        return published.appendingPathComponent(safeName)
    }

    /// Pending shares, oldest first. Files stay put until a successful import is acknowledged.
    public static func pending(container: URL? = nil) -> [PendingShare] {
        guard let base = container ?? defaultContainer() else { return [] }
        let manager = FileManager.default
        let root = base.appendingPathComponent(folderName, isDirectory: true)
        removeAbandonedStaging(in: root)
        guard let directories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return directories.compactMap { directory -> PendingShare? in
            guard let items = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ), let file = items.first(where: { item in
                (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }) else { return nil }
            let created = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return PendingShare(url: file, name: file.lastPathComponent, size: size, createdAt: created)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes one pending share, for example once the app imported it.
    public static func discard(_ share: PendingShare) {
        try? FileManager.default.removeItem(at: share.url.deletingLastPathComponent())
    }

    /// Imports one disk handoff. A failed import keeps the original so foreground activation
    /// can retry after a temporary disk or file-access failure.
    @MainActor
    public static func importNext(
        canImport: Bool = true,
        container: URL? = nil,
        using importFile: (URL) async -> Bool
    ) async -> SharedInboxImportResult {
        guard canImport else { return .deferred }
        let shares = pending(container: container)
        guard let first = shares.first else { return .empty }
        guard await importFile(first.url) else { return .failed }
        discard(first)
        return .imported(hasMore: shares.count > 1)
    }

    /// Reclaims only old, unpublished directories owned by this staging protocol.
    /// Fresh copies and all published handoffs remain available regardless of age.
    private static func removeAbandonedStaging(in inbox: URL) {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for directory in directories {
            let name = directory.lastPathComponent
            guard name.first == ".", UUID(uuidString: String(name.dropFirst())) != nil,
                  let attributes = try? manager.attributesOfItem(atPath: directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let created = attributes[.creationDate] as? Date,
                  let modified = attributes[.modificationDate] as? Date,
                  max(created, modified) < cutoff else { continue }
            try? manager.removeItem(at: directory)
        }
    }

    /// Keeps the original name when it is a plain file name, otherwise derives one.
    static func safe(_ name: String, fileExtension: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = L10n.text("分享的文件") + (fileExtension.isEmpty ? "" : "." + fileExtension)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return fallback }
        return String(cleaned.prefix(200))
    }
}

public enum ShareInboxError: Error, Equatable {
    case unavailable
    case notAFile
    case tooLarge
}

public enum SharedInboxImportResult: Equatable, Sendable {
    case deferred
    case empty
    case failed
    case imported(hasMore: Bool)
}
