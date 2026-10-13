import Darwin
import Foundation

struct ProcessPipes {
    let output: [Int32]
    let errors: [Int32]

    init() throws {
        output = try Self.make()
        do { errors = try Self.make() } catch {
            for descriptor in output { close(descriptor) }
            throw error
        }
    }

    func closeAll() {
        for descriptor in output + errors { close(descriptor) }
    }

    private static func make() throws -> [Int32] {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw ProcessFailure(.spawnFailed) }
        guard pair.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }),
            fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0
        else {
            for descriptor in pair { close(descriptor) }
            throw ProcessFailure(.spawnFailed)
        }
        return pair
    }
}

enum ProcessSpawn {
    static func start(_ command: ProcessCommand, pipes: ProcessPipes) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw ProcessFailure(.spawnFailed)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProcessFailure(.spawnFailed) }
        defer { posix_spawnattr_destroy(&attributes) }
        try configure(&actions, command: command, pipes: pipes)
        var signals = sigset_t()
        sigemptyset(&signals)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for value in [SIGINT, SIGTERM, SIGPIPE, SIGCHLD] { sigaddset(&defaults, value) }
        guard posix_spawnattr_setsigmask(&attributes, &signals) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                        | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ) == 0
        else { throw ProcessFailure(.spawnFailed) }
        var pid: pid_t = 0
        let arguments = [command.executable] + command.arguments
        let environment = command.environment.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value)"
        }
        let status = withStrings(arguments) { argv in
            withStrings(environment) { env in
                posix_spawn(&pid, command.executable, &actions, &attributes, argv, env)
            }
        }
        guard status == 0 else { throw ProcessFailure(.spawnFailed) }
        assert(pid > 0)
        return pid
    }

    private static func configure(
        _ actions: inout posix_spawn_file_actions_t?, command: ProcessCommand, pipes: ProcessPipes
    ) throws {
        let changed: Int32
        if #available(macOS 26, *) {
            changed = posix_spawn_file_actions_addchdir(&actions, command.directory)
        } else {
            changed = posix_spawn_file_actions_addchdir_np(&actions, command.directory)
        }
        guard changed == 0,
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
            posix_spawn_file_actions_adddup2(&actions, pipes.output[1], 1) == 0,
            posix_spawn_file_actions_adddup2(&actions, pipes.errors[1], 2) == 0
        else { throw ProcessFailure(.spawnFailed) }
    }

    private static func withStrings<Result>(
        _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        // Allocations are bounded by command validation; OOM is not an operating retry.
        precondition(pointers.allSatisfy { $0 != nil })
        defer {
            for pointer in pointers { free(pointer) }
        }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
