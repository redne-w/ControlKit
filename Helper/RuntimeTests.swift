import Darwin
import Foundation
import XCTest

final class RuntimeIssueObserver: NSObject, XCTestObservation, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = 0
    private var latest = ""

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The most recent issue's text, bounded: it names the XCTest failure behind an uncertain
    /// outcome, which is otherwise invisible to the agent and the logs.
    var latestDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        lock.lock()
        recorded += 1
        latest = String(issue.compactDescription.prefix(300))
        lock.unlock()
    }
}

/// Lifecycle only. Production UI operations and session scheduling are separate milestones.
@MainActor
final class RuntimeTests: XCTestCase {
    func testConnection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["CONTROLKIT_LAUNCH_TOKEN"], token.utf8.count == 64,
            let portText = environment["CONTROLKIT_HOST_PORT"], let port = UInt16(portText),
            let encoded = environment["CONTROLKIT_IDENTITY"], encoded.utf8.count <= 1_024,
            let data = Data(base64Encoded: encoded),
            let identity = try? JSONDecoder().decode(WireIdentity.self, from: data),
            let deviceText = environment["SIMULATOR_UDID"],
            let device = UUID(uuidString: deviceText),
            let bundleIdentifier = environment["CONTROLKIT_APP_BUNDLE_ID"]
        else { throw WireFailure.authenticationFailed }
        continueAfterFailure = true
        let startup = ContinuousClock.now.advanced(by: .seconds(5))
        let socket = try WireListener.connect(port: port, until: startup)
        var hello = WireMessage(type: "hello", identity: identity)
        hello.token = token
        hello.capabilities = WireMessage.allCapabilities
        hello.helperPID = getpid()
        hello.simulatorUDID = device
        try socket.send(hello, limit: 4_096, until: startup)
        let ready = try socket.receive(limit: 4_096, until: startup)
        guard ready.type == "ready", ready.identity == identity,
            ready.capabilities == WireMessage.allCapabilities
        else { throw WireFailure.identityMismatch }
        let automation = try RuntimeAutomation(
            bundleIdentifier: bundleIdentifier, generation: identity.helperGeneration)
        let issues = RuntimeIssueObserver()
        XCTestObservationCenter.shared.addTestObserver(issues)
        defer { XCTestObservationCenter.shared.removeTestObserver(issues) }
        try commandLoop(socket, identity: identity, automation: automation, issues: issues)
    }

    private func commandLoop(
        _ socket: WireSocket, identity: WireIdentity, automation: RuntimeAutomation,
        issues: RuntimeIssueObserver
    ) throws {
        let lifetime = ContinuousClock.now.advanced(by: .seconds(1_800))
        var seen: Set<UUID> = []
        for _ in 0..<10_000 {
            let request = try socket.receive(limit: 65_536, until: lifetime)
            guard request.type == "request", request.identity == identity,
                let requestID = request.requestId, seen.insert(requestID).inserted,
                let remaining = request.remainingMilliseconds
            else { throw WireFailure.identityMismatch }
            let deadline = min(
                lifetime, ContinuousClock.now.advanced(by: .milliseconds(Int64(remaining))))
            var reply = WireMessage(type: "reply", identity: identity)
            reply.requestId = requestID
            reply.operation = request.operation
            var artifact: Data?
            var issueCount: Int?
            do {
                if request.operation?.hasPrefix("ui.") == true {
                    issueCount = issues.count
                    let executed = try automation.execute(request)
                    if issues.count != issueCount! {
                        throw RuntimeAutomationFailure(
                            "outcome_unknown",
                            "XCTest recorded an issue during the action: "
                                + issues.latestDescription,
                            uncertain: Self.isMutation(request.operation))
                    }
                    reply.result = executed.0
                    artifact = executed.1
                    if request.parameters?.faultDisconnectAfterDispatch == true {
                        socket.close()
                        return
                    }
                } else if request.operation == "lifecycle.attach" {
                    try automation.validateAttachment()
                    var result = UIResult()
                    result.acknowledged = true
                    reply.result = result
                }
            } catch let failure as RuntimeAutomationFailure {
                let recordedIssue = issueCount.map { issues.count != $0 } ?? false
                let uncertain =
                    failure.uncertain || recordedIssue && Self.isMutation(request.operation)
                let message =
                    recordedIssue
                    ? "XCTest recorded an issue during the action: \(issues.latestDescription)"
                    : failure.message
                reply.error = WireError(
                    code: recordedIssue ? "outcome_unknown" : failure.code,
                    message: message)
                reply.effectsUncertain = uncertain
            } catch {
                reply.error = WireError(code: "helper_failure", message: "Helper operation failed.")
                reply.effectsUncertain = Self.isMutation(request.operation)
            }
            try socket.send(reply, limit: 2 * 1_024 * 1_024, until: deadline)
            if let artifact { try socket.sendBinary(artifact, until: deadline) }
            if request.operation == "lifecycle.stop" { return }
        }
    }

    private static func isMutation(_ operation: String?) -> Bool {
        guard let operation else { return false }
        return [
            "ui.tap", "ui.type", "ui.set_text", "ui.swipe", "ui.scroll",
            "ui.system_alert.tap",
        ].contains(operation)
    }
}
