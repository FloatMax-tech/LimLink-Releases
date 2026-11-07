import Foundation

public enum FilePreviewKind: Sendable, Equatable { case image, pdf, video, audio, text, unsupported }

public struct FileTransferCompletion: Identifiable, Sendable, Equatable {
    public enum Direction: Sendable, Equatable { case sending, receiving }
    public let id = UUID()
    public let fileName: String
    public let direction: Direction
    public init(fileName: String, direction: Direction) { self.fileName = fileName; self.direction = direction }
}

public struct TextFilePreview: Sendable {
    public let text: String
    public let truncated: Bool
}

public enum FilePreviewError: Error { case unavailable, binaryText, unsupported }

/// A horizontal row swipe and the child button can receive the same release event.
/// Block that activation briefly; keep later deliberate taps and other rows independent.
public struct FileActionActivationGate: Sendable {
    private var swiping = false
    private var blockedUntil: TimeInterval?
    public init() {}
    public mutating func recordHorizontalSwipe(uptime: TimeInterval) { swiping = true }
    public mutating func endHorizontalSwipe(uptime: TimeInterval) {
        guard swiping else { return }
        swiping = false
        blockedUntil = uptime + 0.25
    }
    public func allowsActivation(uptime: TimeInterval) -> Bool {
        !swiping && (blockedUntil.map { uptime >= $0 } ?? true)
    }
}

/// Keep the original bookmarked directory's grant alive through an asynchronous file consumer.
/// A child file URL alone does not own the directory's balanced security-scope access.
public final class FileSourceAccess: Sendable {
    private let url: URL
    private let started: Bool
    public init(directory: URL) {
        url = directory
        started = directory.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

/// Offline preview routing deliberately uses the original filename, never an untrusted MIME claim.
public enum FilePreviewPolicy {
    public static let maximumTextBytes = 262_144

    public static func classify(fileName: String) -> FilePreviewKind {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif": .image
        case "pdf": .pdf
        case "mp4", "mov", "m4v", "webm", "avi", "mkv": .video
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus": .audio
        case "txt", "md", "csv", "tsv", "json", "log", "xml", "yaml", "yml", "ini", "toml",
             "swift", "kt", "java", "cs", "py", "js", "ts", "css", "html", "htm", "sh": .text
        default: .unsupported
        }
    }

    public static func readText(at url: URL) throws -> TextFilePreview {
        guard url.isFileURL,
              try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw FilePreviewError.unavailable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let source = try handle.read(upToCount: maximumTextBytes + 4) ?? Data()
        let truncated = source.count > maximumTextBytes
        var bytes = Data(source.prefix(maximumTextBytes))
        let text: String?
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let littleEndian = bytes.starts(with: [0xFF, 0xFE])
            bytes.removeFirst(2)
            if bytes.count % 2 != 0 { bytes.removeLast() }
            if truncated, bytes.count >= 2 {
                let tail = bytes.suffix(2)
                let unit = littleEndian ? UInt16(tail[tail.startIndex]) | UInt16(tail[tail.index(after: tail.startIndex)]) << 8
                    : UInt16(tail[tail.startIndex]) << 8 | UInt16(tail[tail.index(after: tail.startIndex)])
                if (0xD800...0xDBFF).contains(unit) { bytes.removeLast(2) }
            }
            text = String(data: bytes, encoding: littleEndian ? .utf16LittleEndian : .utf16BigEndian)
        } else {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
            guard !bytes.contains(0) else { throw FilePreviewError.binaryText }
            // A bounded prefix may cut through the last UTF-8 character.
            if truncated {
                for _ in 0..<3 where String(data: bytes, encoding: .utf8) == nil && !bytes.isEmpty { bytes.removeLast() }
            }
            text = String(data: bytes, encoding: .utf8)
        }
        guard let text else { throw FilePreviewError.binaryText }
        return TextFilePreview(text: text, truncated: truncated)
    }
}

/// Retains a staged selection and, when necessary, hard-links it under the original extension.
/// No payload is copied into memory and the immutable selected snapshot survives the preview.
public final class FilePreviewLease: Sendable {
    public let url: URL
    public let originalURL: URL
    private let selection: TransferFile?
    private let ownedDirectory: URL?
    private let scopedURL: URL?
    private let sourceAccess: FileSourceAccess?

    public convenience init(file: TransferFile) throws {
        guard let url = file.url else { throw FilePreviewError.unavailable }
        try self.init(url: url, name: file.name, holding: file, originalURL: file.originalURL)
    }

    public init(url: URL, name: String, holding: TransferFile? = nil, originalURL: URL? = nil, accessRoot: URL? = nil) throws {
        guard url.isFileURL, !name.isEmpty, name != ".", name != "..",
              (name as NSString).lastPathComponent == name, !name.contains("\\"), !name.contains("\0") else {
            throw FilePreviewError.unavailable
        }
        let sourceAccess = accessRoot.map { FileSourceAccess(directory: $0) }
        let access = url.startAccessingSecurityScopedResource()
        var kept = false
        defer { if access && !kept { url.stopAccessingSecurityScopedResource() } }
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw FilePreviewError.unavailable
        }
        self.selection = holding
        self.sourceAccess = sourceAccess
        self.originalURL = originalURL ?? url
        self.scopedURL = access ? url : nil
        if url.lastPathComponent == name {
            self.url = url
            ownedDirectory = nil
        } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LimLink-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                let target = folder.appendingPathComponent(name)
                try FileManager.default.linkItem(at: url, to: target)
                self.url = target
                ownedDirectory = folder
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        kept = true
    }

    deinit {
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        withExtendedLifetime(selection) { }
        withExtendedLifetime(sourceAccess) { }
    }
}

/// Persist the pending state before export: a restart must not automatically duplicate an asset
/// if Photos committed it just before the process exited. An explicit retry is a separate action.
public struct PhotoExportGate: Sendable {
    public private(set) var snapshot: [String: String]
    public init(snapshot: [String: String] = [:]) { self.snapshot = snapshot }
    public mutating func begin(_ key: String, retryPending: Bool = false) -> Bool {
        if let value = snapshot[key], !(retryPending && value == "pending") { return false }
        snapshot[key] = "pending"
        return true
    }
    public mutating func saved(_ key: String, assetIdentifier: String) {
        guard !assetIdentifier.isEmpty else { failed(key); return }
        snapshot[key] = "asset:" + assetIdentifier
    }
    public mutating func failed(_ key: String) { snapshot.removeValue(forKey: key) }
    public func assetIdentifier(for key: String) -> String? {
        guard let value = snapshot[key], value.hasPrefix("asset:") else { return nil }
        return String(value.dropFirst(6))
    }
    public func isPending(_ key: String) -> Bool { snapshot[key] == "pending" }
}
