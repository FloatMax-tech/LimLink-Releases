import Foundation
import LimLinkAppSupport

/// User-selected folders may live on another volume. Copy privately on that volume,
/// apply quarantine, then let the shared file store publish by a same-volume rename.
actor MacReceivedFileStore {
    private var preparedDirectories: Set<URL> = []

    func reclaimAbandonedFiles(in destination: URL) throws {
        let manager = FileManager.default
        let staging = destination.appendingPathComponent(".limlink-receive-staging", isDirectory: true)
        guard !preparedDirectories.contains(staging), manager.fileExists(atPath: staging.path) else { return }
        let type = try manager.attributesOfItem(atPath: staging.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else {
            throw TransferFileStoreError.saveFailed(destination, message: L10n.text("接收暂存位置不是普通文件夹。"))
        }
        for item in try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            if item.pathExtension == "partial", UUID(uuidString: item.deletingPathExtension().lastPathComponent) != nil {
                try manager.removeItem(at: item)
            }
        }
        preparedDirectories.insert(staging)
    }

    func save(name: String, verifiedURL: URL, size: Int, destination: URL) async throws -> SavedFile {
        guard MacReceiveConsent.safeBasename(name) else { throw TransferFileStoreError.invalidFileName(name) }
        guard (0...TransferLimits.maximumFileBytes).contains(size) else {
            throw TransferFileStoreError.fileTooLarge(maximumBytes: TransferLimits.maximumFileBytes, actualBytes: size)
        }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: verifiedURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw TransferFileStoreError.notRegularFile(verifiedURL)
        }
        let actual = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard actual == size else { throw TransferFileStoreError.sizeMismatch(expected: size, actual: actual) }
        try Task.checkCancellation()
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".limlink-receive-staging", isDirectory: true)
        if manager.fileExists(atPath: staging.path) {
            let type = try manager.attributesOfItem(atPath: staging.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else {
                throw TransferFileStoreError.saveFailed(destination, message: L10n.text("接收暂存位置不是普通文件夹。"))
            }
        } else {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try reclaimAbandonedFiles(in: destination)
        let temporary = staging.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: verifiedURL, to: temporary)
        try Task.checkCancellation()
        try QuarantineMarker.apply(to: temporary)
        let store = TransferFileStore(inbox: destination)
        return try await store.save(name: name, fileURL: temporary, expectedSize: size)
    }
}
