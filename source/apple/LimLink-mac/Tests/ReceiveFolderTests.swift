import AppKit
import XCTest

final class ReceiveFolderTests: XCTestCase {
    func testAcceptedDestinationKeepsItsScopeWhenTheNextDestinationChanges() throws {
        let codec = MemoryCodec()
        let folder = URL(fileURLWithPath: "/Volumes/First/Incoming", isDirectory: true)
        let second = URL(fileURLWithPath: "/Volumes/Second/Incoming", isDirectory: true)
        let scope = CountingScope()
        let persistence = MemoryPersistence()
        persistence.stored = StoredReceiveBookmark(bookmarkData: try codec.bookmarkData(for: folder), displayName: "First")
        let store = ReceiveFolderStore(downloadsURL: URL(fileURLWithPath: "/tmp/Downloads"), downloadsDisplayName: "Downloads",
            codec: codec, scope: scope, isUsable: { _ in true }, persistence: persistence)
        var accepted: ReceiveFolderLease? = store.acquireDestination()

        try store.choose(folder: second)

        XCTAssertEqual(accepted?.url, folder)
        XCTAssertEqual(store.decision.url, second)
        XCTAssertEqual(scope.active[folder], 1, "Refreshing future receives must not release the accepted transfer's access")
        accepted = nil
        XCTAssertEqual(scope.active[folder], 0)
    }

    func testUnmountLeavesAcceptedDestinationPinnedWhileTheNextOfferFallsBack() throws {
        let codec = MemoryCodec()
        let folder = URL(fileURLWithPath: "/Volumes/ReceiveDisk/Incoming", isDirectory: true)
        let scope = CountingScope()
        let persistence = MemoryPersistence()
        persistence.stored = StoredReceiveBookmark(bookmarkData: try codec.bookmarkData(for: folder), displayName: "ReceiveDisk")
        var connected = true
        let store = ReceiveFolderStore(downloadsURL: URL(fileURLWithPath: "/tmp/Downloads"), downloadsDisplayName: "Downloads",
            codec: codec, scope: scope, isUsable: { _ in connected }, persistence: persistence)
        let accepted = store.acquireDestination()
        connected = false

        let next = store.acquireDestination()

        XCTAssertEqual(accepted.url, folder)
        XCTAssertEqual(next.url.path, "/tmp/Downloads")
        XCTAssertEqual(scope.active[folder], 1)
        withExtendedLifetime(accepted) { }
    }

    @MainActor
    func testUnmountRefreshesNextReceiveDestinationToDownloads() async throws {
        let codec = MemoryCodec()
        let folder = URL(fileURLWithPath: "/Volumes/ReceiveDisk/Incoming", isDirectory: true)
        let persistence = MemoryPersistence()
        persistence.stored = StoredReceiveBookmark(bookmarkData: try codec.bookmarkData(for: folder), displayName: "ReceiveDisk")
        var connected = true
        let store = ReceiveFolderStore(downloadsURL: URL(fileURLWithPath: "/tmp/Downloads"), downloadsDisplayName: "Downloads",
            codec: codec, scope: MemoryScope(), isUsable: { _ in connected }, persistence: persistence)
        XCTAssertEqual(store.decision.url, folder)

        connected = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(store.decision.source, .downloads)
        XCTAssertEqual(store.decision.url.path, "/tmp/Downloads")
        XCTAssertNotNil(persistence.stored)
    }

    @MainActor
    func testMountRestoresRememberedDestinationAfterFallback() async throws {
        let codec = MemoryCodec()
        let folder = URL(fileURLWithPath: "/Volumes/ReceiveDisk/Incoming", isDirectory: true)
        let persistence = MemoryPersistence()
        persistence.stored = StoredReceiveBookmark(bookmarkData: try codec.bookmarkData(for: folder), displayName: "ReceiveDisk")
        var connected = false
        let store = ReceiveFolderStore(downloadsURL: URL(fileURLWithPath: "/tmp/Downloads"), downloadsDisplayName: "Downloads",
            codec: codec, scope: MemoryScope(), isUsable: { _ in connected }, persistence: persistence)
        XCTAssertEqual(store.decision.source, .downloads)

        connected = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(store.decision.source, .userSelection)
        XCTAssertEqual(store.decision.url, folder)
    }

    func testStaleBookmarkRenewalRunsWhileItsSecurityScopeIsActive() throws {
        let folder = URL(fileURLWithPath: "/Volumes/ReceiveDisk/Incoming", isDirectory: true)
        let scope = CountingScope()
        let codec = ScopeRequiredCodec(url: folder, scope: scope)
        let decision = ReceiveFolderPolicy.resolve(
            stored: StoredReceiveBookmark(bookmarkData: Data([1]), displayName: "ReceiveDisk"),
            downloadsURL: URL(fileURLWithPath: "/tmp/Downloads"), downloadsDisplayName: "Downloads",
            codec: codec, scope: scope, isUsable: { _ in true })

        XCTAssertNotNil(decision.updatedBookmark)
        XCTAssertEqual(decision.updatedBookmark?.bookmarkData, Data([2]))
    }

