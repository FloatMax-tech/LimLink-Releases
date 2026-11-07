import Foundation
import XCTest
@testable import LimLinkCoreLogic

final class FollowupTests: XCTestCase {
    func testPartialSizeCountsAllAndExpiredOnlyClearsToZero() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = try PartialDirectory(root: root.appendingPathComponent("Partial", isDirectory: true))
        try directory.upsert(record("active", bytes: 10, activity: .transferring, since: nil, lastWrite: now), bytes: Array(repeating: 1, count: 10))
        try directory.upsert(record("paused", bytes: 4, activity: .paused, since: now.addingTimeInterval(-10 * 60), lastWrite: now), bytes: Array(repeating: 2, count: 4))
        try directory.upsert(record("expired", bytes: 7, activity: .paused, since: now.addingTimeInterval(-30 * 60), lastWrite: now), bytes: Array(repeating: 3, count: 7))
        let library = try PartialLibrary(registryURL: root.appendingPathComponent("partial-registry.json"))
        let decision = PartialPlacementDecision(
            directory: directory.root,
            volumeID: "disk",
            mode: .privateDirectory,
            fallbackReason: nil,
            targetDirectory: nil
        )
        try library.remember(decision, id: "local")
        let mounted: @Sendable (String) -> Bool = { $0 == "disk" }
        let beforeExpired = await library.partialFilesSize(expiredOnly: true, now: now, isMounted: mounted)
        let beforeTotal = await library.partialFilesSize(now: now, isMounted: mounted)
        XCTAssertEqual(beforeExpired, 7)
        XCTAssertEqual(beforeTotal, 21)
        await library.clearPartialFiles(now: now, isMounted: mounted)
        let afterExpired = await library.partialFilesSize(expiredOnly: true, now: now, isMounted: mounted)
        let afterTotal = await library.partialFilesSize(now: now, isMounted: mounted)
        XCTAssertEqual(afterExpired, 0)
        XCTAssertEqual(afterTotal, 14)
        let names = try directory.records().map(\.id).sorted()
        XCTAssertEqual(names, ["active", "paused"])
    }

    func testPartialRegistrySkipsUnmountedVolumesUntilTheyReturn() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let local = try PartialDirectory(root: root.appendingPathComponent("local", isDirectory: true))
        let external = try PartialDirectory(root: root.appendingPathComponent("ext", isDirectory: true))
        try external.upsert(record("old", bytes: 5, activity: .disconnected, since: now.addingTimeInterval(-30 * 60), lastWrite: now), bytes: Array(repeating: 9, count: 5))
        let library = try PartialLibrary(registryURL: root.appendingPathComponent("partial-registry.json"))
        try library.remember(PartialPlacementDecision(directory: local.root, volumeID: "disk", mode: .privateDirectory, fallbackReason: nil, targetDirectory: nil), id: "local")
        try library.remember(PartialPlacementDecision(directory: external.root, volumeID: "ext", mode: .targetHidden, fallbackReason: nil, targetDirectory: nil), id: "ext")
        try library.clearPartialFiles(now: now, isMounted: { $0 == "disk" })
        XCTAssertEqual(try external.records().map(\.id), ["old"])
        XCTAssertEqual(try library.partialFilesSize(expiredOnly: true, now: now, isMounted: { $0 == "disk" }), 0)
        XCTAssertEqual(try library.partialFilesSize(expiredOnly: true, now: now, isMounted: { _ in true }), 5)
        try library.clearPartialFiles(now: now, isMounted: { _ in true })
        XCTAssertEqual(try external.records(), [])
        _ = local
    }

    func testPurgeDropsPartialsAtLeast24HoursOld() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = try PartialDirectory(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try directory.upsert(record("old", bytes: 1, activity: .transferring, since: nil, lastWrite: now.addingTimeInterval(-24 * 60 * 60)), bytes: [1])
        try directory.upsert(record("fresh", bytes: 1, activity: .paused, since: now, lastWrite: now.addingTimeInterval(-24 * 60 * 60 + 1)), bytes: [2])
        try directory.purgeOlderThan24Hours(now: now)
        XCTAssertEqual(try directory.records().map(\.id), ["fresh"])
        XCTAssertTrue(PartialMaintenanceSchedule.purgesOnLaunch)
        XCTAssertTrue(PartialMaintenanceSchedule.purges(on: .willEnterForeground))
        XCTAssertTrue(PartialMaintenanceSchedule.purges(on: .didWake))
        XCTAssertFalse(PartialMaintenanceSchedule.purges(on: .didEnterBackground))
        XCTAssertFalse(PartialMaintenanceSchedule.purges(on: .willSleep))
    }

    func testSameVolumePartialStaysPrivate() {
        let support = URL(fileURLWithPath: "/tmp/limlink-support")
        let inbox = URL(fileURLWithPath: "/tmp/limlink-inbox")
        let fs = ScriptedPartialFileSystem()
        let accessed = AccessLog()
        let decision = PartialPlacement.choose(
            saveLocation: inbox,
            applicationSupport: support,
            volumeOf: { _ in VolumeIdentity(id: "disk", isMounted: true) },
            fileSystem: fs,
            beginSecurityScope: { url in
                accessed.paths.append(url.path)
                return true
            }
        )
        XCTAssertEqual(decision.mode, .privateDirectory)
        XCTAssertNil(decision.fallbackReason)
        XCTAssertTrue(decision.directory.path.contains("LimLink/Partial"))
        XCTAssertFalse(PartialFiles.isFilesVisiblePath(decision.directory.path))
        XCTAssertTrue(fs.created.isEmpty)
        XCTAssertTrue(accessed.paths.isEmpty)
    }

    func testCrossVolumeHiddenPartialWhenResumeWriteWorks() throws {
        let support = URL(fileURLWithPath: "/tmp/limlink-support")
        let external = URL(fileURLWithPath: "/Volumes/Ext/Inbox")
        let fs = ScriptedPartialFileSystem()
        let accessed = AccessLog()
        let decision = choose(support: support, save: external, fs: fs, accessed: accessed)
        XCTAssertEqual(decision.mode, .targetHidden)
        XCTAssertNil(decision.fallbackReason)
        XCTAssertEqual(decision.directory.lastPathComponent, ".limlink-partial")
        XCTAssertEqual(accessed.paths, [external.path])
        XCTAssertEqual(fs.offsetWrites.map(\.0), [1])
        let library = try PartialLibrary(registryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try library.remember(decision, id: "ext")
        let stored = try library.uses()
        XCTAssertEqual(stored.first?.mode, .targetHidden)
        XCTAssertTrue(stored.first?.path.hasSuffix(".limlink-partial") == true)
    }

    func testCrossVolumeFallsBackWhenResumeAtOffsetFails() throws {
        let support = URL(fileURLWithPath: "/tmp/limlink-support")
        let external = URL(fileURLWithPath: "/Volumes/Ext/Inbox")
        let fs = ScriptedPartialFileSystem()
        fs.fault = .resume
        let accessed = AccessLog()
        let decision = choose(support: support, save: external, fs: fs, accessed: accessed)
        XCTAssertEqual(decision.mode, .privateThenCopy)
        XCTAssertEqual(decision.fallbackReason, .resumeWriteUnsupported)
        XCTAssertTrue(decision.directory.path.contains("LimLink/Partial"))
        XCTAssertFalse(decision.directory.path.contains(".limlink-partial"))
        XCTAssertEqual(accessed.paths, [external.path])
        XCTAssertFalse(fs.created.isEmpty)
        XCTAssertTrue(fs.offsetWrites.isEmpty)

        let registryURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let library = try PartialLibrary(registryURL: registryURL)
        try library.remember(decision, id: "ext")
        let stored = try XCTUnwrap(try library.uses().first)
        XCTAssertEqual(stored.mode, .privateThenCopy)
        XCTAssertEqual(stored.fallbackReason, .resumeWriteUnsupported)
        XCTAssertEqual(stored.path, decision.directory.path)
        XCTAssertEqual(stored.targetPath, external.path)

        try PartialPlacement.copyAfterVerification(decision, bytes: [9, 9], fileName: "note.txt", fileSystem: fs)
        XCTAssertEqual(fs.copies.count, 1)
        XCTAssertEqual(fs.copies[0].1, external.appendingPathComponent("note.txt").path)
    }

    func testCrossVolumeFallsBackWhenHiddenCreateOrRenameFails() throws {
        let support = URL(fileURLWithPath: "/tmp/limlink-support")
        let external = URL(fileURLWithPath: "/Volumes/Ext/Inbox")
        let createFS = ScriptedPartialFileSystem()
        createFS.fault = .create
        let accessed = AccessLog()
        let created = choose(support: support, save: external, fs: createFS, accessed: accessed)
        XCTAssertEqual(created.mode, .privateThenCopy)
        XCTAssertEqual(created.fallbackReason, .hiddenDirectoryUnusable)

        let renameFS = ScriptedPartialFileSystem()
        renameFS.fault = .rename
        accessed.paths = []
        let renamed = choose(support: support, save: external, fs: renameFS, accessed: accessed)
        XCTAssertEqual(renamed.mode, .privateThenCopy)
        XCTAssertEqual(renamed.fallbackReason, .renameUnreliable)
        XCTAssertEqual(accessed.paths, [external.path])
        let library = try PartialLibrary(registryURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        try library.remember(renamed, id: "rename")
        XCTAssertEqual(try library.uses().first?.mode, .privateThenCopy)
        XCTAssertEqual(try library.uses().first?.path, renamed.directory.path)
    }

    func testIdleSleepPolicyFollowsInjectedPowerSource() {
        let box = PowerBox(power: .acPower)
        var session = IdleSleepActivitySession(
            policy: .preventOnACPowerOnly,
            applies: true,
            power: IdleSleepPower { box.power }
        )
        guard case .acquire(let acquired) = session.begin() else {
            return XCTFail("acquire")
        }
        XCTAssertFalse(acquired.allowsIdleSystemSleep)
        XCTAssertTrue(acquired.blocksAppNap)
        XCTAssertTrue(acquired.suddenTerminationDisabled)
        XCTAssertTrue(acquired.automaticTerminationDisabled)
        box.power = .battery
        guard case .reacquire(let onBattery) = session.powerDidChange() else {
            return XCTFail("reacquire")
        }
        XCTAssertTrue(onBattery.allowsIdleSystemSleep)
        XCTAssertTrue(onBattery.blocksAppNap)
        box.power = .acPower
        guard case .reacquire(let onAC) = session.powerDidChange() else {
            return XCTFail("back to ac")
        }
        XCTAssertFalse(onAC.allowsIdleSystemSleep)

        var allow = IdleSleepActivitySession(policy: .allow, applies: true, power: IdleSleepPower { .battery })
        guard case .acquire(let allowed) = allow.begin() else { return XCTFail("allow") }
        XCTAssertTrue(allowed.allowsIdleSystemSleep)
        XCTAssertEqual(allow.powerDidChange(), .none)

        var prevent = IdleSleepActivitySession(policy: .prevent, applies: true, power: IdleSleepPower { .battery })
        guard case .acquire(let prevented) = prevent.begin() else { return XCTFail("prevent") }
        XCTAssertFalse(prevented.allowsIdleSystemSleep)

        var ios = IdleSleepActivitySession(policy: .prevent, applies: false, power: IdleSleepPower { .battery })
        XCTAssertEqual(ios.begin(), .none)
        XCTAssertEqual(ios.powerDidChange(), .none)
    }

    private func choose(
        support: URL,
        save: URL,
        fs: ScriptedPartialFileSystem,
        accessed: AccessLog
    ) -> PartialPlacementDecision {
        PartialPlacement.choose(
            saveLocation: save,
            applicationSupport: support,
            volumeOf: { url in
                if url.path.contains("/Volumes/Ext") {
                    return VolumeIdentity(id: "ext", isMounted: true)
                }
                return VolumeIdentity(id: "disk", isMounted: true)
            },
            fileSystem: fs,
            beginSecurityScope: { url in
                accessed.paths.append(url.path)
                return true
            }
        )
    }

    private func record(
        _ id: String,
        bytes: Int,
        activity: PartialActivity,
        since: Date?,
        lastWrite: Date
    ) -> PartialFileRecord {
        PartialFileRecord(id: id, byteCount: Int64(bytes), lastWrite: lastWrite, activity: activity, since: since)
    }
}

private final class AccessLog {
    var paths: [String] = []
}

private final class PowerBox: @unchecked Sendable {
    var power: PowerSource
    init(power: PowerSource) { self.power = power }
}

private final class ScriptedPartialFileSystem: PartialFileSystem, @unchecked Sendable {
    enum Fault {
        case create
        case rename
        case resume
    }

    var fault: Fault?
    var created: [String] = []
    var offsetWrites: [(Int, String)] = []
    var copies: [(String, String)] = []
    private var files: [String: [UInt8]] = [:]

    func createDirectory(_ url: URL) throws {
        created.append(url.path)
        if fault == .create, url.lastPathComponent == PartialPlacement.hiddenDirectoryName {
            throw PartialFileSystemError.unavailable
        }
    }

    func write(_ bytes: [UInt8], to url: URL) throws {
        files[url.path] = bytes
    }

    func atomicRename(from source: URL, to destination: URL) throws {
        if fault == .rename {
            throw PartialFileSystemError.unavailable
        }
        files[destination.path] = files.removeValue(forKey: source.path) ?? []
    }

    func write(atOffset offset: Int, bytes: [UInt8], to url: URL) throws {
        if fault == .resume {
            throw PartialFileSystemError.unavailable
        }
        offsetWrites.append((offset, url.path))
        var existing = files[url.path] ?? []
        let end = offset + bytes.count
        if existing.count < end {
            existing.append(contentsOf: repeatElement(0, count: end - existing.count))
        }
        for (index, byte) in bytes.enumerated() {
            existing[offset + index] = byte
        }
        files[url.path] = existing
    }

    func remove(_ url: URL) throws {
        files[url.path] = nil
    }

    func copy(_ source: URL, to destination: URL) throws {
        copies.append((source.path, destination.path))
        files[destination.path] = files[source.path] ?? []
    }
}
