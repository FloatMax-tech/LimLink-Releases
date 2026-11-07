import CoreTransferable
import Foundation
import LimLinkAppSupport
import UniformTypeIdentifiers

enum PhotoImportError: Error { case unavailable }

/// Own the system picker's temporary file until the disk-backed sender snapshot is ready.
/// Never decode a full-resolution photo into UIImage or load its bytes as one Data value.
final class PickedPhoto: Transferable, Sendable {
    let url: URL
    private let directory: URL

    private init(url: URL, directory: URL) {
        self.url = url
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let (url, directory) = try stageReceivedFile(received.file, prefix: "photo")
            return PickedPhoto(url: url, directory: directory)
        }
    }
}

/// A file dropped onto the app (iPad drag and drop), staged the same way as a picked photo.
final class PickedFile: Transferable, Sendable {
    let url: URL
    private let directory: URL

    private init(url: URL, directory: URL) {
        self.url = url
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let (url, directory) = try stageReceivedFile(received.file, prefix: "drop")
            return PickedFile(url: url, directory: directory)
        }
    }
}

private func stageReceivedFile(_ file: URL, prefix: String) throws -> (url: URL, directory: URL) {
    try Task.checkCancellation()
    let manager = FileManager.default
    let attributes = try manager.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw TransferFileStoreError.notRegularFile(file)
    }
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size <= TransferLimits.maximumFileBytes else {
        throw TransferFileStoreError.fileTooLarge(maximumBytes: TransferLimits.maximumFileBytes, actualBytes: size)
    }
    let directory = TransferStagingDirectories.shared.outgoing
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        let destination = directory.appendingPathComponent(file.lastPathComponent)
        try manager.copyItem(at: file, to: destination)
        try Task.checkCancellation()
        return (destination, directory)
    } catch {
        try? manager.removeItem(at: directory)
        throw error
    }
}