    func testNoBookmarkUsesDownloadsAndDoesNotStartSecurityScope() {
        let scope = MemoryScope()
        let downloads = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let decision = ReceiveFolderPolicy.resolve(
            stored: nil,
            downloadsURL: downloads,
            downloadsDisplayName: "下载",
            codec: MemoryCodec(),
            scope: scope,
            isUsable: { _ in true }
        )
        XCTAssertEqual(decision.source, .downloads)
        XCTAssertEqual(decision.url, downloads)
        XCTAssertEqual(decision.displayName, "下载")
        XCTAssertNil(decision.notice)
        XCTAssertNil(decision.retainedBookmark)
        XCTAssertFalse(decision.startedSecurityScope)
        XCTAssertTrue(scope.started.isEmpty)
        XCTAssertEqual(ReceiveLayout.incomingDirectory(saveLocation: decision.url), downloads)
    }

    func testDefaultLayoutDoesNotCreateSessionSubfolder() {
        let folder = URL(fileURLWithPath: "/tmp/Incoming", isDirectory: true)
        XCTAssertEqual(ReceiveLayout.incomingDirectory(saveLocation: folder), folder)
        let nested = ReceiveLayout.incomingDirectory(
            saveLocation: folder,
            createsPerSessionSubfolder: true,
            sessionFolderName: "来自 甲"
        )
        XCTAssertEqual(nested.lastPathComponent, "来自 甲")
    }

    func testUserFolderIsUsedDirectly() throws {
        let codec = MemoryCodec()
        let folder = URL(fileURLWithPath: "/Volumes/KINGSTON/收件", isDirectory: true)
        let data = try codec.bookmarkData(for: folder)
        let scope = MemoryScope()
        let decision = ReceiveFolderPolicy.resolve(
            stored: StoredReceiveBookmark(bookmarkData: data, displayName: "KINGSTON"),
            downloadsURL: URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true),
            downloadsDisplayName: "下载",
            codec: codec,
            scope: scope,
            isUsable: { _ in true }
        )
        XCTAssertEqual(decision.source, .userSelection)
        XCTAssertEqual(decision.url, folder)
        XCTAssertEqual(decision.displayName, "KINGSTON")
        XCTAssertNil(decision.notice)
        XCTAssertEqual(decision.retainedBookmark?.bookmarkData, data)
        XCTAssertNil(decision.updatedBookmark)
        XCTAssertEqual(scope.started, [folder])
        XCTAssertTrue(decision.startedSecurityScope)
        XCTAssertEqual(ReceiveLayout.incomingDirectory(saveLocation: decision.url), folder)
    }

    func testStaleBookmarkIsRenewed() throws {
        let codec = MemoryCodec()
        let folder = URL(fileURLWithPath: "/Volumes/KINGSTON/收件", isDirectory: true)
        let original = try codec.bookmarkData(for: folder)
        codec.stale.insert(original)
        let decision = ReceiveFolderPolicy.resolve(
            stored: StoredReceiveBookmark(bookmarkData: original, displayName: "KINGSTON"),
            downloadsURL: URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true),
            downloadsDisplayName: "下载",
            codec: codec,
            scope: MemoryScope(),
            isUsable: { _ in true }
        )
        let renewed = try XCTUnwrap(decision.updatedBookmark)
        XCTAssertNotEqual(renewed.bookmarkData, original)
        XCTAssertEqual(renewed.displayName, "KINGSTON")
        XCTAssertEqual(try codec.resolve(renewed.bookmarkData).url, folder)
        XCTAssertEqual(decision.source, .userSelection)
        XCTAssertEqual(decision.url, folder)
    }

    func testStaleRenewFailureStillUsesFolderWhenUsable() throws {
        let codec = MemoryCodec()
        let folder = URL(fileURLWithPath: "/Volumes/KINGSTON/收件", isDirectory: true)
        let original = try codec.bookmarkData(for: folder)
        codec.stale.insert(original)
        codec.failNextBookmark = true
        let decision = ReceiveFolderPolicy.resolve(
            stored: StoredReceiveBookmark(bookmarkData: original, displayName: "KINGSTON"),
            downloadsURL: URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true),
            downloadsDisplayName: "下载",
            codec: codec,
            scope: MemoryScope(),
            isUsable: { _ in true }
        )
        XCTAssertEqual(decision.source, .userSelection)
        XCTAssertNil(decision.updatedBookmark)
        XCTAssertEqual(decision.retainedBookmark?.bookmarkData, original)
    }

    func testUnreadableBookmarkFallsBackWithoutDeletingIt() {
        let codec = MemoryCodec()
        codec.resolveError = true
        let stored = StoredReceiveBookmark(bookmarkData: Data("gone".utf8), displayName: "KINGSTON")
        let decision = ReceiveFolderPolicy.resolve(
            stored: stored,
            downloadsURL: URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true),
            downloadsDisplayName: "下载",
            codec: codec,
            scope: MemoryScope(),
            isUsable: { _ in true }
        )
        XCTAssertEqual(decision.source, .downloads)
        XCTAssertEqual(decision.displayName, "下载")
        XCTAssertEqual(decision.notice, "「KINGSTON」没有连接，暂时存到「下载」")
        XCTAssertEqual(decision.retainedBookmark, stored)
        XCTAssertNil(decision.updatedBookmark)
        XCTAssertFalse(decision.startedSecurityScope)
    }

    func testUnusableFolderStopsSecurityScopeAndFallsBack() throws {
        let codec = MemoryCodec()
        let folder = URL(fileURLWithPath: "/Volumes/KINGSTON/收件", isDirectory: true)
        let data = try codec.bookmarkData(for: folder)
        let scope = MemoryScope()
        let decision = ReceiveFolderPolicy.resolve(
            stored: StoredReceiveBookmark(bookmarkData: data, displayName: "KINGSTON"),
            downloadsURL: URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true),
            downloadsDisplayName: "下载",
            codec: codec,
            scope: scope,
            isUsable: { _ in false }
        )
        XCTAssertEqual(decision.source, .downloads)
        XCTAssertEqual(decision.notice, "「KINGSTON」没有连接，暂时存到「下载」")
        XCTAssertEqual(scope.started, [folder])
        XCTAssertEqual(scope.stopped, [folder])
        XCTAssertFalse(decision.startedSecurityScope)
        XCTAssertEqual(decision.retainedBookmark?.bookmarkData, data)
    }

    func testStoreChoosePersistsAndFallbackDoesNotEraseBookmark() throws {
        let codec = MemoryCodec()
        let persistence = MemoryPersistence()
        let downloads = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let store = ReceiveFolderStore(
            downloadsURL: downloads,
            downloadsDisplayName: "下载",
            codec: codec,
            scope: MemoryScope(),
            isUsable: { _ in true },
            persistence: persistence
        )
        XCTAssertEqual(store.decision.source, .downloads)
        XCTAssertEqual(store.incomingDirectory, downloads)

        let folder = URL(fileURLWithPath: "/tmp/limlink-save", isDirectory: true)
        try store.choose(folder: folder)
        XCTAssertEqual(store.decision.source, .userSelection)
        XCTAssertEqual(store.decision.url, folder)
        XCTAssertEqual(store.incomingDirectory, folder)
        XCTAssertNotNil(persistence.stored)

        codec.resolveError = true
        store.refresh()
        XCTAssertEqual(store.decision.source, .downloads)
        XCTAssertEqual(store.incomingDirectory, downloads)
        XCTAssertNotNil(persistence.stored)
        XCTAssertTrue(store.decision.notice?.contains("下载") == true)
    }

    func testSecurityScopedBookmarkRoundTripWhenAvailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limlink-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let codec = SecurityScopedBookmarkCodec()
        let data: Data
        do {
            data = try codec.bookmarkData(for: directory)
        } catch {
            throw XCTSkip("安全作用域书签在这个进程里不可用：\(error)")
        }
        let resolved = try codec.resolve(data)
        XCTAssertEqual(
            resolved.url.standardizedFileURL.path,
            directory.standardizedFileURL.path
        )
    }
}

