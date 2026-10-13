import Darwin
import Foundation

// Local milestone-1 integration harness, not the production supervisor.
// All credential-bearing configuration and execution logs stay in a private temporary directory.
struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

final class Harness {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let executable: URL
    let products: URL
    let runtime: URL
    let device: String
    let token = UUID().uuidString + UUID().uuidString
    let port: UInt16
    private var sequence = 0
    private(set) var measurements: [[String: Any]] = []

    init(device: String, runtime: URL) throws {
        self.device = device
        let environment = ProcessInfo.processInfo.environment
        executable = URL(
            fileURLWithPath: environment["CONTROLKIT_PROBE_CLI"] ?? ".build/debug/ControlKit")
        products = URL(
            fileURLWithPath: environment["CONTROLKIT_PROBE_PRODUCTS"]
                ?? ".build/probe-xcode/Build/Products"
        )
        self.runtime = runtime.standardizedFileURL.resolvingSymlinksInPath()
        guard !self.runtime.path.hasPrefix(root.path + "/") else {
            throw SmokeFailure("Runtime credentials must be outside the repository.")
        }
        guard !FileManager.default.fileExists(atPath: runtime.path) else {
            throw SmokeFailure(
                "Choose a new runtime directory; existing paths are not overwritten.")
        }
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        port = try Self.unusedPort()
    }

    static func unusedPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SmokeFailure("Cannot allocate a loopback socket.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SmokeFailure("Cannot bind the loopback socket.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { throw SmokeFailure("Cannot read the loopback port.") }
        return UInt16(bigEndian: address.sin_port)
    }

