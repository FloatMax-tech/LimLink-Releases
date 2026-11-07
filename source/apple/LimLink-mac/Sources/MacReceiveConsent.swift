import Foundation
import LimLinkKit
import LimLinkAppSupport

/// A display-name confirmation is valid only for the connection and metadata that produced it.
struct MacReceiveConsent {
    private struct Entry {
        var pending: PendingSession
        var connectionID: UUID
        var accepted = false
    }
    private var entries: [String: Entry] = [:]

    mutating func register(_ pending: PendingSession, connectionID: UUID) -> Bool {
        guard entries[pending.sessionID] == nil, entries.count < 4,
              let name = pending.fileName, Self.safeBasename(name),
              let size = pending.size, (0...TransferLimits.maximumFileBytes).contains(size) else { return false }
        entries[pending.sessionID] = Entry(pending: pending, connectionID: connectionID)
        return true
    }

    mutating func decide(sessionID: String, accept: Bool) {
        if accept { entries[sessionID]?.accepted = true }
        else { entries.removeValue(forKey: sessionID) }
    }

    func permits(_ file: PublishedFile, connectionID: UUID) -> Bool {
        guard let entry = entries[file.sessionID], entry.accepted else { return false }
        return entry.connectionID == connectionID && entry.pending.fingerprint == file.fingerprint
            && entry.pending.fileName == file.fileName && entry.pending.size == file.size && file.fileURL != nil
    }

    mutating func remove(sessionID: String) { entries.removeValue(forKey: sessionID) }
    mutating func disconnect(connectionID: UUID) {
        entries = entries.filter { $0.value.connectionID != connectionID }
    }

    static func safeBasename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