final class CountingScope: SecurityScopeAccessing {
    var active: [URL: Int] = [:]
    func startAccessing(_ url: URL) -> Bool { active[url, default: 0] += 1; return true }
    func stopAccessing(_ url: URL) { active[url, default: 0] -= 1 }
}

private struct ScopeRequiredCodec: BookmarkCodec {
    let url: URL
    let scope: CountingScope
    func bookmarkData(for url: URL) throws -> Data {
        guard scope.active[url, default: 0] > 0 else { throw BookmarkError.unreadable }
        return Data([2])
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: url, isStale: true) }
}

final class MemoryCodec: BookmarkCodec {
    var bookmarks: [Data: URL] = [:]
    var stale: Set<Data> = []
    var resolveError = false
    var failNextBookmark = false
    private var serial = 0

    func bookmarkData(for url: URL) throws -> Data {
        if failNextBookmark {
            failNextBookmark = false
            throw BookmarkError.unreadable
        }
        serial += 1
        let data = Data("bookmark-\(serial)".utf8)
        bookmarks[data] = url
        return data
    }

    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if resolveError { throw BookmarkError.unreadable }
        guard let url = bookmarks[data] else { throw BookmarkError.unreadable }
        return ResolvedBookmark(url: url, isStale: stale.contains(data))
    }
}

final class MemoryScope: SecurityScopeAccessing {
    var started: [URL] = []
    var stopped: [URL] = []

    func startAccessing(_ url: URL) -> Bool {
        started.append(url)
        return true
    }

    func stopAccessing(_ url: URL) {
        stopped.append(url)
    }
}

final class MemoryPersistence: ReceiveBookmarkPersisting {
    var stored: StoredReceiveBookmark?

    init(stored: StoredReceiveBookmark? = nil) {
        self.stored = stored
    }

    func load() -> StoredReceiveBookmark? { stored }

    func save(_ bookmark: StoredReceiveBookmark?) {
        stored = bookmark
    }
}
