import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum FileTransferLimits {
    public static let maximumFileBytes: Int = 5_000_000_000
    public static let maximumChunkBytes: Int = 1024 * 1024
}

public enum TransferSourceError: Error, Equatable, Sendable {
    case invalidSize
    case invalidChecksum
    case invalidRange
    case fileChanged
}

/// A file-backed source retains only its URL and metadata. Reads never exceed one transfer chunk.
public struct TransferSource: Sendable {
    public let size: Int
    public let sha256Hex: String
    private let storage: Storage

    public init(bytes: [UInt8]) {
        size = bytes.count
        var digest = IncrementalFileDigest()
        digest.update(Data(bytes))
        sha256Hex = digest.finalizeHex()
        storage = .memory(bytes)
    }

    public init(fileURL: URL, size: Int, sha256Hex: String) throws {
        guard (0...FileTransferLimits.maximumFileBytes).contains(size) else {
            throw TransferSourceError.invalidSize
        }
        guard case .success(let checksum) = FileDigest.parse(sha256Hex) else {
            throw TransferSourceError.invalidChecksum
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard fileURL.isFileURL, attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value == UInt64(size) else {
            throw TransferSourceError.fileChanged
        }
        self.size = size
        self.sha256Hex = checksum
        storage = .file(fileURL)
    }

    public func read(offset: Int, count: Int) throws -> [UInt8] {
        try Task.checkCancellation()
        guard offset >= 0, offset <= size, count >= 0,
              count <= FileTransferLimits.maximumChunkBytes, count <= size - offset else {
            throw TransferSourceError.invalidRange
        }
        switch storage {
        case .memory(let bytes):
            return Array(bytes[offset..<(offset + count)])
        case .file(let url):
            return try withFileChunkAutoreleasePool {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard try handle.seekToEnd() == UInt64(size) else { throw TransferSourceError.fileChanged }
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: count) ?? Data()
                guard data.count == count else { throw TransferSourceError.fileChanged }
                return Array(data)
            }
        }
    }

    /// Compatibility access for callers that supplied in-memory bytes; file sources stay on disk.
    var inMemoryBytes: [UInt8]? {
        guard case .memory(let bytes) = storage else { return nil }
        return bytes
    }

    private enum Storage: Sendable {
        case memory([UInt8])
        case file(URL)
    }
}

/// Incremental SHA-256 uses CryptoKit on Apple platforms and a bounded-memory fallback elsewhere.
public struct IncrementalFileDigest: Sendable {
#if canImport(CryptoKit)
    private var digest = CryptoKit.SHA256()
#else
    private var digest = SHA256.Incremental()
#endif

    public init() {}

    public mutating func update(_ data: Data) {
        digest.update(data: data)
    }

    public mutating func finalizeHex() -> String {
        SHA256.hex(Array(digest.finalize()))
    }
}

public extension FileDigest {
    static func sha256Hex(fileURL: URL) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var digest = IncrementalFileDigest()
        while true {
            let didRead = try withFileChunkAutoreleasePool {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: FileTransferLimits.maximumChunkBytes) ?? Data()
                guard !data.isEmpty else { return false }
                digest.update(data)
                return true
            }
            guard didRead else { break }
        }
        try Task.checkCancellation()
        return digest.finalizeHex()
    }
}

/// Foundation may create autoreleased objects for file reads on Apple platforms.
private func withFileChunkAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
#if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
#else
    try body()
#endif
}
