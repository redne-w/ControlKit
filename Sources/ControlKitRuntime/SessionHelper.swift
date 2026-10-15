import ControlKitProcess
import ControlKitWire
import Foundation

package struct SessionHelper {
    package let identity: WireIdentity
    let socket: WireSocket
    let process: OwnedProcess
    let runner: RunnerIdentity
    package let runtime: PrivateDirectory

    package static func start(
        source: URL, cache: URL, device: SimulatorDevice, app: String, epoch: UUID,
        session: UUID, generation: UInt64, launch launchID: UUID, tools: AppleTools,
        runtimeRoot: PrivateDirectory, budget suppliedBudget: OperationBudget? = nil
    ) throws -> Self {
        let budget = suppliedBudget ?? OperationBudget(milliseconds: 120_000)
        try validateRuntimeText(app)
        let cached = try HelperCache.prepare(
            source: source, cache: cache, tools: tools, budget: budget)
        let runtime = try SessionRetention.reserve(
            launchID, in: runtimeRoot, until: budget.end)
        let listener = try WireListener()
        let identity = WireIdentity(
            epoch: epoch, session: session, generation: generation, launch: launchID)
        let token = try HelperConfiguration.token()
        let config = try HelperConfiguration.write(
            cached: cached, runtime: runtime, identity: identity, token: token,
            port: listener.port, appBundleIdentifier: app)
        let process = try launch(
            config: config, runtime: runtime, device: device.udid, tools: tools)
        let authenticated: (socket: WireSocket, runner: RunnerIdentity)
        do {
            authenticated = try authenticate(
                listener: listener, identity: identity, token: token, device: device,
                process: process, deadline: budget.end)
        } catch {
            listener.close()
            process.cancel()
            let exit = try? process.wait()
            // The XCTest runner's own output is not retained; its result bundle stays here.
            DiagnosticLog.failure(
                "helper.start_failed", error,
                [
                    "session": session.uuidString, "generation": "\(generation)",
                    "runnerReason": exit?.reason.rawValue ?? "unknown",
                    "runnerExitCode": exit?.exitCode.map { "\($0)" } ?? "none",
                    "resultBundle": runtime.url.appendingPathComponent("result.xcresult").path,
                ])
            throw RuntimeFailure(
                "retirement_unconfirmed",
                "Helper startup failed before authenticated runner retirement could be proven.")
        }
        let helper = Self(
            identity: identity, socket: authenticated.socket, process: process,
            runner: authenticated.runner, runtime: runtime)
        do {
            let attached = try helper.execute(
                requestID: UUID(), operation: "lifecycle.attach", parameters: nil,
                deadline: min(budget.end, .now.advanced(by: .seconds(5))))
            if let refused = attached.0.error {
                DiagnosticLog.record(
                    "helper.attach_refused",
                    [
                        "session": session.uuidString, "code": refused.code,
                        "message": refused.message,
                    ])
                throw RuntimeFailure("app_not_foreground", "Target app is not foreground.")
            }
        } catch {
            DiagnosticLog.failure("helper.attach_failed", error, ["session": session.uuidString])
            try helper.retire(graceSeconds: 5)
            throw error
        }
        return helper
    }

    package func execute(
        requestID: UUID, operation: String, parameters: UIParameters?,
        deadline: ContinuousClock.Instant, cancelled: () -> Bool = { false }
    ) throws -> (WireMessage, Data?) {
        let remaining = try milliseconds(until: deadline)
        var request = WireMessage(type: "request", identity: identity)
        request.requestId = requestID
        request.operation = operation
        request.remainingMilliseconds = remaining
        request.parameters = parameters
        let progress = {
            if cancelled() {
                throw RuntimeFailure("cancelled", "Operation cancellation requested.")
            }
            try monitor()
        }
        try socket.send(request, limit: 65_536, until: deadline, progress: progress)
        let reply = try socket.receive(
            limit: 2 * 1_024 * 1_024, until: deadline, progress: progress)
        try reply.validateReply(to: request)
        guard let manifest = reply.result?.screenshot else { return (reply, nil) }
        let artifact = try socket.receiveBinary(
            count: manifest.byteCount, sha256: manifest.sha256, until: deadline,
            progress: progress)
        return (reply, artifact)
    }

    package func retire(graceSeconds: Int = 5) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        if process.result == nil {
            try? lifecycleStop(until: deadline)
            socket.close()
        }
        while process.result == nil, ContinuousClock.now < deadline {
            try process.poll()
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.result == nil { process.cancel() }
        let exit = try process.wait()
        if !exit.succeeded {
            // A runner that ended early (for example after an XCTest failure) is otherwise
            // invisible: its output is the only record of why.
            DiagnosticLog.toolFailure(
                label: "session_runner",
                arguments: ["xcodebuild", "test-without-building", identity.sessionId.uuidString],
                result: exit)
        }
        let runnerDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(try runner.isRetired()) {
            try requireRuntime(
                ContinuousClock.now < runnerDeadline, "retirement_unconfirmed",
                "Authenticated XCTest runner is still present.")
            Thread.sleep(forTimeInterval: 0.01)
        }
        try SessionRetention.markRetired(runtime)
    }

    private func lifecycleStop(until deadline: ContinuousClock.Instant) throws {
        var request = WireMessage(type: "request", identity: identity)
        request.requestId = UUID()
        request.operation = "lifecycle.stop"
        request.remainingMilliseconds = max(1, try milliseconds(until: deadline))
        try socket.send(request, limit: 65_536, until: deadline, progress: monitor)
        let reply = try socket.receive(limit: 65_536, until: deadline, progress: monitor)
        try reply.validateReply(to: request)
    }

    private func monitor() throws {
        try process.poll()
        try requireRuntime(
            process.result == nil, "helper_disconnected", "Helper launcher exited during operation."
        )
    }

    private static func launch(
        config: URL, runtime: PrivateDirectory, device: UUID, tools: AppleTools
    ) throws -> OwnedProcess {
        try tools.start(
            [
                "xcodebuild", "test-without-building", "-xctestrun", config.path,
                "-destination", "platform=iOS Simulator,id=\(device.uuidString)",
                "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
                "-maximum-test-execution-time-allowance", "1800",
                "-resultBundlePath", runtime.url.appendingPathComponent("result.xcresult").path,
            ], milliseconds: 1_800_000,
            // Keeps XCTest's own failure text; test output without compilation stays small.
            outputLimit: 1_048_576)
    }

    private static func authenticate(
        listener: WireListener, identity: WireIdentity, token: String,
        device: SimulatorDevice, process: OwnedProcess,
        deadline suppliedDeadline: ContinuousClock.Instant
    ) throws -> (socket: WireSocket, runner: RunnerIdentity) {
        let deadline = min(suppliedDeadline, ContinuousClock.now.advanced(by: .seconds(120)))
        for _ in 0..<8 {
            let socket = try listener.accept(until: deadline, progress: { try monitor(process) })
            do {
                let hello = try socket.receive(
                    limit: 4_096, until: min(deadline, .now.advanced(by: .seconds(5))),
                    progress: { try monitor(process) })
                try hello.validateHello(
                    identity: identity, token: token, device: device.udid,
                    capabilities: WireMessage.allCapabilities)
                let runner = try RunnerIdentity(pid: hello.helperPID!, device: device)
                var ready = WireMessage(type: "ready", identity: identity)
                ready.capabilities = WireMessage.allCapabilities
                try socket.send(
                    ready, limit: 4_096, until: deadline, progress: { try monitor(process) })
                listener.close()
                return (socket, runner)
            } catch {
                socket.close()
            }
        }
        throw WireFailure.authenticationFailed
    }

    private static func monitor(_ process: OwnedProcess) throws {
        try process.poll()
        try requireRuntime(
            process.result == nil, "helper_exited", "Helper exited before readiness.")
    }
}

private func milliseconds(until deadline: ContinuousClock.Instant) throws -> UInt64 {
    let now = ContinuousClock.now
    try requireRuntime(now < deadline, "deadline_exceeded", "Deadline expired before dispatch.")
    let parts = now.duration(to: deadline).components
    return min(
        120_000,
        UInt64(parts.seconds) * 1_000
            + UInt64(parts.attoseconds) / 1_000_000_000_000_000)
}
