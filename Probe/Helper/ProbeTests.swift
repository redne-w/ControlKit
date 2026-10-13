import Foundation
import XCTest

/// XCTest reports many UI operation failures as issues rather than Swift errors.
/// Capture those issues at the command boundary using the public recording hook.
private final class CommandIssues: @unchecked Sendable {
    private let lock = NSLock()
    private var capturing = false
    private var message: String?

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        precondition(!capturing)
        capturing = true
        message = nil
    }

    func record(_ description: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard capturing else { return false }
        if message == nil { message = String(description.prefix(ProbeLimits.textCharacters)) }
        return true
    }

    func end() -> String? {
        lock.lock()
        defer { lock.unlock() }
        precondition(capturing)
        capturing = false
        return message
    }
}

final class ProbeTests: XCTestCase {
    private let issues = CommandIssues()

    override func record(_ issue: XCTIssue) {
        if !issues.record(issue.compactDescription) {
            super.record(issue)
        }
    }

    @MainActor
    func testServe() throws {
        let environment = ProcessInfo.processInfo.environment
        let token = environment["CONTROLKIT_PROBE_TOKEN"] ?? ""
        let appID = environment["CONTROLKIT_PROBE_APP"] ?? ""
        guard let port = UInt16(environment["CONTROLKIT_PROBE_PORT"] ?? ""), port > 0,
            (32...128).contains(token.utf8.count), !appID.isEmpty
        else {
            throw ProbeFailure("invalid_configuration", "Missing probe launch configuration.")
        }
        continueAfterFailure = true
        executionTimeAllowance = ProbeLimits.lifetimeSeconds + 60
        let app = XCUIApplication(bundleIdentifier: appID)
        let server = try ProbeServer(port: port, token: token)
        server.start()
        defer { server.stop() }
        let started = ContinuousClock.now
        var count = 0
        // This deliberately keeps XCTest alive without relaunching the application per command.
        while started.duration(to: .now) < .seconds(ProbeLimits.lifetimeSeconds) {
            let (request, failure, stopped) = server.mailbox.take()
            if let failure { throw ProbeFailure("server_failure", failure) }
            if stopped { return }
            if let request {
                guard count < ProbeLimits.commands else {
                    throw ProbeFailure("command_limit", "Probe command budget exhausted.")
                }
                count += 1
                let response = execute(request, app: app)
                server.reply(response, stop: request.operation == .stop)
            } else {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        }
        throw ProbeFailure("lifetime_limit", "Probe lifetime exhausted.")
    }

    @MainActor
    private func execute(_ request: ProbeRequest, app: XCUIApplication) -> ProbeResponse {
        let started = ContinuousClock.now
        var response: ProbeResponse
        issues.begin()
        do {
            response = try ProbeAutomation.execute(request, app: app)
        } catch {
            response = ProbeResponse(id: request.id)
            response.ok = false
            response.error =
                error as? ProbeFailure
                ?? ProbeFailure("automation_failure", String(describing: error))
        }
        if let message = issues.end() {
            response.ok = false
            response.error = ProbeFailure("automation_failure", message)
        }
        let duration = started.duration(to: .now).components
        response.elapsedMilliseconds =
            Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
        return response
    }
}
