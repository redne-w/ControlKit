import ControlKitDiscovery
import ControlKitRuntime
import ControlKitSession
import ControlKitWire
import Foundation

package struct SupervisorRequest: Codable, Sendable {
    package let schemaVersion: Int
    package var requestId: UUID
    package var operation: String
    package let toolchain: ToolchainIdentity
    package var remainingMilliseconds: UInt64
    package var sessionId: UUID?
    package var helperGeneration: UInt64?
    package var receiptId: UUID?
    package var device: UUID?
    package var app: String?
    package var parameters: UIParameters?
    package var management: ManagementParameters?
    package var output: String?

    package init(
        requestId: UUID = UUID(), operation: String, toolchain: ToolchainIdentity,
        remainingMilliseconds: UInt64
    ) {
        schemaVersion = 18
        self.requestId = requestId
        self.operation = operation
        self.toolchain = toolchain
        self.remainingMilliseconds = remainingMilliseconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, requestId, operation, toolchain, remainingMilliseconds
        case sessionId, helperGeneration, receiptId, device, app, parameters, management, output
    }

    package init(from decoder: Decoder) throws {
        let unknown = try decoder.container(keyedBy: SupervisorCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard unknown.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown request field."))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        requestId = try values.decode(UUID.self, forKey: .requestId)
        operation = try values.decode(String.self, forKey: .operation)
        toolchain = try values.decode(ToolchainIdentity.self, forKey: .toolchain)
        remainingMilliseconds = try values.decode(UInt64.self, forKey: .remainingMilliseconds)
        sessionId = try values.decodeIfPresent(UUID.self, forKey: .sessionId)
        helperGeneration = try values.decodeIfPresent(UInt64.self, forKey: .helperGeneration)
        receiptId = try values.decodeIfPresent(UUID.self, forKey: .receiptId)
        device = try values.decodeIfPresent(UUID.self, forKey: .device)
        app = try values.decodeIfPresent(String.self, forKey: .app)
        parameters = try values.decodeIfPresent(UIParameters.self, forKey: .parameters)
        management = try values.decodeIfPresent(ManagementParameters.self, forKey: .management)
        output = try values.decodeIfPresent(String.self, forKey: .output)
    }
}

package struct ManagementParameters: Codable, Sendable {
    package var workingDirectory: String?
    package var projectDirectory: String?
    package var profile: String?
    package var setupProfile: String?
    package var workspace: String?
    package var xcodeProject: String?
    package var scheme: String?
    package var configuration: String?
    package var product: String?
    package var path: String?
    package var bundleIdentifier: String?
    package var name: String?
    package var runtime: String?
    package var deviceType: String?
    package var write: Bool?
    package var replaceExisting: Bool?
    package var sinceSeconds: Int?
    package var limit: Int?

    package init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case workingDirectory, projectDirectory, profile, setupProfile, workspace, xcodeProject
        case scheme, configuration, product, path, bundleIdentifier, name, runtime, deviceType
        case write, replaceExisting, sinceSeconds, limit
    }

    package init(from decoder: Decoder) throws {
        let unknown = try decoder.container(keyedBy: SupervisorCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard unknown.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown management field.")
            )
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
        projectDirectory = try values.decodeIfPresent(String.self, forKey: .projectDirectory)
        profile = try values.decodeIfPresent(String.self, forKey: .profile)
        setupProfile = try values.decodeIfPresent(String.self, forKey: .setupProfile)
        workspace = try values.decodeIfPresent(String.self, forKey: .workspace)
        xcodeProject = try values.decodeIfPresent(String.self, forKey: .xcodeProject)
        scheme = try values.decodeIfPresent(String.self, forKey: .scheme)
        configuration = try values.decodeIfPresent(String.self, forKey: .configuration)
        product = try values.decodeIfPresent(String.self, forKey: .product)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        runtime = try values.decodeIfPresent(String.self, forKey: .runtime)
        deviceType = try values.decodeIfPresent(String.self, forKey: .deviceType)
        write = try values.decodeIfPresent(Bool.self, forKey: .write)
        replaceExisting = try values.decodeIfPresent(Bool.self, forKey: .replaceExisting)
        sinceSeconds = try values.decodeIfPresent(Int.self, forKey: .sinceSeconds)
        limit = try values.decodeIfPresent(Int.self, forKey: .limit)
    }
}

