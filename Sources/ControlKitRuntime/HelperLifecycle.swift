import ControlKitProcess
import ControlKitWire
import Foundation

package struct HelperEvidence: Codable, Sendable {
    package let toolchain: ToolchainIdentity
    package let cacheKey: String
    package let cacheReused: Bool
    package let authenticated: Bool
    package let runnerRetired: Bool
    package let stopMode: String
    package let runtimeDirectory: String
}

package enum HelperLifecycle {
    package static func verify(
        source: URL, cache: URL, device id: UUID, tools: AppleTools,
        disconnectAfterPing: Bool = false
    ) throws
        -> HelperEvidence
    {
        let operations = try SimulatorOperations(tools: tools)
        let claim = try DeviceClaim(
            directory: operations.leases, device: id, operation: "helper.verify")
        let device = try operations.device(id)
        try requireRuntime(
            device.state == "Booted", "device_not_booted", "Boot the chosen simulator first.")
        let cached = try HelperCache.prepare(source: source, cache: cache, tools: tools)
        try requireRuntime(
            !operations.state.url.path.hasPrefix(source.path + "/"),
            "private_files", "Runtime credentials must be outside the source repository.")
        let runs = try operations.state.entries().filter { UUID(uuidString: $0) != nil }
        try requireRuntime(
            runs.count < 32, "resource_limit", "Private runtime retention reached 32 runs.")
        _ = try RuntimeFiles.cacheBytes(operations.state.url, maximumBytes: 256 * 1_024 * 1_024)
        let runtime = try PrivateDirectory(
            operations.state.url.appendingPathComponent(claim.launchID.uuidString))
        let listener = try WireListener()
        let identity = WireIdentity(
            epoch: UUID(), session: UUID(), generation: 1, launch: claim.launchID)
        let token = try HelperConfiguration.token()
        let config = try HelperConfiguration.write(
            cached: cached, runtime: runtime, identity: identity, token: token, port: listener.port)
        try claim.begin()
        let process = try launch(
            config: config, runtime: runtime, device: id, tools: tools, claim: claim)
        var runner: RunnerIdentity?
        var operationError: (any Error)?
        do {
            let socket = try authenticate(
                listener, identity: identity, token: token, device: device, process: process,
                runner: &runner)
            try command("lifecycle.ping", socket: socket, identity: identity, process: process)
            if !disconnectAfterPing {
                try command("lifecycle.stop", socket: socket, identity: identity, process: process)
            }
            socket.close()
        } catch {
            operationError = error
            listener.close()
            process.cancel()
        }
        try retire(process: process, runner: runner, graceSeconds: operationError == nil ? 5 : 0)
        try claim.complete()
        _ = try RuntimeFiles.cacheBytes(operations.state.url, maximumBytes: 256 * 1_024 * 1_024)
        if let operationError { throw operationError }
        return HelperEvidence(
            toolchain: tools.identity, cacheKey: cached.key, cacheReused: cached.reused,
            authenticated: true, runnerRetired: true,
            stopMode: disconnectAfterPing ? "disconnect" : "graceful",
            runtimeDirectory: runtime.url.path)
    }

    private static func launch(
        config: URL, runtime: PrivateDirectory, device: UUID, tools: AppleTools, claim: DeviceClaim
    ) throws -> OwnedProcess {
        let arguments = [
            "xcodebuild", "test-without-building", "-xctestrun", config.path,
            "-destination", "platform=iOS Simulator,id=\(device.uuidString)",
            "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "180",
            "-resultBundlePath", runtime.url.appendingPathComponent("result.xcresult").path,
        ]
        do { return try tools.start(arguments, milliseconds: 180_000, outputLimit: 0) } catch {
            // No child was created; there is no uncertain execution to retain.
            try claim.complete()
            throw error
        }
    }

    private static func authenticate(
        _ listener: WireListener, identity: WireIdentity, token: String, device: SimulatorDevice,
        process: OwnedProcess, runner: inout RunnerIdentity?
    ) throws -> WireSocket {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        for _ in 0..<8 {
            let socket = try listener.accept(until: deadline, progress: { try monitor(process) })
            do {
                let hello = try socket.receive(
                    limit: 4_096, until: min(deadline, .now.advanced(by: .seconds(5))),
                    progress: { try monitor(process) })
                try hello.validateHello(
                    identity: identity, token: token, device: device.udid,
                    capabilities: WireMessage.allCapabilities)
                runner = try RunnerIdentity(pid: hello.helperPID!, device: device)
                var ready = WireMessage(type: "ready", identity: identity)
                ready.capabilities = WireMessage.allCapabilities
                try socket.send(
                    ready, limit: 4_096, until: deadline, progress: { try monitor(process) })
                listener.close()
                return socket
            } catch let error as WireFailure {
                socket.close()
                if error == .deadlineExceeded, ContinuousClock.now >= deadline { throw error }
            }
        }
        throw WireFailure.authenticationFailed
    }

    private static func monitor(_ process: OwnedProcess) throws {
        try process.poll()
        try requireRuntime(
            process.result == nil, "helper_exited", "Helper launcher exited before readiness.")
    }

    private static func command(
        _ operation: String, socket: WireSocket, identity: WireIdentity, process: OwnedProcess
    ) throws {
        var request = WireMessage(type: "request", identity: identity)
        request.requestId = UUID()
        request.operation = operation
        request.remainingMilliseconds = 5_000
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        try socket.send(request, limit: 65_536, until: deadline, progress: { try monitor(process) })
        let reply = try socket.receive(
            limit: 65_536, until: deadline, progress: { try monitor(process) })
        try reply.validateReply(to: request)
    }

    private static func retire(process: OwnedProcess, runner: RunnerIdentity?, graceSeconds: Int)
        throws
    {
        let grace = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while process.result == nil, ContinuousClock.now < grace {
            try process.poll()
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.result == nil { process.cancel() }
        _ = try process.wait()
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        guard let runner else {
            throw RuntimeFailure(
                "retirement_unconfirmed",
                "No authenticated runner identity; ownership fence retained.")
        }
        while !(try runner.isRetired()) {
            try requireRuntime(
                ContinuousClock.now < deadline, "retirement_unconfirmed",
                "XCTest runner is still present; ownership fence retained.")
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
