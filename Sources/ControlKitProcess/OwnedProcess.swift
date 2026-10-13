import Darwin
import Foundation

/// One synchronous owner, no callbacks or hidden queue. Pump while awaiting other I/O.
/// Only this object may reap its direct child. An unreaped leader prevents process-group ID reuse.
package final class OwnedProcess {
    package let pid: pid_t
    private var outputFD: Int32
    private var errorFD: Int32
    private let deadline: ContinuousClock.Instant
    private let outputLimit: Int
    private let cancellation: () -> Bool
    private var output = Data()
    private var errors = Data()
    private var retainedBytes = 0
    private var truncated = false
    private var reason: ProcessResult.Reason?
    private var escalation: ContinuousClock.Instant?
    private var killDeadline: ContinuousClock.Instant?
    private var reaped = false
    package private(set) var result: ProcessResult?

    package init(_ command: ProcessCommand, cancellation: @escaping () -> Bool = { false }) throws {
        try command.validate()
        guard !cancellation() else { throw ProcessFailure(.cancelledBeforeSpawn) }
        self.cancellation = cancellation
        deadline = .now.advanced(by: .milliseconds(Int64(command.timeoutMilliseconds)))
        outputLimit = command.outputLimit
        let pipes = try ProcessPipes()
        do { pid = try ProcessSpawn.start(command, pipes: pipes) } catch {
            pipes.closeAll()
            throw error
        }
        close(pipes.output[1])
        close(pipes.errors[1])
        outputFD = pipes.output[0]
        errorFD = pipes.errors[0]
    }

    deinit {
        if !reaped {
            // Never signal a PID after reaping. Non-child XCTest runners need separate proof.
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
        }
        if outputFD >= 0 { close(outputFD) }
        if errorFD >= 0 { close(errorFD) }
    }

    package func cancel() {
        guard result == nil, reason == nil else { return }
        beginStop(.cancelled)
    }

    package func poll() throws {
        guard result == nil else { return }
        if cancellation() { cancel() }
        drain(&outputFD, into: &output)
        drain(&errorFD, into: &errors)
        var information = siginfo_t()
        let observed = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        if observed != 0 {
            if errno == EINTR { return }
            throw ProcessFailure(.observationFailed)
        }
        if information.si_pid == pid {
            try finish()
            return
        }
        if reason == nil, ContinuousClock.now >= deadline { beginStop(.timedOut) }
        if let escalation, ContinuousClock.now >= escalation, killDeadline == nil {
            kill(-pid, SIGKILL)
            killDeadline = .now.advanced(by: .seconds(2))
        }
        if let killDeadline, ContinuousClock.now >= killDeadline {
            throw ProcessFailure(.cleanupUnconfirmed)
        }
    }

    package func wait(cancelled: () -> Bool = { false }) throws -> ProcessResult {
        while result == nil {
            if cancelled() { cancel() }
            try poll()
            if result == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        return result!
    }

    private func beginStop(_ cause: ProcessResult.Reason) {
        guard reason == nil else { return }
        reason = cause
        kill(-pid, SIGTERM)
        escalation = .now.advanced(by: .seconds(2))
    }

    private func finish() throws {
        // Retire descendants still in the owned group BEFORE freeing its leader's PID.
        kill(-pid, SIGKILL)
        drain(&outputFD, into: &output)
        drain(&errorFD, into: &errors)
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else {
            throw ProcessFailure(.observationFailed)
        }
        reaped = true
        let signal = status & 0x7f
        result = ProcessResult(
            reason: reason ?? .exited, exitCode: signal == 0 ? (status >> 8) & 0xff : nil,
            signal: signal == 0 ? nil : signal, stdout: output, stderr: errors,
            outputTruncated: truncated)
        if outputFD >= 0 {
            close(outputFD)
            outputFD = -1
        }
        if errorFD >= 0 {
            close(errorFD)
            errorFD = -1
        }
    }

    private func drain(_ descriptor: inout Int32, into data: inout Data) {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Fairness is bounded even when a child continuously floods one stream.
        for _ in 0..<16 {
            let count = read(descriptor, &bytes, bytes.count)
            if count == 0 {
                close(descriptor)
                descriptor = -1
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { beginStop(.ioFailure) }
                return
            }
            let available = outputLimit - retainedBytes
            let retained = min(count, available)
            data.append(contentsOf: bytes.prefix(retained))
            retainedBytes += retained
            if retained < count { truncated = true }
        }
    }
}
