import ControlKitRuntime
import ControlKitWire
import Darwin
import Foundation

package enum SupervisorClientFailure: Error {
    case cancelled(sent: Bool)
    case replacement(String)
}

package enum SupervisorClient {
    package static func perform(
        _ request: SupervisorRequest, executable: URL, source: URL, cache: URL
    ) throws -> SupervisorResponse {
        try perform(request, executable: executable, source: source, cache: cache, mayReplace: true)
    }

    private static func perform(
        _ request: SupervisorRequest, executable: URL, source: URL, cache: URL, mayReplace: Bool
    ) throws -> SupervisorResponse {
        let cancellation = CancellationSignal()
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(request.remainingMilliseconds)))
        let socket: WireSocket
        do {
            socket = try LocalListener.connect()
        } catch {
            socket = try startAndAwait(
                executable: executable, source: source, cache: cache,
                until: min(deadline, .now.advanced(by: .seconds(5))),
                cancellation: cancellation)
        }
        defer { socket.close() }
        if cancellation.isRequested { throw SupervisorClientFailure.cancelled(sent: false) }
        try socket.sendJSON(
            request, limit: 65_536, until: deadline,
            progress: { try checkCancellation(cancellation, sent: false) })
        let response: SupervisorResponse
        do {
            response = try socket.receiveJSON(
                SupervisorResponse.self, limit: 2 * 1_024 * 1_024, until: deadline,
                progress: { try checkCancellation(cancellation, sent: true) })
        } catch SupervisorClientFailure.cancelled {
            throw SupervisorClientFailure.cancelled(sent: true)
        }
        let replaceable = ["toolchain_mismatch", "protocol_mismatch"]
        guard mayReplace, replaceable.contains(response.error?.code ?? "") else { return response }
        return try replace(
            request, previous: response, socket: socket, executable: executable,
            source: source, cache: cache, deadline: deadline, cancellation: cancellation)
    }

    private static func replace(
        _ request: SupervisorRequest, previous: SupervisorResponse, socket: WireSocket,
        executable: URL, source: URL, cache: URL, deadline: ContinuousClock.Instant,
        cancellation: CancellationSignal
    ) throws -> SupervisorResponse {
        var shutdown = request
        shutdown.requestId = UUID()
        shutdown.operation = "supervisor.shutdown"
        shutdown.sessionId = nil
        shutdown.helperGeneration = nil
        socket.close()
        let replacement: WireSocket
        do { replacement = try LocalListener.connect() } catch {
            throw SupervisorClientFailure.replacement("cannot connect for idle shutdown")
        }
        defer { replacement.close() }
        do {
            try replacement.sendJSON(shutdown, limit: 65_536, until: deadline)
        } catch {
            throw SupervisorClientFailure.replacement("cannot request idle shutdown")
        }
        let stopped: SupervisorResponse
        do {
            stopped = try replacement.receiveJSON(
                SupervisorResponse.self, limit: 65_536, until: deadline)
        } catch {
            throw SupervisorClientFailure.replacement("idle shutdown response was lost")
        }
        guard stopped.ok else { return previous }
        replacement.close()
        let socketPath = try SupervisorEndpoint.directory().url
            .appendingPathComponent("control.sock").path
        while ContinuousClock.now < deadline {
            var info = stat()
            if lstat(socketPath, &info) != 0, errno == ENOENT { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let ready: WireSocket
        do {
            ready = try startAndAwait(
                executable: executable, source: source, cache: cache,
                until: min(deadline, .now.advanced(by: .seconds(5))), cancellation: cancellation)
        } catch {
            throw SupervisorClientFailure.replacement("replacement supervisor did not become ready")
        }
        defer { ready.close() }
        try ready.sendJSON(
            request, limit: 65_536, until: deadline,
            progress: { try checkCancellation(cancellation, sent: false) })
        return try ready.receiveJSON(
            SupervisorResponse.self, limit: 2 * 1_024 * 1_024, until: deadline,
            progress: { try checkCancellation(cancellation, sent: true) })
    }

    private static func awaitConnection(
        until deadline: ContinuousClock.Instant, cancellation: CancellationSignal
    ) throws
        -> WireSocket
    {
        while ContinuousClock.now < deadline {
            try checkCancellation(cancellation, sent: false)
            if let socket = try? LocalListener.connect() { return socket }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw WireFailure.deadlineExceeded
    }

    private static func startAndAwait(
        executable: URL, source: URL, cache: URL, until deadline: ContinuousClock.Instant,
        cancellation: CancellationSignal
    ) throws -> WireSocket {
        for _ in 0..<8 {
            try checkCancellation(cancellation, sent: false)
            try DetachedSupervisor.start(executable: executable, source: source, cache: cache)
            let attempt = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(500)))
            if let socket = try? awaitConnection(until: attempt, cancellation: cancellation) {
                return socket
            }
            if ContinuousClock.now >= deadline { break }
        }
        throw WireFailure.deadlineExceeded
    }

    private static func checkCancellation(_ signal: CancellationSignal, sent: Bool) throws {
        if signal.isRequested { throw SupervisorClientFailure.cancelled(sent: sent) }
    }
}

enum DetachedSupervisor {
    static func start(executable: URL, source: URL, cache: URL) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
            posix_spawnattr_init(&attributes) == 0
        else { throw WireFailure.socketFailure }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        for descriptor: Int32 in [0, 1] {
            guard
                posix_spawn_file_actions_addopen(
                    &actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
                    == 0
            else { throw WireFailure.socketFailure }
        }
        guard
            posix_spawn_file_actions_addopen(
                &actions, 2, errorPath(), O_WRONLY | O_CREAT | O_APPEND, 0o600) == 0
        else { throw WireFailure.socketFailure }
        guard
            posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { throw WireFailure.socketFailure }
        let values = [
            executable.path, "_supervisor", "--source", source.path, "--cache", cache.path,
        ]
        var arguments = values.map { strdup($0) }
        precondition(arguments.allSatisfy { $0 != nil })
        defer {
            for argument in arguments { free(argument) }
        }
        arguments.append(nil)
        var environment = ProcessInfo.processInfo.environment.map {
            strdup("\($0.key)=\($0.value)")
        }
        precondition(environment.allSatisfy { $0 != nil })
        defer {
            for value in environment { free(value) }
        }
        environment.append(nil)
        var pid: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { env in
                posix_spawn(
                    &pid, executable.path, &actions, &attributes, argv.baseAddress!,
                    env.baseAddress!)
            }
        }
        guard result == 0, pid > 0 else {
            DiagnosticLog.record("supervisor.spawn_failed", ["posixError": "\(result)"])
            throw WireFailure.socketFailure
        }
        DiagnosticLog.record("supervisor.spawned", ["pid": "\(pid)"])
    }

    /// The detached supervisor has no terminal, so its standard error goes to the owner-only log
    /// folder. Without that folder it falls back to discarding output, as before logging existed.
    private static func errorPath() -> String {
        let directory = DiagnosticLog.directoryURL()
        guard (try? PrivateDirectory(directory)) != nil else { return "/dev/null" }
        return directory.appendingPathComponent(DiagnosticLog.supervisorErrorName).path
    }
}
