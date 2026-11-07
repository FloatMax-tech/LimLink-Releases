import LimLinkAppSupport
import AppKit
import Combine
import Foundation

struct StoredReceiveBookmark: Equatable, Codable {
    var bookmarkData: Data
    var displayName: String
}

struct ResolvedBookmark: Equatable {
    var url: URL
    var isStale: Bool
}

enum BookmarkError: Error, Equatable {
    case unreadable
}

protocol BookmarkCodec {
    func bookmarkData(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedBookmark
}

protocol SecurityScopeAccessing {
    /// 返回 true 表示已经开始访问，用完必须 `stopAccessing`。
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

protocol ReceiveBookmarkPersisting {
    func load() -> StoredReceiveBookmark?
    func save(_ bookmark: StoredReceiveBookmark?)
}

enum ReceiveFolderSource: Equatable {
    case downloads
    case userSelection
}

struct ReceiveFolderDecision: Equatable {
    var url: URL
    var displayName: String
    var source: ReceiveFolderSource
    var notice: String?
    /// 书签过期后重建成功时，调用方应把它写回去。
    var updatedBookmark: StoredReceiveBookmark?
    /// 用户的选择。退回「下载」时也保留，盘插回来还能用。
    var retainedBookmark: StoredReceiveBookmark?
    var startedSecurityScope: Bool
}

/// An accepted offer keeps this destination even when the next offer falls back or changes folder.
final class ReceiveFolderLease {
    let url: URL
    let displayName: String
    private let scope: any SecurityScopeAccessing
    private let started: Bool

    init(decision: ReceiveFolderDecision, scope: any SecurityScopeAccessing) {
        url = decision.url
        displayName = decision.displayName
        self.scope = scope
        started = decision.source == .userSelection && scope.startAccessing(decision.url)
    }

    deinit { if started { scope.stopAccessing(url) } }
}

enum ReceiveLayout {
    /// 默认直接落在保存位置，不按会话建子文件夹（Mac 方案 4.8，总清单 #23 默认关）。
    static func incomingDirectory(
        saveLocation: URL,
        createsPerSessionSubfolder: Bool = false,
        sessionFolderName: String? = nil
    ) -> URL {
        guard createsPerSessionSubfolder, let sessionFolderName, !sessionFolderName.isEmpty else {
            return saveLocation
        }
        return saveLocation.appendingPathComponent(sessionFolderName, isDirectory: true)
    }
}

enum ReceiveFolderPolicy {
    static func fallbackNotice(folderName: String, downloadsName: String) -> String {
        L10n.text("「{0}」没有连接，暂时存到「{1}」", String(describing: folderName), String(describing: downloadsName))
    }

    /// 解析保存位置。用户选的文件夹不可用时退回「下载」，不改掉已经记住的书签。
    static func resolve(
        stored: StoredReceiveBookmark?,
        downloadsURL: URL,
        downloadsDisplayName: String,
        codec: any BookmarkCodec,
        scope: any SecurityScopeAccessing,
        isUsable: (URL) -> Bool
    ) -> ReceiveFolderDecision {
        guard let stored else {
            return downloadsDecision(
                downloadsURL: downloadsURL,
                downloadsDisplayName: downloadsDisplayName,
                notice: nil,
                retained: nil
            )
        }

        let resolved: ResolvedBookmark
        do {
            resolved = try codec.resolve(stored.bookmarkData)
        } catch {
            return downloadsDecision(
                downloadsURL: downloadsURL,
                downloadsDisplayName: downloadsDisplayName,
                notice: fallbackNotice(folderName: stored.displayName, downloadsName: downloadsDisplayName),
                retained: stored
            )
        }

        let started = scope.startAccessing(resolved.url)
        var retained = stored
        var updated: StoredReceiveBookmark?
        if resolved.isStale {
            if let renewed = try? codec.bookmarkData(for: resolved.url) {
                let fresh = StoredReceiveBookmark(bookmarkData: renewed, displayName: stored.displayName)
                retained = fresh
                updated = fresh
            }
        }

        if isUsable(resolved.url) {
            return ReceiveFolderDecision(
                url: resolved.url,
                displayName: stored.displayName,
                source: .userSelection,
                notice: nil,
                updatedBookmark: updated,
                retainedBookmark: retained,
                startedSecurityScope: started
            )
        }

        if started {
            scope.stopAccessing(resolved.url)
        }
        return downloadsDecision(
            downloadsURL: downloadsURL,
            downloadsDisplayName: downloadsDisplayName,
            notice: fallbackNotice(folderName: stored.displayName, downloadsName: downloadsDisplayName),
            retained: retained,
            updated: updated
        )
    }

