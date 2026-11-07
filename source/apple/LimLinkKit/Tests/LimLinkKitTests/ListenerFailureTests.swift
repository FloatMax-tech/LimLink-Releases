import Foundation
import Network
import XCTest
@testable import LimLinkKit
@testable import LimLinkCoreLogic

final class ListenerFailureTests: XCTestCase {
    func testTerminalFailureEndsQueuedAndFutureConnectionWaits() async throws {
        let (endpoint, listener) = try makeListener()
        let expected = TransportFailure.posix(Int32(ENETDOWN))
        do {
            let _: LimLinkConnection = try await withCheckedThrowingContinuation { continuation in
                endpoint.enqueue(OnceContinuation(continuation))
                listener.stateUpdateHandler?(.failed(.posix(.ENETDOWN)))
                // Also cleans up the pre-fix waiter without a hanging failing test.
                endpoint.stop()
            }
            XCTFail("A terminal listener failure must fail the waiting consumer")
        } catch {
            XCTAssertEqual(error as? TransportFailure, expected)
        }
        await assertNextFailure(endpoint, equals: expected)
    }

    func testFailureBeforeConsumerWaitIsRemembered() async throws {
        let (endpoint, listener) = try makeListener()
        defer { endpoint.stop() }
        listener.stateUpdateHandler?(.failed(.posix(.ENETDOWN)))
        await assertNextFailure(endpoint, equals: .posix(Int32(ENETDOWN)))
    }

    func testCancelledListenerCannotAcceptAnotherWait() async throws {
        let (endpoint, listener) = try makeListener()
        defer { endpoint.stop() }
        listener.stateUpdateHandler?(.cancelled)
        await assertNextFailure(endpoint, equals: .cancelled)
    }

    func testTransientStatesDoNotReplaceTerminalFailure() async throws {
        let (endpoint, listener) = try makeListener()
        defer { endpoint.stop() }
        listener.stateUpdateHandler?(.waiting(.posix(.EHOSTUNREACH)))
        listener.stateUpdateHandler?(.ready)
        listener.stateUpdateHandler?(.failed(.posix(.ENETDOWN)))
        listener.stateUpdateHandler?(.cancelled)
        await assertNextFailure(endpoint, equals: .posix(Int32(ENETDOWN)))
    }

    func testStoppedListenerRejectsFutureWaitsImmediately() async throws {
        let (endpoint, _) = try makeListener()
        endpoint.stop()
        await assertNextFailure(endpoint, equals: .cancelled)
    }

    private func assertNextFailure(_ endpoint: LimLinkListener, equals expected: TransportFailure) async {
        do {
            _ = try await endpoint.nextConnection(timeout: .milliseconds(50))
            XCTFail("A terminated listener must not return a connection")
        } catch {
            XCTAssertEqual(error as? TransportFailure, expected)
        }
    }

    private func makeListener() throws -> (LimLinkListener, NWListener) {
        // Construction and state delivery need no socket bind or Local Network permission.
        let listener = try NWListener(using: .tcp)
        let endpoint = LimLinkListener(
            port: 52470, portDiagnostic: .primary,
            configuration: try LimLinkConfiguration.make(deviceName: "receiver", deviceType: .mac),
            listener: listener, queue: DispatchQueue(label: "limlink.test.listener-state"),
            probe: VerifyProbe(), advertisedFingerprint: "unused", advertising: nil, inviting: false
        )
        return (endpoint, listener)
    }
}
