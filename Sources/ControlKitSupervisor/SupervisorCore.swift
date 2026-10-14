import ControlKitDiscovery
import ControlKitRuntime
import ControlKitSession
import ControlKitWire
import CryptoKit
import Foundation

final class SessionRecord: @unchecked Sendable {
    let id: UUID
    let device: UUID
    let app: String
    var claim: DeviceClaim?
    let created: UInt64
    let hardDeadline: ContinuousClock.Instant
    var lastActivity = ContinuousClock.now
    var effectRunning = false
    var cancelEffect = false
    var retirementUnconfirmed = false
    var machine = SessionMachine()
    var helper: SessionHelper?
    var resultBytes = 0
    var results: [UUID: SupervisorData] = [:]
    var resultOrder: [UUID] = []
    var sealingResults: Set<UUID> = []
    var events: [DiagnosticEvent] = []

    init(id: UUID, device: UUID, app: String, claim: DeviceClaim, created: UInt64) {
        self.id = id
        self.device = device
        self.app = app
        self.claim = claim
        self.created = created
        hardDeadline = .now.advanced(by: .seconds(1_800))
    }

    func view(now: UInt64) -> SessionView {
        let remaining = ContinuousClock.now.duration(to: hardDeadline).components.seconds
        return SessionView(
            id: id, device: device, app: app, state: machine.state,
            generation: machine.generation, createdMonotonicMilliseconds: created,
            hardDeadlineMonotonicMilliseconds: now + UInt64(max(0, remaining)) * 1_000)
    }

    func store(_ data: SupervisorData, request: UUID) {
        guard let encoded = try? JSONEncoder().encode(data), encoded.count <= 4 * 1_024 * 1_024
        else {
            machine.markResultExpired(id: request)
            return
        }
        while resultOrder.count >= 16 || resultBytes + encoded.count > 4 * 1_024 * 1_024 {
            guard let expired = resultOrder.first else { break }
            resultOrder.removeFirst()
            if let old = results.removeValue(forKey: expired),
                let bytes = try? JSONEncoder().encode(old).count
            {
                resultBytes -= bytes
            }
            machine.markResultExpired(id: expired)
        }
        results[request] = data
        resultOrder.append(request)
        resultBytes += encoded.count
    }

    func log(_ code: String, request: UUID? = nil) {
        // The in-memory ring serves `logs`; the file outlives the supervisor for bug reports.
        // Callers hold the core lock, and an append is one short owner-only file write.
        DiagnosticLog.record(
            "session.event",
            ["session": id.uuidString, "code": code, "request": request?.uuidString ?? "none"])
        if events.count >= 1_024 { events.removeFirst() }
        events.append(
            DiagnosticEvent(
                monotonicMilliseconds: SupervisorCore.now(), code: code, requestId: request))
    }
}

final class ManagementJob {
    let fingerprint: String
    var response: SupervisorResponse?

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }
}

