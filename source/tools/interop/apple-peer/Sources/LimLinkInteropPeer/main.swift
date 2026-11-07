import Foundation
import LimLinkKit

/// Development-only, loopback-only peer. Every run requires an explicit fixture decision.
@main struct InteropPeer {
    static func main() async throws {
        let arguments = CommandLine.arguments
        func option(_ name: String) throws -> String {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
                throw ProbeError.arguments("Missing \(name)")
            }
            return arguments[index + 1]
        }
        let readyURL = URL(fileURLWithPath: try option("--ready-file"))
        let inbox = URL(fileURLWithPath: try option("--inbox"), isDirectory: true)
        let decision = try option("--fixture-decision")
        guard ["accept", "reject"].contains(decision) else { throw ProbeError.arguments("Invalid fixture decision") }
        let bindingDecision = arguments.contains("--fixture-binding-decision") ? try option("--fixture-binding-decision") : nil
        if let bindingDecision, !["accept", "reject"].contains(bindingDecision) { throw ProbeError.arguments("Invalid binding fixture decision") }
        let connectionCount = arguments.contains("--connections") ? Int(try option("--connections")) : 1
        guard let connectionCount, (1...10).contains(connectionCount) else { throw ProbeError.arguments("Invalid fixture connection count") }
        let stopURL = arguments.contains("--stop-file") ? URL(fileURLWithPath: try option("--stop-file")) : nil
        let manager = FileManager.default
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let partial = inbox.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: partial) }
        let identity = try KeychainDeviceIdentity.ephemeral()
        defer { try? identity.store.delete() }
        let config = try LimLinkConfiguration.make(deviceName: "Apple interop fixture", deviceType: .mac)
        let binding: DeviceBindingController?
        if let bindingDecision {
            let store = try DeviceBindingStore(url: partial.appendingPathComponent("bindings.json"), ownFingerprint: identity.material.fingerprint.base64URL)
            let controller = DeviceBindingController(store: store, alias: "Apple interop fixture", deviceType: "mac")
            controller.onChange = { request in
                if let request { controller.decide(pairID: request.id, accept: bindingDecision == "accept") }
            }
            binding = controller
        } else { binding = nil }
        defer { binding?.onChange = nil; binding?.stop() }
        let service = SingleFileService(configuration: config, maximumRetainedSessions: 4, deviceBinding: binding,
                                        receiveDirectory: partial, maximumFileBytes: FileTransferLimits.maximumFileBytes)
        let listener = try await LimLinkListener.start(configuration: config, identity: identity.material,
                                                      trust: .acceptAndReport, scope: .loopback, advertise: nil)
        defer { listener.stop() }
        let stopMonitor = Task {
            guard let stopURL else { return }
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: stopURL.path) { listener.stop(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { stopMonitor.cancel() }
        let ready: [String: Any] = ["port": listener.port, "fingerprint": identity.material.fingerprint.base64URL]
        try JSONSerialization.data(withJSONObject: ready).write(to: readyURL, options: .atomic)
        for _ in 0..<connectionCount {
            let connection: LimLinkConnection
            do { connection = try await listener.nextConnection(timeout: .seconds(120)) }
            catch {
                if let stopURL, manager.fileExists(atPath: stopURL.path) { break }
                throw error
            }
            defer { connection.cancel() }
            service.trust(connection.peerFingerprint.base64URL)
            await service.serve(connection,
                                requestLimits: HTTPRequestLimits(maximumHeaderBytes: 16 * 1024, maximumBodyBytes: 1024 * 1024),
                                idleTimeout: .seconds(120), discardSessionsOnDisconnect: true,
                                onPending: { offer in
                let accepted = binding?.permits(peer: offer.fingerprint, bindingID: offer.bindingID) == true || decision == "accept"
                print("OFFER name=\(offer.senderName ?? "missing") bytes=\(offer.size ?? -1) accepted=\(accepted)")
                service.decide(sessionID: offer.sessionID, accept: accepted)
            }, onPublished: { file in
                guard let source = file.fileURL, file.bytes.isEmpty else { throw ProbeError.invalidPublication }
                let destination = inbox.appendingPathComponent(file.fileName)
                try FileManager.default.moveItem(at: source, to: destination)
                print("PUBLISHED bytes=\(file.size) name=\(file.fileName)")
                return file.fileName
            })
        }
    }
}

private enum ProbeError: Error { case arguments(String), invalidPublication }
