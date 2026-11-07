import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns only a random private staging path. A host may move the verified file elsewhere;
/// cleanup never follows that move or derives a path from peer-controlled metadata.
final class DiskReceiveFile {
    let url: URL
    private let handle: FileHandle

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("limlink-\(UUID().uuidString).partial")
        let descriptor = url.path.withCString { open($0, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #if os(iOS) || os(macOS)
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
        #endif
    }

    func append(_ bytes: [UInt8], offset: Int) throws {
        try withDiskWriteAutoreleasePool {
            guard try handle.seekToEnd() == UInt64(offset) else { throw POSIXError(.EIO) }
            try handle.write(contentsOf: Data(bytes))
            // Only report this offset after the chunk reaches durable storage.
            try handle.synchronize()
        }
    }

    func reset() throws {
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.synchronize()
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

private func withDiskWriteAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
    #else
    try body()
    #endif
}