    func spawn(
        _ executable: String, _ arguments: [String], environment: [String: String] = [:]
    ) throws -> (process: Process, output: URL, errors: URL) {
        sequence += 1
        let output = runtime.appendingPathComponent("\(sequence).stdout")
        let errors = runtime.appendingPathComponent("\(sequence).stderr")
        for file in [output, errors] {
            guard
                FileManager.default.createFile(
                    atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]
                )
            else { throw SmokeFailure("Cannot create process output.") }
        }
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
            new
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return (process, output, errors)
    }

    func wait(
        _ job: (process: Process, output: URL, errors: URL), seconds: Double
    ) throws -> (Int32, Data) {
        let started = ContinuousClock.now
        while job.process.isRunning {
            if started.duration(to: .now) > .seconds(seconds) {
                terminate(job.process)
                throw SmokeFailure("Subprocess deadline exceeded. Logs: \(job.errors.path)")
            }
            do {
                try checkOutputSize([job.output, job.errors])
            } catch {
                terminate(job.process)
                throw error
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try checkOutputSize([job.output, job.errors])
        return (job.process.terminationStatus, try Data(contentsOf: job.output))
    }

    func checkOutputSize(_ files: [URL]) throws {
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 8 * 1_024 * 1_024 else {
                throw SmokeFailure("Subprocess output exceeded the harness limit.")
            }
        }
    }

    func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let started = ContinuousClock.now
        while process.isRunning, started.duration(to: .now) < .seconds(2) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    @discardableResult
    func xcrun(_ arguments: [String], seconds: Double = 60) throws -> Data {
        let job = try spawn("/usr/bin/xcrun", arguments)
        let (status, data) = try wait(job, seconds: seconds)
        guard status == 0 else {
            throw SmokeFailure("xcrun \(arguments[0]) failed. Logs: \(job.errors.path)")
        }
        return data
    }

    func request(
        _ operation: String, arguments: [String] = [], expectedError: String? = nil,
        timeout: Double = 30
    ) throws -> [String: Any] {
        let started = ContinuousClock.now
        let job = try spawn(
            executable.path,
            [
                "probe", "request", operation,
                "--connection", runtime.appendingPathComponent("connection.json").path,
                "--timeout", "\(timeout)",
            ] + arguments
        )
        let (status, data) = try wait(job, seconds: timeout + 5)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmokeFailure("CLI did not return a JSON object.")
        }
        let error = response["error"] as? [String: String]
        guard error?["code"] == expectedError, (status == 0) == (expectedError == nil) else {
            throw SmokeFailure(
                "Unexpected \(operation) result: \(String(decoding: data, as: UTF8.self))")
        }
        let elapsed = started.duration(to: .now).components
        measurements.append([
            "operation": operation,
            "wallMilliseconds": Double(elapsed.seconds) * 1_000
                + Double(elapsed.attoseconds) / 1e15,
            "helperMilliseconds": response["elapsedMilliseconds"] ?? 0,
        ])
        return response
    }

    func prepareTestRun() throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: products, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "xctestrun" }
        guard files.count == 1 else { throw SmokeFailure("Build the Xcode probe first.") }
        guard
            var plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: files[0]), format: nil
            ) as? [String: Any]
        else {
            throw SmokeFailure("Expected an xctestrun dictionary.")
        }
        guard var target = plist["ControlKitHelper"] as? [String: Any] else {
            throw SmokeFailure(
                "Unexpected xctestrun schema; inspect it before changing the harness.")
        }
        let productPath = products.path
        for key in ["TestBundlePath", "TestHostPath"] {
            guard let path = target[key] as? String else {
                throw SmokeFailure("Missing \(key) in xctestrun.")
            }
            target[key] = path.replacingOccurrences(of: "__TESTROOT__", with: productPath)
        }
        let dependencies = target["DependentProductPaths"] as? [String] ?? []
        target["DependentProductPaths"] = dependencies.map {
            $0.replacingOccurrences(of: "__TESTROOT__", with: productPath)
        }
        for key in ["TestingEnvironmentVariables", "UITargetAppEnvironmentVariables"] {
            let values = target[key] as? [String: String] ?? [:]
            target[key] = values.mapValues {
                $0.replacingOccurrences(of: "__TESTROOT__", with: productPath)
            }
        }
        var environment = target["EnvironmentVariables"] as? [String: String] ?? [:]
        environment["CONTROLKIT_PROBE_TOKEN"] = token
        environment["CONTROLKIT_PROBE_PORT"] = "\(port)"
        environment["CONTROLKIT_PROBE_APP"] = "dev.controlkit.fixture"
        target["EnvironmentVariables"] = environment
        plist["ControlKitHelper"] = target
        let destination = runtime.appendingPathComponent("Probe.xctestrun")
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        guard
            FileManager.default.createFile(
                atPath: destination.path, contents: data, attributes: [.posixPermissions: 0o600]
            )
        else { throw SmokeFailure("Cannot create private test configuration.") }
        try writeConnection()
        return destination
    }

    private func writeConnection() throws {
        let data = try JSONSerialization.data(withJSONObject: ["port": port, "token": token])
        guard
            FileManager.default.createFile(
                atPath: runtime.appendingPathComponent("connection.json").path,
                contents: data, attributes: [.posixPermissions: 0o600]
            )
        else {
            throw SmokeFailure("Cannot write private connection information.")
        }
    }

    func startHelper(
        _ configuration: URL
    ) throws -> (process: Process, output: URL, errors: URL) {
        let job = try spawn(
            "/usr/bin/xcrun",
            [
                "xcodebuild", "test-without-building", "-xctestrun", configuration.path,
                "-destination", "platform=iOS Simulator,id=\(device)",
                "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES",
                "-maximum-test-execution-time-allowance", "660",
            ])
        let started = ContinuousClock.now
        for _ in 0..<120 {
            guard job.process.isRunning else {
                throw SmokeFailure("Helper exited at startup. Logs: \(job.output.path)")
            }
            do {
                try checkOutputSize([job.output, job.errors])
            } catch {
                terminate(job.process)
                throw error
            }
            let data = try Data(contentsOf: job.output)
            if String(decoding: data, as: UTF8.self).contains("CONTROLKIT_PROBE_READY") {
                let elapsed = started.duration(to: .now).components
                measurements.append([
                    "operation": "helper_start",
                    "wallMilliseconds": Double(elapsed.seconds) * 1_000
                        + Double(elapsed.attoseconds) / 1e15,
                ])
                return job
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        terminate(job.process)
        throw SmokeFailure("Helper readiness timed out. Logs: \(job.output.path)")
    }

    func element(_ response: [String: Any], id: String) throws -> [String: Any] {
        let elements = response["elements"] as? [[String: Any]] ?? []
        guard let element = elements.first(where: { $0["identifier"] as? String == id }) else {
            throw SmokeFailure("Expected element \(id) is absent.")
        }
        return element
    }
}

func verifyInteractions(_ harness: Harness, extraInspections: Int) throws -> String {
    _ = try harness.request("ping")
    _ = try harness.request("tap", arguments: ["--id", "fixture.open"])
    _ = try harness.request("tap", arguments: ["--id", "fixture.increment"])
    let before = try harness.request("inspect")
    guard let identity = try harness.element(before, id: "fixture.identity")["label"] as? String
    else {
        throw SmokeFailure("Fixture identity is not a string.")
    }
    for _ in 0..<extraInspections {
        let observed = try harness.request("inspect")
        guard try harness.element(observed, id: "fixture.identity")["label"] as? String == identity
        else {
            throw SmokeFailure("Sequential inspection changed the app's screen identity.")
        }
    }
    guard try harness.element(before, id: "fixture.counter")["label"] as? String == "Count: 1"
    else {
        throw SmokeFailure("Tap did not update fixture state.")
    }
    _ = try harness.request(
        "type", arguments: ["--id", "fixture.input", "--text", "Hello café 👋"]
    )
    let typed = try harness.request("inspect")
    guard try harness.element(typed, id: "fixture.input")["value"] as? String == "Hello café 👋"
    else {
        throw SmokeFailure("Unicode typing failed.")
    }
    _ = try harness.request("tap", arguments: ["--id", "fixture.dismiss"])
    _ = try harness.request(
        "tap", arguments: ["--id", "missing"], expectedError: "element_not_found"
    )
    _ = try harness.request(
        "tap", arguments: ["--id", "fixture.duplicate"], expectedError: "ambiguous_element"
    )
    for _ in 0..<3 {
        _ = try harness.request("swipe", arguments: ["--id", "fixture.scroll"])
    }
    _ = try harness.request("tap", arguments: ["--id", "fixture.bottom"])
    let screenshot = try harness.request(
        "screenshot",
        arguments: ["--output", harness.runtime.appendingPathComponent("screen.png").path]
    )
    let after = try harness.request("inspect")
    try verifyScreenshot(harness, screenshot: screenshot, inspection: after)
    guard try harness.element(after, id: "fixture.counter")["label"] as? String == "Count: 2" else {
        throw SmokeFailure("Scrolling to and tapping the bottom button failed.")
    }
    return identity
}

func verifyScreenshot(
    _ harness: Harness, screenshot: [String: Any], inspection: [String: Any]
) throws {
    let file = harness.runtime.appendingPathComponent("screen.png")
    let data = try Data(contentsOf: file)
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard data.count > 24, data.prefix(8) == Data(signature) else {
        throw SmokeFailure("Screenshot is not a PNG.")
    }
    let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let elements = inspection["elements"] as? [[String: Any]]
    guard let frame = elements?.first?["frame"] as? [String: Double],
        let widthPoints = frame["width"], let heightPoints = frame["height"],
        let scale = screenshot["screenScale"] as? Double,
        Double(width) == widthPoints * scale, Double(height) == heightPoints * scale
    else {
        throw SmokeFailure("Screenshot pixels and element point coordinates disagree.")
    }
    _ = try harness.request(
        "screenshot", arguments: ["--output", file.path], expectedError: "file_exists"
    )
}

func verifyRestart(_ harness: Harness, configuration: URL, identity: String) throws {
    let job = try harness.startHelper(configuration)
    defer { harness.terminate(job.process) }
    // Do not activate or launch the app here: a restart must preserve foreground and navigation.
    let after = try harness.request("inspect")
    guard try harness.element(after, id: "fixture.identity")["label"] as? String == identity else {
        throw SmokeFailure("Helper restart changed the app's in-memory screen identity.")
    }
    guard try harness.element(after, id: "fixture.counter")["label"] as? String == "Count: 2" else {
        throw SmokeFailure("Helper restart lost application state.")
    }
    _ = try harness.request("stop")
    let (status, _) = try harness.wait(job, seconds: 30)
    guard status == 0 else {
        throw SmokeFailure("Restarted XCTest helper did not exit successfully.")
    }
}

func verifyFaultRecovery(
    _ harness: Harness, configuration: URL, identity: String
) throws -> Bool {
    let interrupted = try harness.startHelper(configuration)
    defer { harness.terminate(interrupted.process) }
    _ = try harness.request(
        "tap", arguments: ["--id", "fixture.bottom"], expectedError: "outcome_unknown", timeout: 0.1
    )
    // Fault injection, not UI synchronization: allow the abandoned action a chance to complete.
    Thread.sleep(forTimeInterval: 1)
    let termination = try harness.spawn(
        "/usr/bin/xcrun",
        [
            "simctl", "terminate", harness.device, "dev.controlkit.helper.xctrunner",
        ])
    let (terminationStatus, _) = try harness.wait(termination, seconds: 10)
    guard terminationStatus == 0 else {
        throw SmokeFailure("Fault test could not forcibly terminate the helper.")
    }
    harness.terminate(interrupted.process)
    let recovered = try harness.startHelper(configuration)
    defer { harness.terminate(recovered.process) }
    let after = try harness.request("inspect")
    guard try harness.element(after, id: "fixture.identity")["label"] as? String == identity else {
        throw SmokeFailure("Fault recovery changed the app's screen identity.")
    }
    let counter = try harness.element(after, id: "fixture.counter")["label"] as? String
    guard counter == "Count: 2" || counter == "Count: 3" else {
        throw SmokeFailure("An uncertain mutation was replayed or application state was lost.")
    }
    _ = try harness.request("stop")
    let (status, _) = try harness.wait(recovered, seconds: 30)
    guard status == 0 else { throw SmokeFailure("Recovered helper did not exit successfully.") }
    return counter == "Count: 3"
}

func prepareFixture(_ harness: Harness) throws -> URL {
    let fixture = harness.products.appendingPathComponent(
        "Debug-iphonesimulator/ControlKitFixture.app")
    try harness.xcrun(["simctl", "install", harness.device, fixture.path])
    try harness.xcrun([
        "simctl", "launch", "--terminate-running-process", harness.device, "dev.controlkit.fixture",
    ])
    return try harness.prepareTestRun()
}

func runSmoke(_ harness: Harness, extraInspections: Int) throws {
    let configuration = try prepareFixture(harness)
    let job = try harness.startHelper(configuration)
    defer { harness.terminate(job.process) }
    let identity = try verifyInteractions(harness, extraInspections: extraInspections)
    _ = try harness.request("stop")
    let (status, _) = try harness.wait(job, seconds: 30)
    guard status == 0 else { throw SmokeFailure("XCTest helper did not exit successfully.") }
    try verifyRestart(harness, configuration: configuration, identity: identity)
    let timedOutActionApplied = try verifyFaultRecovery(
        harness, configuration: configuration, identity: identity
    )
    let summary: [String: Any] = [
        "ok": true, "device": harness.device, "measurements": harness.measurements,
        "timedOutActionApplied": timedOutActionApplied,
        "verified": [
            "independent helper", "public snapshot", "separate CLI processes", "tap",
            "Unicode input",
            "scroll", "screenshot", "typed errors", "state preserved across helper restart",
            "mutation timeout reports uncertainty", "forced helper termination and recovery",
        ],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: harness.runtime.appendingPathComponent("summary.json"))
    print(String(decoding: data, as: UTF8.self))
}

func serve(_ harness: Harness) throws {
    let configuration = try prepareFixture(harness)
    let job = try harness.startHelper(configuration)
    defer { harness.terminate(job.process) }
    // Intercept Ctrl-C only while we own the foreground xcodebuild; do not leave it detached.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { job.process.interrupt() }
    interrupt.resume()
    defer {
        interrupt.cancel()
        signal(SIGINT, SIG_DFL)
    }
    let message = """
        Probe ready for up to 10 minutes. Private connection file:
        \(harness.runtime.appendingPathComponent("connection.json").path)
        Use: just probe-request <connection-file> inspect
        End with: just probe-request <connection-file> stop (or Ctrl-C here).

        """
    FileHandle.standardOutput.write(Data(message.utf8))
    let (status, _) = try harness.wait(job, seconds: 660)
    guard status == 0 else {
        throw SmokeFailure("Probe stopped or expired. Private logs: \(harness.runtime.path)")
    }
}

func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.isEmpty {
        print(
            """
            Usage: swift Tools/ProbeSmoke.swift [serve] <udid> <new-runtime-dir> [extra-inspections]
            Requires a dedicated booted simulator and built CLI/helper. Prefer the Just recipes.
            Default: smoke + fault tests; optional 0–100 extra sequential inspections.
            Serve: keep the helper alive for manual CLI requests (max 10 minutes).
            Installs/relaunches only dev.controlkit.fixture.
            It does not erase or shut down the simulator.
            Credential-bearing artifacts remain in the owner-only directory outside the repository.
            CONTROLKIT_PROBE_CLI / CONTROLKIT_PROBE_PRODUCTS select
            toolchain-specific build outputs.
            """)
        if arguments.contains("--help") { return }
        throw SmokeFailure("Missing arguments; see --help.")
    }
    let interactive = arguments.first == "serve"
    if interactive { arguments.removeFirst() }
    guard (2...3).contains(arguments.count), !interactive || arguments.count == 2 else {
        throw SmokeFailure("Expected a simulator UDID and a new private runtime directory.")
    }
    let countText = arguments.count == 3 ? arguments[2] : "0"
    guard let count = Int(countText), (0...100).contains(count) else {
        throw SmokeFailure("Extra inspections must be in 0–100.")
    }
    let harness = try Harness(device: arguments[0], runtime: URL(fileURLWithPath: arguments[1]))
    if interactive {
        try serve(harness)
    } else {
        try runSmoke(harness, extraInspections: count)
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("Probe failed: \(error)\n".utf8))
    exit(1)
}