private struct SupervisorCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(intValue: Int) { return nil }
    init(stringValue: String) { self.stringValue = stringValue }
}

package struct SupervisorError: Codable, Equatable, Sendable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

package struct SessionView: Codable, Sendable {
    package let id: UUID
    package let device: UUID
    package let app: String
    package let state: SessionState
    package let generation: UInt64
    package let createdMonotonicMilliseconds: UInt64
    package let hardDeadlineMonotonicMilliseconds: UInt64
}

package struct ReceiptView: Codable, Sendable {
    package let requestId: UUID
    package let operation: SessionOperation
    package let status: ReceiptStatus
    package let errorCode: String?
    package let resultAvailable: Bool
}

package struct SupervisorData: Codable, Sendable {
    package var session: SessionView?
    package var sessions: [SessionView]?
    package var receipt: ReceiptView?
    package var ui: UIResult?
    package var screenshotPath: String?
    package var toolchain: ToolchainIdentity?
    package var devices: [SimulatorDevice]?
    package var artifact: AppArtifact?
    package var launch: LaunchResult?
    package var completedSteps: [String]?
    package var findings: [DoctorFinding]?
    package var configurationPath: String?
    package var logs: [DiagnosticEvent]?
    package var appLogs: AppLogResult?
    package var appCrashes: AppCrashResult?
    package var cacheClean: CacheCleanResult?

    package init() {}
}

package struct DoctorFinding: Codable, Sendable {
    package let severity: String
    package let code: String
    package let message: String
    package let provenance: String?
}

package struct DiagnosticEvent: Codable, Sendable {
    package let monotonicMilliseconds: UInt64
    package let code: String
    package let requestId: UUID?
}

package struct SupervisorResponse: Codable, Sendable {
    package enum Completion: String, Codable, Sendable {
        case notDispatched = "not_dispatched"
        case finished, unknown
    }

    package let schemaVersion: Int
    package let requestId: UUID
    package let supervisorEpoch: UUID?
    package let sessionId: UUID?
    package let helperGeneration: UInt64?
    package let ok: Bool
    package let completion: Completion
    package let error: SupervisorError?
    package let data: SupervisorData?

    package init(
        request: SupervisorRequest, epoch: UUID?, session: UUID? = nil,
        generation: UInt64? = nil, completion: Completion, error: SupervisorError? = nil,
        data: SupervisorData? = nil
    ) {
        schemaVersion = 1
        requestId = request.requestId
        supervisorEpoch = epoch
        sessionId = session
        helperGeneration = generation
        ok = error == nil
        self.completion = completion
        self.error = error
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, requestId, supervisorEpoch, sessionId, helperGeneration
        case ok, completion, error, data
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        requestId = try values.decode(UUID.self, forKey: .requestId)
        supervisorEpoch = try values.decodeIfPresent(UUID.self, forKey: .supervisorEpoch)
        sessionId = try values.decodeIfPresent(UUID.self, forKey: .sessionId)
        helperGeneration = try values.decodeIfPresent(UInt64.self, forKey: .helperGeneration)
        ok = try values.decode(Bool.self, forKey: .ok)
        completion = try values.decode(Completion.self, forKey: .completion)
        error = try values.decodeIfPresent(SupervisorError.self, forKey: .error)
        data = try values.decodeIfPresent(SupervisorData.self, forKey: .data)
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(supervisorEpoch, forKey: .supervisorEpoch)
        try values.encode(sessionId, forKey: .sessionId)
        try values.encode(helperGeneration, forKey: .helperGeneration)
        try values.encode(ok, forKey: .ok)
        try values.encode(completion, forKey: .completion)
        try values.encode(error, forKey: .error)
        try values.encode(data, forKey: .data)
    }
}
