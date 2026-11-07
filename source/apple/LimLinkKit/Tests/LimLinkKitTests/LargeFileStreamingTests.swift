import CryptoKit
import Foundation
import Security
import XCTest
@testable import LimLinkKit
@testable import LimLinkCoreLogic

/// Real Network.framework mutual TLS, consent, file-backed receiving, and durable publication.
final class LargeFileStreamingTests: XCTestCase, @unchecked Sendable {
    func testThirtyTwoMiBFileStreamsOverMutualTLSWithExplicitConsent() async throws {
        // The tail exercises the last PUT independently of full-size chunks.
        try await transferFile(size: 32 * 1_024 * 1_024 + 17, sparse: false)
    }

    func testExactlyFiveBillionBytesStreamOverMutualTLSWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["LIMLINK_TEST_5GB"] == "1" else {
            throw XCTSkip("Set LIMLINK_TEST_5GB=1 to transmit and verify exactly 5,000,000,000 bytes over mutual TLS.")
        }
        try await transferFile(size: 5_000_000_000, sparse: true)
    }

    private func transferFile(size: Int, sparse: Bool) async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("LimLinkLargeFile-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try manager.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove large-file test directory: \(error)")
            }
            XCTAssertFalse(manager.fileExists(atPath: directory.path))
        }
        let attributes = try manager.attributesOfFileSystem(forPath: directory.path)
        let freeBytes = try XCTUnwrap(attributes[.systemFreeSize] as? NSNumber).int64Value
        let requiredBytes = Int64(size) * 2 + 256 * 1_024 * 1_024
        guard freeBytes >= requiredBytes else {
            throw LargeFileTestFailure.insufficientDiskSpace(required: requiredBytes, available: freeBytes)
        }
        let sourceURL = directory.appendingPathComponent("source.bin")
        let receiveDirectory = directory.appendingPathComponent("partial", isDirectory: true)
        let savedName = "received large file (1).bin"
        let savedURL = directory.appendingPathComponent(savedName)
        try manager.createDirectory(at: receiveDirectory, withIntermediateDirectories: true)
        let expectedDigest = try makeFixture(at: sourceURL, size: size, sparse: sparse)
        let sourceDigest = try FileDigest.sha256Hex(fileURL: sourceURL)
        XCTAssertEqual(sourceDigest, expectedDigest, "The production streaming digest must match CryptoKit.")
        let source = try TransferSource(fileURL: sourceURL, size: size, sha256Hex: sourceDigest)
        let server = try largeFileTestIdentity()
        defer { try? server.store.delete() }
        let sender = try largeFileTestIdentity()
        defer { try? sender.store.delete() }
        let senderAlias = "大文件发送者 Mac"
        let configuration = try LimLinkConfiguration.make(deviceName: "large-file-receiver", deviceType: .mac)
        let observations = LargeFileObservations()
        let service = SingleFileService(
            configuration: configuration,
            trustedFingerprints: [sender.material.fingerprint.base64URL],
            receiveDirectory: receiveDirectory,
            maximumFileBytes: 5_000_000_000
        )
        let listener = try await LimLinkListener.start(
            configuration: configuration,
            identity: server.material,
            trust: .allowListed([sender.material.fingerprint]),
            scope: .loopback,
            advertise: nil,
            timeout: .seconds(5)
        )
        defer { listener.stop() }
        let serve = Task {
            let inbound = try await listener.nextConnection()
            defer { inbound.cancel() }
            XCTAssertEqual(inbound.negotiatedVersionRaw, LimLinkProtocol.tls13WireVersion)
            XCTAssertEqual(inbound.peerFingerprint, sender.material.fingerprint)
            XCTAssertTrue(inbound.verifyObservation.sawCertificate)
            await service.serve(
                inbound,
                requestLimits: HTTPRequestLimits(maximumHeaderBytes: 16 * 1_024, maximumBodyBytes: 1_024 * 1_024),
                idleTimeout: .seconds(60),
                discardSessionsOnDisconnect: true,
                onPending: { offer in
                    observations.record(offer)
                    XCTAssertEqual(offer.senderName, senderAlias)
                    XCTAssertEqual(offer.fileName, "large file.bin")
                    XCTAssertEqual(offer.size, size)
                    XCTAssertEqual(offer.fingerprint, sender.material.fingerprint.base64URL)
                    // TLS trust alone does not accept the offer: the host explicitly decides here.
                    let accepted = service.decide(sessionID: offer.sessionID, accept: true)
                    XCTAssertTrue(accepted)
                    observations.recordDecision(accepted)
                },
                onPublished: { file in
                    let publicationManager = FileManager.default
                    XCTAssertTrue(observations.approved)
                    XCTAssertTrue(file.bytes.isEmpty, "A file-backed receiver must not publish a whole-file byte array.")
                    XCTAssertEqual(file.size, size)
                    XCTAssertEqual(file.fileName, "large file.bin")
                    XCTAssertEqual(file.fingerprint, sender.material.fingerprint.base64URL)
                    let receivedURL = try XCTUnwrap(file.fileURL)
                    XCTAssertEqual(receivedURL.deletingLastPathComponent().standardizedFileURL, receiveDirectory.standardizedFileURL)
                    let receivedSize = try publicationManager.attributesOfItem(atPath: receivedURL.path)[.size] as? NSNumber
                    XCTAssertEqual(receivedSize?.intValue, size)
                    let digest = try compareAndHashFiles(source: sourceURL, received: receivedURL)
                    XCTAssertEqual(digest, expectedDigest)
                    try publicationManager.moveItem(at: receivedURL, to: savedURL)
                    observations.recordPublication(file, digest: digest)
                    return savedName
                }
            )
        }
        defer { serve.cancel() }
        let outbound = try await LimLinkConnection.connect(
            host: "127.0.0.1",
            port: listener.port,
            identity: sender.material,
            trust: .allowListed([server.material.fingerprint]),
            scope: .loopback,
            timeout: .seconds(5)
        )
        defer { outbound.cancel() }
        XCTAssertEqual(outbound.negotiatedVersionRaw, LimLinkProtocol.tls13WireVersion)
        XCTAssertEqual(outbound.peerFingerprint, server.material.fingerprint)
        XCTAssertTrue(outbound.verifyObservation.sawCertificate)
        XCTAssertEqual(FileTransferLimits.maximumFileBytes, 5_000_000_000)
        XCTAssertEqual(FileTransferLimits.maximumChunkBytes, 1_024 * 1_024)
        let client = SingleFileClient(
            local: configuration.hostApp,
            localAlias: senderAlias,
            localDevType: "mac",
            peerHost: "127.0.0.1",
            deviceName: configuration.deviceName,
            intent: .userTap,
            timestamp: "2026-10-18T00:00:00Z",
            fileID: "large-file",
            relativePath: "large file.bin",
            source: source,
            clientSessionKey: UUID().uuidString
        )
        let started = Date()
        print("LIMLINK_LARGE_FILE_BEGIN bytes=\(size) sha256=\(expectedDigest) freeBytes=\(freeBytes)")
        let result = try await SingleFileExchange.run(
            connection: outbound,
            client: client,
            responseLimits: HTTPResponseLimits(maximumHeaderBytes: 16 * 1_024, maximumBodyBytes: 1_024 * 1_024),
            idleTimeout: .seconds(60),
            onTick: { tick in observations.record(tick) }
        )
        XCTAssertEqual(result.status, .completed(finalName: savedName))
        XCTAssertEqual(result.bytesSent, size)
        XCTAssertEqual(result.bytesTotal, size)
        outbound.cancel()
        try await serve.value
        let snapshot = observations.snapshot
        XCTAssertEqual(snapshot.pendingCount, 1)
        XCTAssertEqual(snapshot.publicationCount, 1)
        XCTAssertTrue(snapshot.approved)
        XCTAssertFalse(snapshot.uploadedBeforeApproval)
        XCTAssertTrue(snapshot.offsetsWereContiguous)
        XCTAssertEqual(snapshot.uploadedBytes, size)
        XCTAssertEqual(snapshot.maximumBodyBytes, 1_024 * 1_024)
        XCTAssertEqual(snapshot.uploadCount, (size + 1_024 * 1_024 - 1) / (1_024 * 1_024))
        XCTAssertEqual(snapshot.digest, expectedDigest)
        XCTAssertEqual(snapshot.pendingSessionID, snapshot.publishedSessionID)
        XCTAssertTrue(manager.fileExists(atPath: savedURL.path))
        XCTAssertEqual(try manager.attributesOfItem(atPath: savedURL.path)[.size] as? NSNumber, NSNumber(value: size))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: receiveDirectory.path), [], "Disconnect must remove owned partial files.")
        print("LIMLINK_LARGE_FILE_PASS bytes=\(snapshot.uploadedBytes) puts=\(snapshot.uploadCount) maxBody=\(snapshot.maximumBodyBytes) sha256=\(expectedDigest) seconds=\(String(format: "%.3f", Date().timeIntervalSince(started)))")
    }
}

