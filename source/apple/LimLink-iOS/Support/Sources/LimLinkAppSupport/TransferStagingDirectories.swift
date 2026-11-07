import Foundation

/// Process-owned temporary locations for uncommitted outgoing and incoming files.
public struct TransferStagingDirectories: Sendable {
    /// Initialize once, before any selected file or receiver creates a staging lease.
    /// Subsequent stores and listener generations must reuse this value.
    public static let shared = TransferStagingDirectories()

    public let outgoing: URL
    public let incoming: URL

    /// Reclaims abandoned data from a previous process in the two reserved roots only.
    /// Call once at startup, before creating any staging files; calling this again with
    /// the same base while transfers are active would remove their files. Production
    /// callers should use `shared`; explicit bases support isolated hosts and tests.
    /// Cleanup is best effort, and stores create their directories lazily when needed.
    public init(baseDirectory: URL = FileManager.default.temporaryDirectory) {
        outgoing = baseDirectory.appendingPathComponent("LimLinkOutgoing", isDirectory: true)
        incoming = baseDirectory.appendingPathComponent("LimLinkIncoming", isDirectory: true)
        guard baseDirectory.isFileURL else { return }
        for directory in [outgoing, incoming] {
            // Removing the root itself unlinks a symbolic link without following it.
            // No enumeration of the base or deletion of sibling user files is needed.
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
