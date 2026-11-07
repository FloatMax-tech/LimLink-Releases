import Darwin
import Foundation

/// A folder the user authorized for received files, such as Files › Downloads.
public struct SaveFolder: Equatable, Sendable {
    public let url: URL
    public let displayName: String

    public init(url: URL, displayName: String) {
        self.url = url
        self.displayName = displayName
    }
}

/// Remembers the authorized save folder across launches with a bookmark.
/// Callers own the security scope: start access before `remember`, and keep it while saving.
@MainActor
public final class SaveFolderPreference {
    private static let storageKey = "limlink.saveFolder.bookmark"
    private static let nameKey = "limlink.saveFolder.name"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    public func remember(_ url: URL) throws -> SaveFolder {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = SaveFolder(url: url, displayName: Self.displayName(for: url))
        defaults.set(data, forKey: Self.storageKey)
        defaults.set(folder.displayName, forKey: Self.nameKey)
        return folder
    }

    /// The remembered folder, or nil when none was chosen or the bookmark no longer resolves.
    /// A stale bookmark is refreshed in place.
    public func resolve() -> SaveFolder? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        let name = defaults.string(forKey: Self.nameKey) ?? Self.displayName(for: url)
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.storageKey)
        }
        return SaveFolder(url: url, displayName: name)
    }

    public func forget() {
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.nameKey)
    }

    static func displayName(for url: URL) -> String {
        let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        let name = localized ?? url.lastPathComponent
        return name == "Downloads" ? L10n.text("下载") : name
    }
}

/// Publishes received files into a folder outside the app container. The file first moves into a
/// hidden staging folder inside the destination (a rename on the same volume, a copy otherwise),
/// so a partial file never appears under its final name.
public actor FolderFileStore {
    static let stagingName = ".limlink-receive-staging"

    public init() {}

    public func save(name: String, fileURL: URL, expectedSize: Int, destination: URL) async throws -> SavedFile {
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw TransferFileStoreError.notRegularFile(fileURL)
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard size == expectedSize else { throw TransferFileStoreError.sizeMismatch(expected: expectedSize, actual: size) }
            try Task.checkCancellation()
            let temporary = try FolderFileStaging.shared.stage(fileURL, destination: destination)
            defer { FolderFileStaging.shared.finish(temporary) }
            let saved: SavedFile
            do {
                saved = try await TransferFileStore(inbox: destination).save(name: name, fileURL: temporary, expectedSize: expectedSize)
            } catch {
                // Hand the file back so the caller can still keep it somewhere else.
                if (try? manager.moveItem(at: temporary, to: fileURL)) == nil { try? manager.removeItem(at: temporary) }
                throw error
            }
            return saved
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TransferFileStoreError {
            throw error
        } catch {
            throw TransferFileStoreError.saveFailed(destination, message: error.localizedDescription)
        }
    }
}

/// Coordinates every store in this process, including while a store awaits publication on another
/// actor. Only this protocol's expired regular files may be reclaimed; user files are left alone.
final class FolderFileStaging: @unchecked Sendable {
    static let shared = FolderFileStaging()
    private let lock = NSLock()
    private var active: Set<URL> = []

    private init() {}

    func stage(_ source: URL, destination: URL) throws -> URL {
        try lock.withLock {
            let manager = FileManager.default
            let staging = destination.appendingPathComponent(FolderFileStore.stagingName, isDirectory: true)
            if !manager.fileExists(atPath: staging.path) {
                try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            guard try manager.attributesOfItem(atPath: staging.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw TransferFileStoreError.saveFailed(destination, message: L10n.text("接收暂存位置不是普通文件夹。"))
            }
            reclaimExpiredFiles(in: staging)
            let temporary = staging.appendingPathComponent(UUID().uuidString + ".partial")
            try manager.moveItem(at: source, to: temporary)
            do {
                // A moved file may carry old source dates. Retention starts with this handoff.
                try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: temporary.path)
            } catch {
                // A failed staging timestamp must not strand the caller's received file.
                try? manager.moveItem(at: temporary, to: source)
                throw error
            }
            active.insert(temporary.resolvingSymlinksInPath().standardizedFileURL)
            return temporary
        }
    }

    func finish(_ temporary: URL) {
        lock.withLock {
            let canonical = temporary.resolvingSymlinksInPath().standardizedFileURL
            active.remove(canonical)
            let staging = temporary.deletingLastPathComponent()
            guard !active.contains(where: { $0.deletingLastPathComponent() == canonical.deletingLastPathComponent() }) else { return }
            // rmdir refuses nonempty directories atomically, even if another process adds a file.
            staging.withUnsafeFileSystemRepresentation { path in
                if let path { _ = rmdir(path) }
            }
        }
    }

    /// The age limit also protects recent publications from another process or device sharing
    /// this folder. Active files in this process are protected regardless of their timestamps.
    private func reclaimExpiredFiles(in staging: URL) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for item in items {
            let stem = item.deletingPathExtension().lastPathComponent
            guard item.pathExtension == "partial", let id = UUID(uuidString: stem),
                  id.uuidString == stem.uppercased(),
                  let attributes = try? manager.attributesOfItem(atPath: item.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let created = attributes[.creationDate] as? Date,
                  let modified = attributes[.modificationDate] as? Date,
                  max(created, modified) < cutoff,
                  !active.contains(item.resolvingSymlinksInPath().standardizedFileURL) else { continue }
            // Never recurse if another process replaces the checked regular file with a folder.
            item.withUnsafeFileSystemRepresentation { path in
                if let path { _ = unlink(path) }
            }
        }
    }
}