/// An optional 5 GB sparse fixture avoids allocating a second physical 5 GB file.
/// All bytes are still read, sent through TLS, written, compared, and hashed.
private func makeFixture(at url: URL, size: Int, sparse: Bool) throws -> String {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw LargeFileTestFailure.cannotCreateFixture
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    if sparse {
        try handle.truncate(atOffset: UInt64(size))
        try handle.synchronize()
        return try independentDigest(of: url)
    }
    var digest = CryptoKit.SHA256()
    var block = Data((0..<(1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
    var offset = 0
    while offset < size {
        let count = min(block.count, size - offset)
        var marker = UInt64(offset).littleEndian
        withUnsafeBytes(of: &marker) { markerBytes in
            block.replaceSubrange(0..<markerBytes.count, with: markerBytes)
        }
        let bytes = block.prefix(count)
        try handle.write(contentsOf: bytes)
        digest.update(data: bytes)
        offset += count
    }
    try handle.synchronize()
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func independentDigest(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = CryptoKit.SHA256()
    while true {
        let hasMore = try autoreleasepool {
            let bytes = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !bytes.isEmpty else { return false }
            digest.update(data: bytes)
            return true
        }
        if !hasMore { break }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func compareAndHashFiles(source: URL, received: URL) throws -> String {
    let original = try FileHandle(forReadingFrom: source)
    defer { try? original.close() }
    let destination = try FileHandle(forReadingFrom: received)
    defer { try? destination.close() }
    var digest = CryptoKit.SHA256()
    var offset = 0
    while true {
        let hasMore = try autoreleasepool {
            let expected = try original.read(upToCount: 1_024 * 1_024) ?? Data()
            let actual = try destination.read(upToCount: 1_024 * 1_024) ?? Data()
            guard expected == actual else { throw LargeFileTestFailure.contentMismatch(offset: offset) }
            guard !actual.isEmpty else { return false }
            digest.update(data: actual)
            offset += actual.count
            return true
        }
        if !hasMore { break }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func largeFileTestIdentity() throws -> (material: IdentityMaterial, store: KeychainDeviceIdentity) {
    do {
        return try KeychainDeviceIdentity.ephemeral(deviceType: .mac)
    } catch {
        #if os(iOS) && targetEnvironment(simulator)
        if let failure = error as? TransportFailure,
           failure == .keychain(errSecMissingEntitlement) || failure == .identityKey(errSecMissingEntitlement) {
            throw XCTSkip("The simulator test host lacks Keychain entitlements; run real TLS coverage on a signed host or macOS.")
        }
        #endif
        throw error
    }
}

private enum LargeFileTestFailure: Error {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case cannotCreateFixture
    case contentMismatch(offset: Int)
}

/// Counters retain no HTTP bodies or file contents as the transfer grows.
private final class LargeFileObservations: @unchecked Sendable {
    struct Snapshot {
        var pendingCount = 0
        var publicationCount = 0
        var approved = false
        var uploadedBeforeApproval = false
        var offsetsWereContiguous = true
        var uploadedBytes = 0
        var uploadCount = 0
        var maximumBodyBytes = 0
        var digest: String?
        var pendingSessionID: String?
        var publishedSessionID: String?
    }

    private let lock = NSLock()
    private var storage = Snapshot()

    var snapshot: Snapshot { lock.withLock { storage } }
    var approved: Bool { lock.withLock { storage.approved } }

    func record(_ offer: PendingSession) {
        lock.withLock {
            storage.pendingCount += 1
            storage.pendingSessionID = offer.sessionID
        }
    }

    func recordDecision(_ accepted: Bool) {
        lock.withLock { storage.approved = accepted }
    }

    func record(_ tick: SingleFileClientTick) {
        guard let request = tick.request, request.method == "PUT" else { return }
        lock.withLock {
            storage.uploadedBeforeApproval = storage.uploadedBeforeApproval || !storage.approved
            storage.offsetsWereContiguous = storage.offsetsWereContiguous
                && request.value(for: "x-limlink-offset") == String(storage.uploadedBytes)
            storage.uploadedBytes += request.body.count
            storage.uploadCount += 1
            storage.maximumBodyBytes = max(storage.maximumBodyBytes, request.body.count)
        }
    }

    func recordPublication(_ file: PublishedFile, digest: String) {
        lock.withLock {
            storage.publicationCount += 1
            storage.publishedSessionID = file.sessionID
            storage.digest = digest
        }
    }
}
