import Foundation
import LimLinkCoreLogic

public enum TransferLimits {
    public static let maximumFileBytes: Int = FileTransferLimits.maximumFileBytes
    public static let chunkBytes: Int = FileTransferLimits.maximumChunkBytes
}

public struct TransferFile: Sendable {
    public let name: String
    public let source: TransferSource
    public let url: URL?
    public let originalURL: URL?
    public var size: Int { source.size }
    private let lease: StagedFileLease?

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.source = TransferSource(bytes: bytes)
        self.url = nil
        self.originalURL = nil
        self.lease = nil
    }

    fileprivate init(name: String, url: URL, size: Int, digest: String, originalURL: URL) throws {
        self.name = name
        self.source = try TransferSource(fileURL: url, size: size, sha256Hex: digest)
        self.url = url
        self.originalURL = originalURL
        self.lease = StagedFileLease(url: url)
    }
}

/// A selected file and an in-flight send share ownership of the immutable snapshot.
private final class StagedFileLease: Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}

public struct SavedFile: Sendable, Equatable, Identifiable {
    public let name: String
    public let url: URL
    public let size: Int
    /// The original bookmarked directory URL, when publication used a user-selected location.
    public let accessRoot: URL?
    public var id: URL { url }

    public init(name: String, url: URL, size: Int, accessRoot: URL? = nil) {
        self.name = name
        self.url = url
        self.size = size
        self.accessRoot = accessRoot
    }
}

public enum TransferFileStoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidFileName(String)
    case notRegularFile(URL)
    case fileTooLarge(maximumBytes: Int, actualBytes: Int)
    case readFailed(URL, message: String)
    case saveFailed(URL, message: String)
    case listFailed(URL, message: String)
    case sizeMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidFileName: "The file name must be a safe, single file name."
        case .notRegularFile: "Select a regular file. Folders and symbolic links cannot be sent."
        case .fileTooLarge(let maximum, _): "This file exceeds the \(maximum / (1024 * 1024)) MiB transfer limit."
        case .readFailed(_, let message): "The file could not be read: \(message)"
        case .saveFailed(_, let message): "The received file could not be saved: \(message)"
        case .listFailed(_, let message): "Saved files could not be listed: \(message)"
        case .sizeMismatch: "The file length changed before it could be saved."
        }
    }
}

