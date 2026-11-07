import Foundation
import XCTest
@testable import LimLinkKit
@testable import LimLinkCoreLogic

final class ApprovalDeadlineTests: XCTestCase, @unchecked Sendable {
    // Resetting the deadline on each 202 would let this transfer reach approval.
    func testRepeatedPendingResponsesCannotExtendApprovalDeadline() async throws {
        let clock = ApprovalClock()
        let peer = try ApprovalPeer(clock: clock, pendingResponses: 3, pendingStep: .seconds(40))
        do {
            _ = try await SingleFileExchange.run(
                client: makeClient(), idleTimeout: .seconds(120), now: { clock.now },
                exchange: { request, afterWake, timeout in
                    await peer.respond(request, afterWake: afterWake, timeout: timeout)
                }
            )
            XCTFail("Repeated 202 responses must exhaust the total approval budget")
        } catch TransportFailure.timedOut { }
        let polls = await peer.pollTimeouts
        XCTAssertEqual(polls, [.seconds(120), .seconds(80), .seconds(40)])
    }

    // A deadline covering hello, creation, PUT, or completion would reject this
    // valid exchange even though the approval itself takes only 30 seconds.
    func testApprovalBudgetDoesNotLimitNegotiationOrAcceptedTransfer() async throws {
        let clock = ApprovalClock()
        let peer = try ApprovalPeer(
            clock: clock, pendingResponses: 1, pendingStep: .seconds(30),
            negotiationStep: .seconds(300), transferStep: .seconds(300)
        )
        let tick = try await SingleFileExchange.run(
            client: makeClient(), idleTimeout: .seconds(90), now: { clock.now },
            exchange: { request, afterWake, timeout in
                await peer.respond(request, afterWake: afterWake, timeout: timeout)
            }
        )
        XCTAssertEqual(tick.status, .completed(finalName: "test.txt"))
        let transferTimeouts = await peer.transferTimeouts
        XCTAssertFalse(transferTimeouts.isEmpty)
        XCTAssertTrue(transferTimeouts.allSatisfy { $0 == .seconds(90) })
        let completionTimeouts = await peer.completionTimeouts
        XCTAssertEqual(completionTimeouts, [.seconds(1800)], "Final disk publication needs a separate bounded budget")
    }

    // Clamping an idle watchdog alone would let an active/trickling response
    // run forever. The complete poll operation must obey the remaining budget.
    func testInFlightApprovalPollHasTotalDeadline() async throws {
        let peer = try ApprovalPeer(clock: ApprovalClock(), pendingResponses: 0)
        do {
            _ = try await SingleFileExchange.run(
                client: makeClient(), approvalTimeout: .milliseconds(30),
                exchange: { request, afterWake, timeout in
                    if request.target.contains("?wait=") {
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    return await peer.respond(request, afterWake: afterWake, timeout: timeout)
                }
            )
            XCTFail("A poll that exceeds the approval deadline must time out")
        } catch TransportFailure.timedOut { }
    }

    func testCancellationInterruptsInFlightApprovalPoll() async throws {
        let peer = try ApprovalPeer(clock: ApprovalClock(), pendingResponses: 0)
        let polling = expectation(description: "approval poll started")
        let client = try makeClient()
        let task = Task {
            try await SingleFileExchange.run(client: client, exchange: { request, afterWake, timeout in
                if request.target.contains("?wait=") {
                    polling.fulfill()
                    try await Task.sleep(for: .seconds(30))
                }
                return await peer.respond(request, afterWake: afterWake, timeout: timeout)
            })
        }
        await fulfillment(of: [polling], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must leave the approval wait")
        } catch is CancellationError { }
    }

    func testFinalPublicationHasTotalDeadline() async throws {
        let peer = try ApprovalPeer(clock: ApprovalClock(), pendingResponses: 0)
        do {
            _ = try await SingleFileExchange.run(
                client: makeClient(), completionTimeout: .milliseconds(30),
                exchange: { request, afterWake, timeout in
                    if request.target.hasSuffix("/complete") {
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    return await peer.respond(request, afterWake: afterWake, timeout: timeout)
                }
            )
            XCTFail("Final publication must have a finite total deadline")
        } catch TransportFailure.timedOut { }
    }

    func testCancellationInterruptsFinalPublication() async throws {
        let peer = try ApprovalPeer(clock: ApprovalClock(), pendingResponses: 0)
        let publishing = expectation(description: "final publication started")
        let client = try makeClient()
        let task = Task {
            try await SingleFileExchange.run(client: client, exchange: { request, afterWake, timeout in
                if request.target.hasSuffix("/complete") {
                    publishing.fulfill()
                    try await Task.sleep(for: .seconds(30))
                }
                return await peer.respond(request, afterWake: afterWake, timeout: timeout)
            })
        }
        await fulfillment(of: [publishing], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must interrupt final publication")
        } catch is CancellationError { }
    }

    private func makeClient() throws -> SingleFileClient {
        SingleFileClient(
            local: try HostAppIdentity(app: "limlink"), localAlias: "sender",
            peerHost: "192.168.1.2", deviceName: "receiver", intent: .userTap,
            timestamp: "2026-10-16T00:00:00Z", fileID: "file", relativePath: "test.txt",
            bytes: [1, 2, 3], clientSessionKey: "approval-test"
        )
    }
}

private final class ApprovalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

// The real receiver creates, approves, receives, and completes the file. Only
// the unavailable network and passage of time are replaced by this test adapter.
private actor ApprovalPeer {
    let service: SingleFileService
    let clock: ApprovalClock
    let pendingResponses: Int
    let pendingStep: Duration
    let negotiationStep: Duration
    let transferStep: Duration
    var sessionID: String?
    var pollTimeouts: [Duration?] = []
    var transferTimeouts: [Duration?] = []
    var completionTimeouts: [Duration?] = []

    init(
        clock: ApprovalClock, pendingResponses: Int,
        pendingStep: Duration = .zero,
        negotiationStep: Duration = .zero,
        transferStep: Duration = .zero
    ) throws {
        self.clock = clock
        self.pendingResponses = pendingResponses
        self.pendingStep = pendingStep
        self.negotiationStep = negotiationStep
        self.transferStep = transferStep
        service = SingleFileService(
            configuration: try LimLinkConfiguration.make(deviceName: "receiver", deviceType: .iphone),
            trustedFingerprints: ["sender"]
        )
    }

    func respond(_ request: HTTPRequest, afterWake: Bool, timeout: Duration?) -> HTTPResponse {
        if request.target.contains("?wait=") {
            pollTimeouts.append(timeout)
            if pollTimeouts.count <= pendingResponses {
                clock.advance(by: pendingStep)
            } else if let sessionID {
                service.decide(sessionID: sessionID, accept: true)
            }
        } else if request.target.hasSuffix("/hello") || request.target.hasSuffix("/sessions") {
            clock.advance(by: negotiationStep)
        } else if request.target.hasSuffix("/complete") {
            completionTimeouts.append(timeout)
            clock.advance(by: transferStep)
        } else {
            transferTimeouts.append(timeout)
            clock.advance(by: transferStep)
        }
        let step = service.step(request, peerIsLocal: false, fingerprint: "sender")
        if request.method == "POST", request.target.hasSuffix("/sessions") {
            sessionID = JSONWire.object(step.response.body).flatMap { JSONWire.string($0, "sessionId") }
        }
        return step.response
    }
}
