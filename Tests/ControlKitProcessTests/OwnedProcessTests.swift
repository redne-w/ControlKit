import Darwin
import Foundation
import Testing

@testable import ControlKitProcess

struct OwnedProcessTests {
    private func command(_ script: String, timeout: UInt64 = 5_000, limit: Int = 8_388_608)
        -> ProcessCommand
    {
        ProcessCommand(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: "/", timeoutMilliseconds: timeout, outputLimit: limit)
    }

    @Test func outputExitAndLiteralArguments() throws {
        let result = try OwnedProcess(command("printf stdout; printf stderr >&2; exit 7")).wait()
        #expect(result.exitCode == 7)
        #expect(result.reason == .exited)
        #expect(result.stdout == Data("stdout".utf8))
        #expect(result.stderr == Data("stderr".utf8))
        #expect(!result.succeeded)
        let literal = ProcessCommand(
            executable: "/usr/bin/printf", arguments: ["%s", "$(touch not-executed)"],
            environment: [:], directory: "/", timeoutMilliseconds: 5_000)
        #expect(try OwnedProcess(literal).wait().stdout == Data("$(touch not-executed)".utf8))
    }

    @Test func bothStreamsAreDrainedAndRetainedBytesAreBounded() throws {
        let script = """
            i=0; while [ $i -lt 20000 ]; do
                printf 1234567890; printf abcdefghij >&2; i=$((i+1))
            done
            """
        let result = try OwnedProcess(command(script, limit: 1_024)).wait()
        #expect(result.succeeded)
        #expect(result.outputTruncated)
        #expect(result.stdout.count + result.stderr.count == 1_024)
    }

    @Test func timeoutEscalatesAndReapsOnlyOwnedChild() throws {
        let process = try OwnedProcess(command("trap '' TERM; while :; do :; done", timeout: 100))
        let result = try process.wait()
        #expect(result.reason == .timedOut)
        #expect(result.signal == SIGKILL)
        var status: Int32 = 0
        #expect(waitpid(process.pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        // Calling cancel/poll again cannot signal a now-reusable PID.
        process.cancel()
        try process.poll()
    }

    @Test func cancellationAndSpawnFailure() throws {
        let process = try OwnedProcess(command("sleep 20"))
        let result = try process.wait(cancelled: { true })
        #expect(result.reason == .cancelled)
        let invalid = ProcessCommand(
            executable: "/nonexistent/controlkit", arguments: [], environment: [:],
            directory: "/", timeoutMilliseconds: 1_000)
        #expect(throws: ProcessFailure(.spawnFailed)) { _ = try OwnedProcess(invalid) }
    }

    @Test func orphanedPipeCannotHangExit() throws {
        let result = try OwnedProcess(command("sleep 20 & printf done; exit 0")).wait()
        #expect(result.succeeded)
        #expect(result.stdout == Data("done".utf8))
        #expect(!result.outputTruncated)
    }

    @Test func invalidInputIsRejectedBeforeSpawn() throws {
        #expect(throws: ProcessFailure(.cancelledBeforeSpawn)) {
            _ = try OwnedProcess(command("exit 0"), cancellation: { true })
        }
        for timeout: UInt64 in [0, 1_800_001] {
            #expect(throws: ProcessFailure(.invalidInput)) {
                _ = try OwnedProcess(command("exit 0", timeout: timeout))
            }
        }
        #expect(throws: ProcessFailure(.invalidInput)) {
            _ = try OwnedProcess(command(String(repeating: "a", count: 16_385)))
        }
    }
}