public actor TransferFileStore {
    private let inbox: URL
    private let maximumFileBytes: Int
    private let outgoingDirectory: URL

    public init(inbox: URL, maximumFileBytes: Int = TransferLimits.maximumFileBytes, outgoingDirectory: URL? = nil) {
        self.inbox = inbox
        self.maximumFileBytes = max(0, maximumFileBytes)
        self.outgoingDirectory = outgoingDirectory ?? TransferStagingDirectories.shared.outgoing
    }

    public func load(_ url: URL) async throws -> TransferFile {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }

        do {
            try Task.checkCancellation()
            guard url.isFileURL else { throw TransferFileStoreError.notRegularFile(url) }
            guard Self.isSafeBasename(url.lastPathComponent) else {
                throw TransferFileStoreError.invalidFileName(url.lastPathComponent)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw TransferFileStoreError.notRegularFile(url)
            }
            let inspectedSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard inspectedSize <= maximumFileBytes else {
                throw TransferFileStoreError.fileTooLarge(maximumBytes: maximumFileBytes, actualBytes: inspectedSize)
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let manager = FileManager.default
            try manager.createDirectory(at: outgoingDirectory, withIntermediateDirectories: true)
            let temporary = outgoingDirectory.appendingPathComponent(UUID().uuidString)
            guard manager.createFile(atPath: temporary.path, contents: nil) else {
                throw TransferFileStoreError.readFailed(url, message: L10n.text("无法创建发送暂存文件。"))
            }
            var handedOff = false
            defer { if !handedOff { try? manager.removeItem(at: temporary) } }
            let writer = try FileHandle(forWritingTo: temporary)
            defer { try? writer.close() }
            var size = 0
            var digest = IncrementalFileDigest()
            while true {
                try Task.checkCancellation()
                let remaining = maximumFileBytes - size
                let chunkSize = remaining > 0 ? min(TransferLimits.chunkBytes, remaining) : 1
                let copied = try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return 0 }
                    guard chunk.count <= remaining else {
                        throw TransferFileStoreError.fileTooLarge(
                            maximumBytes: maximumFileBytes, actualBytes: size + chunk.count
                        )
                    }
                    try writer.write(contentsOf: chunk)
                    digest.update(chunk)
                    return chunk.count
                }
                guard copied > 0 else { break }
                size += copied
                // Let accepted receives publish while a large selection is being imported.
                await Task.yield()
            }
            try writer.synchronize()
            try Task.checkCancellation()
            let result = try TransferFile(name: url.lastPathComponent, url: temporary, size: size, digest: digest.finalizeHex(), originalURL: url)
            handedOff = true
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TransferFileStoreError {
            throw error
        } catch {
            throw TransferFileStoreError.readFailed(url, message: error.localizedDescription)
        }
    }

    /// Publishes a verified receiver-owned file without loading its contents into memory.
    public func save(name: String, fileURL: URL, expectedSize: Int) async throws -> SavedFile {
        guard Self.isSafeBasename(name) else { throw TransferFileStoreError.invalidFileName(name) }
        guard fileURL.isFileURL else { throw TransferFileStoreError.notRegularFile(fileURL) }
        guard expectedSize >= 0, expectedSize <= maximumFileBytes else {
            throw TransferFileStoreError.fileTooLarge(maximumBytes: maximumFileBytes, actualBytes: expectedSize)
        }
        do {
            try Task.checkCancellation()
            let manager = FileManager.default
            let attributes = try manager.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw TransferFileStoreError.notRegularFile(fileURL)
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard size == expectedSize else {
                throw TransferFileStoreError.sizeMismatch(expected: expectedSize, actual: size)
            }
            try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
            let existing = Set(try manager.contentsOfDirectory(atPath: inbox.path))
            let finalName = Self.collisionSafeName(name, existing: existing)
            let destination = inbox.appendingPathComponent(finalName)
            try Task.checkCancellation()
            // Both locations are inside the same app container: rename publishes atomically.
            try manager.moveItem(at: fileURL, to: destination)
            return SavedFile(name: finalName, url: destination, size: size)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TransferFileStoreError {
            throw error
        } catch {
            throw TransferFileStoreError.saveFailed(inbox, message: error.localizedDescription)
        }
    }

    public func save(name: String, bytes: [UInt8]) async throws -> SavedFile {
        guard Self.isSafeBasename(name) else { throw TransferFileStoreError.invalidFileName(name) }
        guard bytes.count <= maximumFileBytes else {
            throw TransferFileStoreError.fileTooLarge(maximumBytes: maximumFileBytes, actualBytes: bytes.count)
        }

        do {
            let manager = FileManager.default
            try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
            let staging = inbox.appendingPathComponent(".limlink-staging", isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            let temporary = staging.appendingPathComponent(UUID().uuidString)
            defer { try? manager.removeItem(at: temporary) }
            let existing = Set(try manager.contentsOfDirectory(atPath: inbox.path))
            let finalName = Self.collisionSafeName(name, existing: existing)
            let destination = inbox.appendingPathComponent(finalName)

            try Data(bytes).write(to: temporary, options: .atomic)
            // Publishing by moving a complete file prevents partial files from appearing in Inbox.
            // FileManager refuses an existing destination, including a racing external writer.
            try manager.moveItem(at: temporary, to: destination)
            return SavedFile(name: finalName, url: destination, size: bytes.count)
        } catch {
            throw TransferFileStoreError.saveFailed(inbox, message: error.localizedDescription)
        }
    }

    public func listSavedFiles() async throws -> [SavedFile] {
        do {
            let manager = FileManager.default
            let names: [String]
            do {
                names = try manager.contentsOfDirectory(atPath: inbox.path)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return []
            }
            var files: [SavedFile] = []
            for name in names {
                let url = inbox.appendingPathComponent(name)
                let attributes = try manager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                files.append(SavedFile(name: name, url: url, size: size))
            }
            return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            throw TransferFileStoreError.listFailed(inbox, message: error.localizedDescription)
        }
    }

    private static func isSafeBasename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func collisionSafeName(_ name: String, existing: Set<String>) -> String {
        let used = Set(existing.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        func isUnused(_ candidate: String) -> Bool {
            !used.contains(candidate.precomposedStringWithCanonicalMapping.lowercased())
        }
        // Preserve the sender's original name when no collision requires a generated name.
        if isUnused(name) { return name }
        let suggested = FileNameSafety.uniqueName(name, existing: existing)
        if suggested.utf8.count <= 255 && isUnused(suggested) { return suggested }

        let normalized = name.precomposedStringWithCanonicalMapping
        let stem: String
        let fileExtension: String
        if let dot = normalized.lastIndex(of: "."), dot != normalized.startIndex {
            stem = String(normalized[..<dot])
            fileExtension = String(normalized[dot...])
        } else {
            stem = normalized
            fileExtension = ""
        }

        var index = 1
        while true {
            let suffix = " (\(index))"
            let stemBudget = 255 - suffix.utf8.count - fileExtension.utf8.count
            let shortenedStem = utf8Prefix(stem, maximumBytes: max(0, stemBudget))
            let candidate: String
            if !shortenedStem.isEmpty {
                candidate = shortenedStem + suffix + fileExtension
            } else {
                // An unusually long extension or grapheme can consume the stem budget.
                let prefix = utf8Prefix(normalized, maximumBytes: 255 - suffix.utf8.count)
                candidate = (prefix.isEmpty ? "file" : prefix) + suffix
            }
            if isUnused(candidate) { return candidate }
            index += 1
        }
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        var result = ""
        var bytes = 0
        for character in text {
            let characterBytes = character.utf8.count
            guard bytes + characterBytes <= maximumBytes else { break }
            result.append(character)
            bytes += characterBytes
        }
        return result
    }
}