package final class SupervisorCore: @unchecked Sendable {
    package let epoch = UUID()
    package let tools: AppleTools
    private let source: URL
    private let cache: URL
    private let runtime: PrivateDirectory
    private let condition = NSCondition()
    private var sessions: [UUID: SessionRecord] = [:]
    private var jobs: [UUID: ManagementJob] = [:]
    private var jobBytes = 0
    private var artifactBytes = 0
    private static let origin = ContinuousClock.now

    package init(source: URL, cache: URL, tools: AppleTools) throws {
        self.source = source
        self.cache = cache
        self.tools = tools
        runtime = try PrivateDirectory(
            try SupervisorEndpoint.directory().url.appendingPathComponent("sessions-v2"))
    }

    package func handle(_ request: SupervisorRequest) -> SupervisorResponse {
        let started = ContinuousClock.now
        let response = dispatch(request)
        let elapsed = started.duration(to: .now).components
        DiagnosticLog.record(
            "supervisor.request",
            [
                "operation": request.operation, "request": request.requestId.uuidString,
                "session": request.sessionId?.uuidString ?? "none",
                "completion": response.completion.rawValue,
                "errorCode": response.error?.code ?? "none",
                "errorMessage": response.error?.message ?? "none",
                "milliseconds":
                    "\(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)",
            ])
        return response
    }

    private func dispatch(_ request: SupervisorRequest) -> SupervisorResponse {
        do {
            if request.operation == "supervisor.shutdown" {
                guard !hasLiveSessions else {
                    return failure(request, "device_busy", "Supervisor still owns live sessions.")
                }
                return SupervisorResponse(
                    request: request, epoch: epoch, completion: .finished, data: SupervisorData())
            }
            try validate(request)
            if Self.effectfulManagement.contains(request.operation) {
                return management(request)
            }
            return try route(request)
        } catch let failure as RuntimeFailure {
            return self.failure(request, failure.code, failure.message)
        } catch {
            DiagnosticLog.failure(
                "supervisor.internal_failure", error, ["operation": request.operation])
            return failure(request, "internal_failure", "Supervisor operation failed closed.")
        }
    }

    private func route(_ request: SupervisorRequest) throws -> SupervisorResponse {
        switch request.operation {
        case "doctor": return doctor(request)
        case "setup": return setup(request)
        case "logs": return logs(request)
        case "sim.list": return try simulatorList(request)
        case "sim.create": return try simulatorCreate(request)
        case "sim.boot": return try simulatorBoot(request)
        case "sim.shutdown": return try simulatorShutdown(request)
        case "app.build": return try appBuild(request)
        case "app.install": return try appInstall(request)
        case "app.launch": return try appLaunch(request)
        case "app.terminate": return try appTerminate(request)
        case "app.logs": return try appLogs(request)
        case "app.crashes": return try appCrashes(request)
        case "run": return run(request)
        case "session.start": return try start(request)
        case "session.list": return list(request)
        case "session.status": return status(request)
        case "session.recover": return try recover(request)
        case "session.stop": return try stop(request)
        default:
            guard let operation = SessionOperation(rawValue: request.operation) else {
                return failure(request, "invalid_argument", "Unsupported supervisor operation.")
            }
            return try ui(request, operation: operation)
        }
    }

    private static let effectfulManagement: Set<String> = [
        "sim.create", "sim.boot", "sim.shutdown", "app.build", "app.install",
        "app.launch", "app.terminate", "setup", "run",
        "session.start", "session.recover", "session.stop",
    ]

    private func management(_ request: SupervisorRequest) -> SupervisorResponse {
        let fingerprint = self.fingerprint(request)
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(request.remainingMilliseconds)))
        condition.lock()
        if let job = jobs[request.requestId] {
            guard job.fingerprint == fingerprint else {
                condition.unlock()
                return failure(
                    request, "request_id_conflict", "Request UUID has different parameters.")
            }
            while job.response == nil, ContinuousClock.now < deadline {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            }
            let response = job.response
            condition.unlock()
            return response
                ?? failure(request, "deadline_exceeded", "Original request is still running.")
        }
        let requestBytes = (try? JSONEncoder().encode(request).count) ?? 65_536
        let reservation = requestBytes + 8_192
        guard jobs.count < 10_000, jobBytes + reservation <= 16 * 1_024 * 1_024 else {
            condition.unlock()
            return failure(request, "session_limit", "Management receipt registry is full.")
        }
        let job = ManagementJob(fingerprint: fingerprint)
        jobs[request.requestId] = job
        jobBytes += reservation
        condition.unlock()
        let response: SupervisorResponse
        do { response = try route(request) } catch let error as RuntimeFailure {
            response = failure(request, error.code, error.message)
        } catch {
            DiagnosticLog.failure(
                "management.internal_failure", error, ["operation": request.operation])
            response = failure(request, "internal_failure", "Management operation failed closed.")
        }
        condition.lock()
        job.response = response
        condition.broadcast()
        condition.unlock()
        return response
    }

    package var hasLiveSessions: Bool {
        condition.lock()
        defer { condition.unlock() }
        return sessions.values.contains { $0.machine.state != .stopped }
    }

    package func expireSessions() {
        condition.lock()
        let now = ContinuousClock.now
        var retiring: [SessionRecord] = []
        for record in sessions.values where record.machine.state != .stopped {
            let idle = record.lastActivity.duration(to: now) >= .seconds(600)
            guard now >= record.hardDeadline || idle else { continue }
            if record.machine.state == .executing, let active = record.machine.active {
                record.machine.timeout(id: active.id)
                record.cancelEffect = true
            }
            if !record.effectRunning && record.machine.state != .recovering
                && record.machine.state != .stopping
            {
                record.machine.requestStop()
                retiring.append(record)
            }
        }
        condition.broadcast()
        condition.unlock()
        for record in retiring { retireExpired(record) }
    }

    private func validate(_ request: SupervisorRequest) throws {
        try requireRuntime(request.schemaVersion == 17, "protocol_mismatch", "Unsupported schema.")
        try requireRuntime(
            request.toolchain == tools.identity,
            "toolchain_mismatch", "Supervisor is pinned to another exact Xcode toolchain.")
        try requireRuntime(
            (1...1_800_000).contains(request.remainingMilliseconds),
            "invalid_argument", "Invalid remaining deadline.")
    }

    private func simulatorList(_ request: SupervisorRequest) throws -> SupervisorResponse {
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        var data = SupervisorData()
        data.devices = try SimulatorOperations(tools: tools).list(budget: budget)
        data.toolchain = tools.identity
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func simulatorCreate(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let parameters = request.management, let name = parameters.name,
            let runtime = parameters.runtime, let deviceType = parameters.deviceType
        else {
            return failure(request, "invalid_argument", "Create requires name/runtime/device type.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        let simulators = try SimulatorOperations(tools: tools)
        let id = try simulators.create(
            name: name, runtime: runtime, deviceType: deviceType, budget: budget)
        var data = SupervisorData()
        data.devices = [try simulators.device(id, budget: budget)]
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func simulatorBoot(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.device else {
            return failure(request, "invalid_argument", "Boot requires a device.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        let simulators = try SimulatorOperations(tools: tools)
        try simulators.boot(id, budget: budget)
        var data = SupervisorData()
        data.devices = [try simulators.device(id, budget: budget)]
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func simulatorShutdown(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.device else {
            return failure(request, "invalid_argument", "Shutdown requires a device.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        let simulators = try SimulatorOperations(tools: tools)
        try simulators.shutdown(id, budget: budget)
        var data = SupervisorData()
        data.devices = [try simulators.device(id, budget: budget)]
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func appBuild(_ request: SupervisorRequest) throws -> SupervisorResponse {
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        let report = try discovery(request)
        let destination =
            request.device.map {
                "platform=iOS Simulator,id=\($0.uuidString)"
            } ?? "generic/platform=iOS Simulator"
        let artifact = try AppLifecycle(tools: tools).build(
            BuildRequest(
                report: report, product: request.management?.product, destination: destination),
            budget: budget)
        var data = SupervisorData()
        data.artifact = artifact
        data.toolchain = tools.identity
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func appInstall(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.device, let path = request.management?.path else {
            return failure(request, "invalid_argument", "Install requires device and app path.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        let lifecycle = try AppLifecycle(tools: tools)
        let artifact = try lifecycle.inspect(path: path, budget: budget)
        try lifecycle.install(device: id, artifact: artifact, budget: budget)
        var data = SupervisorData()
        data.artifact = artifact
        data.completedSteps = ["app.install"]
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func appLogs(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.device, let parameters = request.management,
            let bundle = parameters.bundleIdentifier
        else {
            return failure(request, "invalid_argument", "Logs require device and bundle ID.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        var data = SupervisorData()
        data.appLogs = try AppDiagnostics.logs(
            tools: tools, device: id, bundle: bundle, since: parameters.sinceSeconds ?? 60,
            limit: parameters.limit ?? 200, budget: budget)
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func appCrashes(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.device, let parameters = request.management,
            let bundle = parameters.bundleIdentifier
        else {
            return failure(request, "invalid_argument", "Crashes require device and bundle ID.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        var data = SupervisorData()
        data.appCrashes = try AppDiagnostics.crashes(
            tools: tools, device: id, bundle: bundle, since: parameters.sinceSeconds ?? 3_600,
            limit: parameters.limit ?? 10, budget: budget)
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func appLaunch(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.device, let bundle = request.management?.bundleIdentifier else {
            return failure(request, "invalid_argument", "Launch requires device and bundle ID.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        var data = SupervisorData()
        data.launch = try AppLifecycle(tools: tools).launch(
            device: id, bundleIdentifier: bundle, budget: budget)
        data.completedSteps = ["app.launch"]
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func appTerminate(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.device, let bundle = request.management?.bundleIdentifier else {
            return failure(request, "invalid_argument", "Terminate requires device and bundle ID.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        try AppLifecycle(tools: tools).terminate(
            device: id, bundleIdentifier: bundle, budget: budget)
        var data = SupervisorData()
        data.completedSteps = ["app.terminate"]
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func doctor(_ request: SupervisorRequest) -> SupervisorResponse {
        var data = SupervisorData()
        data.toolchain = tools.identity
        data.findings = []
        if !["17E202", "27A266a"].contains(tools.identity.xcodeBuild) {
            data.findings!.append(
                DoctorFinding(
                    severity: "warning", code: "unverified_toolchain",
                    message: "This exact Xcode build has not passed ControlKit acceptance.",
                    provenance: tools.identity.developerDirectory))
        }
        do {
            _ = try tools.run(["xcodebuild", "-checkFirstLaunchStatus"])
        } catch {
            DiagnosticLog.failure("doctor.first_launch", error)
            data.findings!.append(
                DoctorFinding(
                    severity: "error", code: "xcode_first_launch",
                    message: "Xcode first-launch setup or license acceptance is incomplete.",
                    provenance: tools.identity.developerDirectory))
        }
        do {
            data.devices = try SimulatorOperations(tools: tools).list()
            if data.devices!.isEmpty {
                data.findings!.append(
                    DoctorFinding(
                        severity: "error", code: "simulator_missing",
                        message: "No available simulator devices/runtimes were found.",
                        provenance: nil))
            }
        } catch {
            DiagnosticLog.failure("doctor.simulators", error)
            data.findings!.append(
                DoctorFinding(
                    severity: "error", code: "simulator_unavailable",
                    message: "Simulator inventory could not be read.", provenance: nil))
        }
        do {
            let report = try discoveryReport(request)
            if report.buildServerFile == nil {
                data.findings!.append(Self.buildServerFinding(root: report.root))
            }
            for choice in report.requiredChoices {
                data.findings!.append(
                    DoctorFinding(
                        severity: "warning", code: "configuration_missing",
                        message: "Repository requires an explicit \(choice).",
                        provenance: report.root))
            }
            for finding in report.findings {
                data.findings!.append(
                    DoctorFinding(
                        severity: "warning", code: finding.code, message: finding.message,
                        provenance: finding.file))
            }
        } catch {
            DiagnosticLog.failure("doctor.discovery", error)
            data.findings!.append(
                DoctorFinding(
                    severity: "error", code: "discovery_failed",
                    message: "Repository discovery failed; run setup with explicit choices.",
                    provenance: request.management?.workingDirectory))
        }
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func setup(_ request: SupervisorRequest) -> SupervisorResponse {
        do {
            let report = try discoveryReport(request)
            var data = SupervisorData()
            data.findings = report.requiredChoices.map {
                DoctorFinding(
                    severity: "warning", code: "configuration_missing",
                    message: "Choose \($0).", provenance: report.root)
            }
            if report.buildServerFile == nil {
                data.findings!.insert(Self.buildServerFinding(root: report.root), at: 0)
            }
            guard request.management?.write == true else {
                return SupervisorResponse(
                    request: request, epoch: epoch, completion: .finished, data: data)
            }
            let configuration = try setupConfiguration(request)
            let url = URL(fileURLWithPath: report.root).appendingPathComponent("controlkit.json")
            try ConfigurationWriter.write(
                configuration, to: url, replace: request.management?.replaceExisting == true)
            data.configurationPath = url.path
            data.findings = [
                DoctorFinding(
                    severity: "info", code: "configuration_written",
                    message: "Wrote explicit shared ControlKit settings.", provenance: url.path)
            ]
            return SupervisorResponse(
                request: request, epoch: epoch, completion: .finished, data: data)
        } catch let error as RuntimeFailure {
            return failure(request, error.code, error.message)
        } catch {
            DiagnosticLog.failure("setup.failed", error)
            return failure(request, "configuration_invalid", "Setup failed closed.")
        }
    }

    private func logs(_ request: SupervisorRequest) -> SupervisorResponse {
        guard let id = request.sessionId else {
            return failure(request, "invalid_argument", "Logs require a session.")
        }
        condition.lock()
        defer { condition.unlock() }
        guard let record = sessions[id] else {
            return failure(request, "session_not_found", "Session does not exist.")
        }
        var data = SupervisorData()
        data.logs = record.events
        data.session = record.view(now: Self.now())
        return SupervisorResponse(
            request: request, epoch: epoch, session: id,
            generation: record.machine.generation, completion: .finished, data: data)
    }

    private func discovery(_ request: SupervisorRequest) throws -> DiscoveryReport {
        let report = try discoveryReport(request)
        if let missing = report.failure {
            throw RuntimeFailure(missing.code.rawValue, missing.message)
        }
        return report
    }

    private func discoveryReport(_ request: SupervisorRequest) throws -> DiscoveryReport {
        guard let parameters = request.management, let working = parameters.workingDirectory else {
            throw RuntimeFailure("invalid_argument", "Build requires a working directory.")
        }
        var options = DiscoveryOptions()
        options.projectDirectory = parameters.projectDirectory
        options.profile = parameters.profile
        options.workspace = parameters.workspace
        options.xcodeProject = parameters.xcodeProject
        options.scheme = parameters.scheme
        options.configuration = parameters.configuration
        do {
            return try RepositoryDiscovery.resolve(
                options: options, currentDirectory: URL(fileURLWithPath: working))
        } catch let failure as DiscoveryFailure {
            throw RuntimeFailure(failure.code.rawValue, failure.message)
        }
    }

    private func setupConfiguration(_ request: SupervisorRequest) throws -> Data {
        guard let parameters = request.management else {
            throw RuntimeFailure("invalid_argument", "Setup settings are missing.")
        }
        var settings: [String: String] = [:]
        if let workspace = parameters.workspace { settings["workspace"] = workspace }
        if let project = parameters.xcodeProject { settings["xcodeProject"] = project }
        if let scheme = parameters.scheme { settings["scheme"] = scheme }
        if let configuration = parameters.configuration {
            settings["configuration"] = configuration
        }
        try requireRuntime(
            !settings.isEmpty, "configuration_missing",
            "Provide at least one explicit setting before writing controlkit.json.")
        let profile = parameters.setupProfile ?? "default"
        try validateRuntimeText(profile, limit: 128)
        let object: [String: Any] = [
            "schemaVersion": 1, "defaultProfile": profile,
            "profiles": [profile: settings],
        ]
        return try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func buildServerFinding(root: String) -> DoctorFinding {
        DoctorFinding(
            severity: "info", code: "build_server_missing",
            message: "Prefer buildServer.json; run xcode-build-server config in the repository.",
            provenance: root)
    }

    private func run(_ request: SupervisorRequest) -> SupervisorResponse {
        guard let id = request.device else {
            return failure(
                request, "invalid_argument", "Run requires an explicit simulator device.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        var data = SupervisorData()
        data.completedSteps = []
        // Per-step records show where a long run stalled or failed.
        func completed(_ step: String) {
            data.completedSteps!.append(step)
            DiagnosticLog.record(
                "run.step", ["step": step, "request": request.requestId.uuidString])
        }
        do {
            let lifecycle = try AppLifecycle(tools: tools)
            let simulators = try SimulatorOperations(tools: tools)
            _ = try simulators.device(id, budget: budget)
            let destination = "platform=iOS Simulator,id=\(id.uuidString)"
            let artifact: AppArtifact
            if let path = request.management?.path {
                artifact = try lifecycle.inspect(path: path, budget: budget)
                completed("app.validate")
            } else {
                artifact = try lifecycle.build(
                    BuildRequest(
                        report: try discovery(request), product: request.management?.product,
                        destination: destination),
                    budget: budget)
                completed("app.build")
            }
            data.artifact = artifact
            try simulators.boot(id, budget: budget)
            completed("sim.boot")
            try lifecycle.install(device: id, artifact: artifact, budget: budget)
            completed("app.install")
            data.launch = try lifecycle.launch(
                device: id, bundleIdentifier: artifact.bundleIdentifier, budget: budget)
            completed("app.launch")
            var sessionRequest = request
            sessionRequest.operation = "session.start"
            sessionRequest.app = artifact.bundleIdentifier
            sessionRequest.remainingMilliseconds = try budget.remaining(maximum: 180_000)
            let session = try start(sessionRequest)
            if let error = session.error {
                return failure(
                    request, error.code, error.message,
                    session: session.sessionId, generation: session.helperGeneration,
                    completion: session.completion, data: data)
            }
            completed("session.start")
            data.session = session.data?.session
            return SupervisorResponse(
                request: request, epoch: epoch, session: session.sessionId,
                generation: session.helperGeneration, completion: .finished, data: data)
        } catch let error as RuntimeFailure {
            let completion: SupervisorResponse.Completion =
                error.code == "outcome_unknown" ? .unknown : .finished
            return failure(
                request, error.code, error.message, completion: completion, data: data)
        } catch {
            DiagnosticLog.failure("run.internal_failure", error)
            return failure(
                request, "internal_failure", "Run failed closed.", data: data)
        }
    }

    private func start(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let deviceID = request.device, let app = request.app else {
            return failure(request, "invalid_argument", "Session start requires device and app.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        try validateRuntimeText(app)
        let operations = try SimulatorOperations(tools: tools)
        let device = try operations.device(deviceID, budget: budget)
        try requireRuntime(
            device.state == "Booted", "device_not_booted", "Boot the device explicitly.")
        let claim = try DeviceClaim(
            directory: operations.leases, device: deviceID, operation: "session")
        try claim.begin()
        condition.lock()
        let active = sessions.values.filter { $0.machine.state != .stopped }
        guard active.count < 4, !active.contains(where: { $0.device == deviceID }) else {
            condition.unlock()
            try claim.complete()
            return failure(
                request, "device_busy", "Device already has an owner or session limit reached.")
        }
        let id = UUID()
        let record = SessionRecord(
            id: id, device: deviceID, app: app, claim: claim, created: Self.now())
        record.log("session.starting", request: request.requestId)
        sessions[id] = record
        condition.unlock()
        do {
            let helper = try SessionHelper.start(
                source: source, cache: cache, device: device, app: app, epoch: epoch,
                session: id, generation: 1, launch: UUID(), tools: tools, runtimeRoot: runtime,
                budget: budget)
            condition.lock()
            record.helper = helper
            record.machine.markReady()
            record.log("session.ready", request: request.requestId)
            let view = record.view(now: Self.now())
            condition.broadcast()
            condition.unlock()
            var data = SupervisorData()
            data.session = view
            return SupervisorResponse(
                request: request, epoch: epoch, session: id, generation: 1,
                completion: .finished, data: data)
        } catch let startup as RuntimeFailure {
            return startFailed(request, record: record, failure: startup)
        } catch {
            DiagnosticLog.failure("session.start_failed", error, ["session": id.uuidString])
            return startFailed(
                request, record: record,
                failure: RuntimeFailure(
                    "retirement_unconfirmed", "Helper startup failed without retirement evidence."))
        }
    }

    private func startFailed(
        _ request: SupervisorRequest, record: SessionRecord, failure startup: RuntimeFailure
    ) -> SupervisorResponse {
        // The response may replace this cause with a generic fencing message.
        DiagnosticLog.failure("session.start_failed", startup, ["session": record.id.uuidString])
        var released = false
        if startup.code != "retirement_unconfirmed" {
            do {
                try record.claim?.complete()
                released = true
            } catch {
                DiagnosticLog.failure("session.release_failed", error)
                released = false
            }
        }
        condition.lock()
        record.machine.failStartup()
        if released {
            record.machine.requestStop()
            _ = record.machine.finishStop(runnerRetired: true)
            record.claim = nil
        } else {
            record.retirementUnconfirmed = true
        }
        condition.broadcast()
        condition.unlock()
        let code = released ? startup.code : "retirement_unconfirmed"
        let message =
            released
            ? startup.message
            : "Helper startup failed; device ownership remains fenced."
        return failure(
            request, code, message, session: record.id, generation: 1)
    }

    private func list(_ request: SupervisorRequest) -> SupervisorResponse {
        condition.lock()
        let views = sessions.values.map { $0.view(now: Self.now()) }.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        condition.unlock()
        var data = SupervisorData()
        data.sessions = views
        data.toolchain = tools.identity
        return SupervisorResponse(
            request: request, epoch: epoch, completion: .finished, data: data)
    }

    private func status(_ request: SupervisorRequest) -> SupervisorResponse {
        guard let id = request.sessionId else {
            return failure(request, "invalid_argument", "Session status requires session identity.")
        }
        condition.lock()
        defer { condition.unlock() }
        guard let record = sessions[id] else {
            return failure(request, "session_not_found", "Session does not exist.")
        }
        var data = SupervisorData()
        data.session = record.view(now: Self.now())
        if let receiptID = request.receiptId {
            guard let receipt = record.machine.receipts[receiptID] else {
                return failure(
                    request, "request_not_found", "No receipt exists for that request UUID.",
                    session: id, generation: record.machine.generation)
            }
            data.receipt = Self.receipt(receipt)
        }
        return SupervisorResponse(
            request: request, epoch: epoch, session: id, generation: record.machine.generation,
            completion: .finished, data: data)
    }

    private func ui(_ request: SupervisorRequest, operation: SessionOperation) throws
        -> SupervisorResponse
    {
        guard let id = request.sessionId, let expected = request.helperGeneration else {
            return failure(
                request, "invalid_argument", "UI commands require session and generation.")
        }
        do {
            try request.parameters?.validate(operation: operation.rawValue)
        } catch {
            return failure(
                request, "invalid_argument", "UI command arguments are invalid.",
                session: id, generation: expected)
        }
        if let output = request.output {
            let captures =
                operation == .screenshot
                || (operation == .inspect && request.parameters?.includeScreenshot == true)
            try requireRuntime(captures, "invalid_argument", "Output path requires a screenshot.")
            try ArtifactExport.validate(output)
        }
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(min(120_000, request.remainingMilliseconds))))
        let command = SessionCommand(
            id: request.requestId, fingerprint: fingerprint(request), operation: operation,
            deadline: deadline)
        let dispatched = waitForDispatch(
            request, session: id, generation: expected, command: command, deadline: deadline)
        switch dispatched {
        case .failure(let response): return response
        case .success(let record):
            return execute(request, operation: operation, record: record, deadline: deadline)
        }
    }

    private enum DispatchResult {
        case success(SessionRecord)
        case failure(SupervisorResponse)
    }

    private func waitForDispatch(
        _ request: SupervisorRequest, session id: UUID, generation: UInt64,
        command: SessionCommand, deadline: ContinuousClock.Instant
    ) -> DispatchResult {
        condition.lock()
        defer { condition.unlock() }
        guard let record = sessions[id] else {
            return .failure(failure(request, "session_not_found", "Session does not exist."))
        }
        let admission = record.machine.admit(command, generation: generation)
        if case .rejected(let code) = admission {
            return .failure(
                failure(
                    request, code, "Session rejected the command.",
                    session: id, generation: record.machine.generation))
        }
        if case .duplicate = admission {
            while record.sealingResults.contains(command.id), ContinuousClock.now < deadline {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            }
            if record.sealingResults.contains(command.id) {
                return .failure(
                    failure(
                        request, "busy", "Original result is still being sealed.",
                        session: id, generation: record.machine.generation))
            }
            return .failure(receiptResponse(request, record: record))
        }
        while true {
            if record.machine.queue.first?.id == command.id,
                record.machine.dispatch(now: .now)?.id == command.id
            {
                record.lastActivity = .now
                record.effectRunning = true
                record.cancelEffect = false
                record.log("command.dispatched.\(command.operation.rawValue)", request: command.id)
                return .success(record)
            }
            if ContinuousClock.now >= deadline {
                record.machine.timeout(id: command.id)
                return .failure(receiptResponse(request, record: record))
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func execute(
        _ request: SupervisorRequest, operation: SessionOperation, record: SessionRecord,
        deadline: ContinuousClock.Instant
    ) -> SupervisorResponse {
        guard let helper = record.helper else {
            return finishUnknown(request, record: record)
        }
        do {
            let executed = try helper.execute(
                requestID: request.requestId, operation: operation.rawValue,
                parameters: request.parameters, deadline: deadline,
                cancelled: { [self] in
                    condition.lock()
                    defer { condition.unlock() }
                    return record.cancelEffect
                })
            let reply = executed.0
            let uncertain = reply.effectsUncertain == true
            condition.lock()
            record.effectRunning = false
            record.machine.finish(
                id: request.requestId, generation: helper.identity.helperGeneration,
                succeeded: reply.error == nil, errorCode: reply.error?.code,
                effectsUncertain: uncertain, snapshot: reply.result?.snapshot?.id)
            if !uncertain { record.log("command.finished", request: request.requestId) }
            if !uncertain { record.sealingResults.insert(request.requestId) }
            if uncertain { condition.broadcast() }
            condition.unlock()
            if uncertain { return finishUnknown(request, record: record) }
            if let error = reply.error {
                condition.lock()
                record.sealingResults.remove(request.requestId)
                condition.broadcast()
                condition.unlock()
                return failure(
                    request, error.code, error.message, session: record.id,
                    generation: record.machine.generation, completion: .finished)
            }
            return finishSuccess(
                request, record: record, result: reply.result, artifact: executed.1)
        } catch {
            DiagnosticLog.failure(
                "command.outcome_unknown", error,
                ["session": record.id.uuidString, "operation": operation.rawValue])
            return finishUnknown(request, record: record)
        }
    }

    private func finishSuccess(
        _ request: SupervisorRequest, record: SessionRecord, result: UIResult?, artifact: Data?
    ) -> SupervisorResponse {
        var data = SupervisorData()
        data.ui = result
        var reservedArtifactBytes = 0
        var privateArtifactPublished = false
        do {
            if let artifact, let manifest = result?.screenshot {
                condition.lock()
                let fits = artifactBytes + artifact.count <= 256 * 1_024 * 1_024
                if fits {
                    artifactBytes += artifact.count
                    reservedArtifactBytes = artifact.count
                }
                condition.unlock()
                try requireRuntime(
                    fits, "resource_limit", "Stored screenshot budget reached 256 MiB.")
                let stored = "artifact-\(manifest.id.uuidString).png"
                let privatePath = record.helper!.runtime.url.appendingPathComponent(stored).path
                try ArtifactExport.write(artifact, to: privatePath)
                privateArtifactPublished = true
                data.screenshotPath = privatePath
                if let output = request.output {
                    try ArtifactExport.write(artifact, to: output)
                    data.screenshotPath = URL(fileURLWithPath: output).standardizedFileURL.path
                }
            }
        } catch let artifactFailure as RuntimeFailure {
            condition.lock()
            if !privateArtifactPublished { artifactBytes -= reservedArtifactBytes }
            record.machine.markFinishedError(id: request.requestId, code: artifactFailure.code)
            record.sealingResults.remove(request.requestId)
            condition.broadcast()
            condition.unlock()
            return failure(
                request, artifactFailure.code, artifactFailure.message,
                session: record.id, generation: record.machine.generation, completion: .finished)
        } catch {
            DiagnosticLog.failure("artifact.failed", error, ["session": record.id.uuidString])
            condition.lock()
            if !privateArtifactPublished { artifactBytes -= reservedArtifactBytes }
            record.machine.markFinishedError(id: request.requestId, code: "artifact_failed")
            record.sealingResults.remove(request.requestId)
            condition.broadcast()
            condition.unlock()
            return failure(
                request, "artifact_failed", "Screenshot completed but artifact publication failed.",
                session: record.id, generation: record.machine.generation, completion: .finished)
        }
        condition.lock()
        record.store(data, request: request.requestId)
        record.sealingResults.remove(request.requestId)
        condition.broadcast()
        condition.unlock()
        return SupervisorResponse(
            request: request, epoch: epoch, session: record.id,
            generation: record.machine.generation, completion: .finished, data: data)
    }

    private func finishUnknown(
        _ request: SupervisorRequest, record: SessionRecord
    ) -> SupervisorResponse {
        condition.lock()
        record.effectRunning = false
        record.machine.finish(
            id: request.requestId, generation: record.machine.generation,
            succeeded: false, effectsUncertain: true)
        record.log("command.unknown", request: request.requestId)
        condition.broadcast()
        condition.unlock()
        return failure(
            request, "outcome_unknown",
            "Command may have executed; recover and inspect before mutation.",
            session: record.id, generation: record.machine.generation, completion: .unknown)
    }

    private func recover(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.sessionId else {
            return failure(request, "invalid_argument", "Recovery requires session identity.")
        }
        let budget = OperationBudget(milliseconds: request.remainingMilliseconds)
        condition.lock()
        guard let record = sessions[id] else {
            condition.unlock()
            return failure(request, "session_not_found", "Session does not exist.")
        }
        if record.retirementUnconfirmed {
            condition.unlock()
            return failure(
                request, "retirement_unconfirmed", "Runner ownership is unverifiable.",
                session: id, generation: record.machine.generation)
        }
        guard !record.effectRunning, record.machine.beginRecovery(), let old = record.helper
        else {
            condition.unlock()
            return failure(request, "session_not_ready", "Only a fenced session can recover.")
        }
        let generation = record.machine.generation + 1
        record.log("session.recovering", request: request.requestId)
        condition.unlock()
        do {
            try old.retire()
        } catch {
            DiagnosticLog.failure("recover.retire_failed", error, ["session": id.uuidString])
            condition.lock()
            record.machine.failRecovery()
            record.retirementUnconfirmed = true
            condition.broadcast()
            condition.unlock()
            return failure(
                request, "retirement_unconfirmed",
                "Old runner remains unverified; device is fenced.",
                session: id, generation: record.machine.generation)
        }
        return launchReplacement(
            request, record: record, generation: generation, budget: budget)
    }

    private func launchReplacement(
        _ request: SupervisorRequest, record: SessionRecord, generation: UInt64,
        budget: OperationBudget
    ) -> SupervisorResponse {
        do {
            let device = try SimulatorOperations(tools: tools).device(
                record.device, budget: budget)
            let helper = try SessionHelper.start(
                source: source, cache: cache, device: device, app: record.app, epoch: epoch,
                session: record.id, generation: generation, launch: UUID(), tools: tools,
                runtimeRoot: runtime, budget: budget)
            condition.lock()
            record.helper = helper
            precondition(record.machine.finishRecovery(oldRunnerRetired: true))
            record.log("session.needs_inspection", request: request.requestId)
            let view = record.view(now: Self.now())
            condition.broadcast()
            condition.unlock()
            var data = SupervisorData()
            data.session = view
            return SupervisorResponse(
                request: request, epoch: epoch, session: record.id, generation: generation,
                completion: .finished, data: data)
        } catch let replacement as RuntimeFailure {
            condition.lock()
            record.machine.failRecovery()
            record.retirementUnconfirmed = replacement.code == "retirement_unconfirmed"
            condition.broadcast()
            condition.unlock()
            let code = record.retirementUnconfirmed ? "retirement_unconfirmed" : replacement.code
            return failure(
                request, code, replacement.message,
                session: record.id, generation: record.machine.generation)
        } catch {
            DiagnosticLog.failure(
                "recover.replace_failed", error, ["session": record.id.uuidString])
            condition.lock()
            record.machine.failRecovery()
            record.retirementUnconfirmed = true
            condition.broadcast()
            condition.unlock()
            return failure(
                request, "retirement_unconfirmed",
                "Replacement helper failed without retirement evidence; device is fenced.",
                session: record.id, generation: record.machine.generation)
        }
    }

    private func stop(_ request: SupervisorRequest) throws -> SupervisorResponse {
        guard let id = request.sessionId else {
            return failure(request, "invalid_argument", "Stop requires session identity.")
        }
        condition.lock()
        guard let record = sessions[id] else {
            condition.unlock()
            return failure(request, "session_not_found", "Session does not exist.")
        }
        if record.retirementUnconfirmed {
            condition.unlock()
            return failure(
                request, "retirement_unconfirmed",
                "Runner ownership is unverifiable; device lease remains fenced.",
                session: id, generation: record.machine.generation)
        }
        if record.machine.state == .stopped {
            var data = SupervisorData()
            data.session = record.view(now: Self.now())
            let response = SupervisorResponse(
                request: request, epoch: epoch, session: id,
                generation: record.machine.generation, completion: .finished, data: data)
            condition.unlock()
            return response
        }
        record.machine.requestStop()
        record.log("session.stopping", request: request.requestId)
        record.cancelEffect = true
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while record.effectRunning, ContinuousClock.now < cancellationDeadline {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard !record.effectRunning else {
            condition.unlock()
            return failure(
                request, "outcome_unknown",
                "Active operation has not retired; repeat stop to continue bounded cleanup.",
                session: id, generation: record.machine.generation, completion: .unknown)
        }
        let helper = record.helper
        condition.unlock()
        do {
            try helper?.retire()
            condition.lock()
            _ = record.machine.finishStop(runnerRetired: true)
            record.log("session.stopped", request: request.requestId)
            try record.claim?.complete()
            record.claim = nil
            record.helper = nil
            let view = record.view(now: Self.now())
            condition.broadcast()
            condition.unlock()
            var data = SupervisorData()
            data.session = view
            return SupervisorResponse(
                request: request, epoch: epoch, session: id,
                generation: record.machine.generation, completion: .finished, data: data)
        } catch {
            DiagnosticLog.failure("stop.retire_failed", error, ["session": id.uuidString])
            condition.lock()
            _ = record.machine.finishStop(runnerRetired: false)
            condition.broadcast()
            condition.unlock()
            return failure(
                request, "retirement_unconfirmed",
                "Runner retirement failed; lease remains fenced.",
                session: id, generation: record.machine.generation)
        }
    }

    private func receiptResponse(
        _ request: SupervisorRequest, record: SessionRecord
    ) -> SupervisorResponse {
        var data = SupervisorData()
        guard let receipt = record.machine.receipts[request.requestId] else {
            return failure(
                request, "request_not_found", "No receipt exists for this request.",
                session: record.id, generation: record.machine.generation)
        }
        data.receipt = Self.receipt(receipt)
        if receipt.status == .unknown {
            return failure(
                request, "outcome_unknown", "Existing receipt is uncertain.",
                session: record.id, generation: record.machine.generation, completion: .unknown)
        }
        if receipt.status == .queued || receipt.status == .dispatched {
            return SupervisorResponse(
                request: request, epoch: epoch, session: record.id,
                generation: record.machine.generation, completion: .notDispatched,
                error: SupervisorError(code: "busy", message: "Original request is still running."),
                data: data)
        }
        if receipt.status == .notDispatched {
            return SupervisorResponse(
                request: request, epoch: epoch, session: record.id,
                generation: record.machine.generation, completion: .notDispatched,
                error: SupervisorError(
                    code: receipt.errorCode ?? "cancelled", message: "Request was not dispatched."),
                data: data)
        }
        if let errorCode = receipt.errorCode {
            return SupervisorResponse(
                request: request, epoch: epoch, session: record.id,
                generation: record.machine.generation, completion: .finished,
                error: SupervisorError(
                    code: errorCode, message: "Original request finished with error."),
                data: data)
        }
        if !receipt.resultAvailable {
            return SupervisorResponse(
                request: request, epoch: epoch, session: record.id,
                generation: record.machine.generation, completion: .finished,
                error: SupervisorError(
                    code: "result_expired", message: "Full result expired; receipt is retained."),
                data: data)
        }
        if let stored = record.results[request.requestId] {
            return SupervisorResponse(
                request: request, epoch: epoch, session: record.id,
                generation: record.machine.generation, completion: .finished, data: stored)
        }
        return SupervisorResponse(
            request: request, epoch: epoch, session: record.id,
            generation: record.machine.generation, completion: .finished, data: data)
    }

    private func retireExpired(_ record: SessionRecord) {
        let retired: Bool
        do {
            try record.helper?.retire()
            try record.claim?.complete()
            record.claim = nil
            retired = true
        } catch {
            DiagnosticLog.failure("expire.retire_failed", error, ["session": record.id.uuidString])
            retired = false
        }
        condition.lock()
        _ = record.machine.finishStop(runnerRetired: retired)
        if retired { record.helper = nil }
        condition.broadcast()
        condition.unlock()
    }

    private func failure(
        _ request: SupervisorRequest, _ code: String, _ message: String,
        session: UUID? = nil, generation: UInt64? = nil,
        completion: SupervisorResponse.Completion = .notDispatched,
        data: SupervisorData? = nil
    ) -> SupervisorResponse {
        SupervisorResponse(
            request: request, epoch: epoch, session: session, generation: generation,
            completion: completion, error: SupervisorError(code: code, message: message), data: data
        )
    }

    private static func receipt(_ value: SessionReceipt) -> ReceiptView {
        ReceiptView(
            requestId: value.requestId, operation: value.operation, status: value.status,
            errorCode: value.errorCode, resultAvailable: value.resultAvailable)
    }

    private func fingerprint(_ request: SupervisorRequest) -> String {
        var data = Data(request.operation.utf8)
        if let session = request.sessionId { data.append(Data(session.uuidString.utf8)) }
        if let generation = request.helperGeneration { data.append(Data("\(generation)".utf8)) }
        if let device = request.device { data.append(Data(device.uuidString.utf8)) }
        if let app = request.app { data.append(Data(app.utf8)) }
        if let output = request.output { data.append(Data(output.utf8)) }
        if let parameters = request.parameters, let encoded = try? JSONEncoder().encode(parameters)
        {
            data.append(encoded)
        }
        if let management = request.management, let encoded = try? JSONEncoder().encode(management)
        {
            data.append(encoded)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func now() -> UInt64 {
        let parts = origin.duration(to: .now).components
        return UInt64(parts.seconds) * 1_000
            + UInt64(parts.attoseconds) / 1_000_000_000_000_000
    }
}
