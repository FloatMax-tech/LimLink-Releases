import Foundation
import XCTest
import Security
import LimLinkKit
import LimLinkAppSupport

final class MacTransferIntegrationTests: XCTestCase {
    func testMacFilePublicationCompletesRealMutualTLSAfterConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacTransferIntegration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Cloud's test worker has no unlocked login keychain. Isolate the real TLS
        // identities in a fresh, disposable keychain instead of requiring user UI.
        let keychain = try IntegrationKeychain(directory: root)
        defer { keychain.close() }
        let sourceURL = root.appendingPathComponent("source.bin")
        let contents = Data(repeating: 0x53, count: 2_097_169)
        try contents.write(to: sourceURL)
        let sourceStore = TransferFileStore(inbox: root, outgoingDirectory: root.appendingPathComponent("outgoing"))
        let file = try await sourceStore.load(sourceURL)
        let server = try KeychainDeviceIdentity.ephemeral()
        defer { try? server.store.delete() }
        let clientIdentity = try KeychainDeviceIdentity.ephemeral()
        defer { try? clientIdentity.store.delete() }
        let configuration = try LimLinkConfiguration.make(deviceName: "Mac receiver", deviceType: .mac)
        let staging = root.appendingPathComponent("incoming")
        let destination = root.appendingPathComponent("saved")
        let receiver = SingleFileService(configuration: configuration, maximumRetainedSessions: 4,
            receiveDirectory: staging, maximumFileBytes: 5_000_000_000)
        receiver.trust(clientIdentity.material.fingerprint.base64URL)
        let listener = try await LimLinkListener.start(configuration: configuration, identity: server.material,
            trust: .allowListed([clientIdentity.material.fingerprint]), scope: .loopback, advertise: nil)
        defer { listener.stop() }
        let consent = IntegrationConsent()
        let connectionID = UUID()
        let publisher = MacReceivedFileStore()
        let serverTask = Task {
            let incoming = try await listener.nextConnection(timeout: .seconds(10))
            defer { incoming.cancel() }
            await receiver.serve(incoming,
                requestLimits: HTTPRequestLimits(maximumHeaderBytes: 16 * 1_024, maximumBodyBytes: 1_048_576),
                idleTimeout: .seconds(20), discardSessionsOnDisconnect: true,
                onPending: { pending in
                    XCTAssertEqual(pending.senderName, "测试 iPad")
                    XCTAssertEqual(pending.size, 2_097_169)
                    XCTAssertTrue(consent.accept(pending, connectionID: connectionID))
                    XCTAssertTrue(receiver.decide(sessionID: pending.sessionID, accept: true))
                },
                onPublished: { published in
                    XCTAssertTrue(consent.permits(published, connectionID: connectionID))
                    XCTAssertTrue(published.bytes.isEmpty)
                    let url = try XCTUnwrap(published.fileURL)
                    let saved = try await publisher.save(name: published.fileName, verifiedURL: url,
                        size: published.size, destination: destination)
                    XCTAssertEqual(try Data(contentsOf: saved.url), contents)
                    return saved.name
                })
        }
        defer { serverTask.cancel() }
        let outgoing = try await LimLinkConnection.connect(host: "127.0.0.1", port: listener.port,
            identity: clientIdentity.material, trust: .allowListed([server.material.fingerprint]), scope: .loopback)
        defer { outgoing.cancel() }
        let client = SingleFileClient(local: configuration.hostApp, localAlias: "测试 iPad", localDevType: "ipad",
            peerHost: "127.0.0.1", deviceName: "Mac receiver", intent: .userTap,
            timestamp: DiagnosticTimestamps.format(Date()), fileID: "mac-regression",
            relativePath: "received.bin", source: file.source, clientSessionKey: UUID().uuidString)
        let result = try await SingleFileExchange.run(connection: outgoing, client: client,
            responseLimits: HTTPResponseLimits(maximumHeaderBytes: 16 * 1_024, maximumBodyBytes: 64 * 1_024),
            idleTimeout: .seconds(20))
        XCTAssertEqual(result.status, .completed(finalName: "received.bin"))
        XCTAssertEqual(result.bytesSent, 2_097_169)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("received.bin")), contents)
        outgoing.cancel()
        try await serverTask.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }
}

private final class IntegrationConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var consent = MacReceiveConsent()
    func accept(_ pending: PendingSession, connectionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let registered = consent.register(pending, connectionID: connectionID)
        consent.decide(sessionID: pending.sessionID, accept: registered)
        return registered
    }
    func permits(_ file: PublishedFile, connectionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return consent.permits(file, connectionID: connectionID)
    }
}

/// Test-only fixture. Restores the worker's prior default and search list.
private final class IntegrationKeychain {
    private var previous: SecKeychain?
    private var searchList: CFArray?
    private var temporary: SecKeychain?

    init(directory: URL) throws {
        SecKeychainCopyDefault(&previous)
        SecKeychainCopySearchList(&searchList)
        let password = UUID().uuidString
        let path = directory.appendingPathComponent("tls-test.keychain").path
        let status = password.withCString { bytes in
            SecKeychainCreate(path, UInt32(password.utf8.count), bytes, false, nil, &temporary)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let result = SecKeychainSetDefault(temporary)
        guard result == errSecSuccess else {
            close()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        // Setting the default controls writes, but does not add it to the search
        // list used when Security reconstructs an identity from its key/certificate.
        guard let temporary else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInvalidKeychain)) }
        let searchable = SecKeychainSetSearchList([temporary] as CFArray)
        guard searchable == errSecSuccess else {
            close()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(searchable))
        }
    }

    func close() {
        guard let temporary else { return }
        SecKeychainSetDefault(previous)
        if let searchList { SecKeychainSetSearchList(searchList) }
        SecKeychainDelete(temporary)
        self.temporary = nil
    }
}