    private static func downloadsDecision(
        downloadsURL: URL,
        downloadsDisplayName: String,
        notice: String?,
        retained: StoredReceiveBookmark?,
        updated: StoredReceiveBookmark? = nil
    ) -> ReceiveFolderDecision {
        ReceiveFolderDecision(
            url: downloadsURL,
            displayName: downloadsDisplayName,
            source: .downloads,
            notice: notice,
            updatedBookmark: updated,
            retainedBookmark: retained,
            startedSecurityScope: false
        )
    }
}

struct SecurityScopedBookmarkCodec: BookmarkCodec {
    func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolve(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedBookmark(url: url, isStale: stale)
    }
}

struct SystemSecurityScope: SecurityScopeAccessing {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

struct UserDefaultsBookmarkPersistence: ReceiveBookmarkPersisting {
    var defaults: UserDefaults = .standard
    var key: String = "receiveFolder.bookmark"

    func load() -> StoredReceiveBookmark? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? PropertyListDecoder().decode(StoredReceiveBookmark.self, from: data)
    }

    func save(_ bookmark: StoredReceiveBookmark?) {
        if let bookmark, let data = try? PropertyListEncoder().encode(bookmark) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

enum ReceiveFolderUsability {
    static func standard(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: url.path)
    }
}

final class ReceiveFolderStore: ObservableObject {
    @Published private(set) var decision: ReceiveFolderDecision

    private let downloadsURL: URL
    private let downloadsDisplayName: String
    private let codec: any BookmarkCodec
    private let scope: any SecurityScopeAccessing
    private let isUsable: (URL) -> Bool
    private let persistence: any ReceiveBookmarkPersisting
    private var stored: StoredReceiveBookmark?
    private var scopedURL: URL?
    private let volumeNotifications = NSWorkspace.shared.notificationCenter
    private var volumeObservers: [NSObjectProtocol] = []

    init(
        downloadsURL: URL,
        downloadsDisplayName: String,
        codec: any BookmarkCodec,
        scope: any SecurityScopeAccessing,
        isUsable: @escaping (URL) -> Bool,
        persistence: any ReceiveBookmarkPersisting
    ) {
        self.downloadsURL = downloadsURL
        self.downloadsDisplayName = downloadsDisplayName
        self.codec = codec
        self.scope = scope
        self.isUsable = isUsable
        self.persistence = persistence
        self.stored = persistence.load()
        self.decision = ReceiveFolderDecision(
            url: downloadsURL,
            displayName: downloadsDisplayName,
            source: .downloads,
            notice: nil,
            updatedBookmark: nil,
            retainedBookmark: nil,
            startedSecurityScope: false
        )
        refresh()
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            volumeNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    static func live() -> ReceiveFolderStore {
        // Received files go straight into ~/Downloads unless the user picks another folder.
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = FileManager.default.displayName(atPath: downloads.path)
        return ReceiveFolderStore(
            downloadsURL: downloads,
            downloadsDisplayName: name,
            codec: SecurityScopedBookmarkCodec(),
            scope: SystemSecurityScope(),
            isUsable: ReceiveFolderUsability.standard,
            persistence: UserDefaultsBookmarkPersistence()
        )
    }

    deinit {
        for observer in volumeObservers { volumeNotifications.removeObserver(observer) }
        if let scopedURL {
            scope.stopAccessing(scopedURL)
        }
    }

    func refresh() {
        if let scopedURL {
            scope.stopAccessing(scopedURL)
            self.scopedURL = nil
        }
        let next = ReceiveFolderPolicy.resolve(
            stored: stored,
            downloadsURL: downloadsURL,
            downloadsDisplayName: downloadsDisplayName,
            codec: codec,
            scope: scope,
            isUsable: isUsable
        )
        if let updated = next.updatedBookmark {
            stored = updated
            persistence.save(updated)
        }
        if next.startedSecurityScope {
            scopedURL = next.url
        }
        decision = next
    }

    func acquireDestination() -> ReceiveFolderLease {
        refresh()
        return ReceiveFolderLease(decision: decision, scope: scope)
    }

    func choose(folder url: URL) throws {
        let data = try codec.bookmarkData(for: url)
        let name = FileManager.default.displayName(atPath: url.path)
        let bookmark = StoredReceiveBookmark(bookmarkData: data, displayName: name)
        stored = bookmark
        persistence.save(bookmark)
        refresh()
    }

    /// 这一步收到的文件直接放进保存位置，不建会话子文件夹。
    var incomingDirectory: URL {
        ReceiveLayout.incomingDirectory(saveLocation: decision.url)
    }
}
