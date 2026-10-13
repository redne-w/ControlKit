import Foundation

struct BuildSettings: Decodable {
    var workspace: String?
    var xcodeProject: String?
    var scheme: String?
    var configuration: String?

    init(
        workspace: String? = nil, xcodeProject: String? = nil, scheme: String? = nil,
        configuration: String? = nil
    ) {
        self.workspace = workspace
        self.xcodeProject = xcodeProject
        self.scheme = scheme
        self.configuration = configuration
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder, allowed: ["workspace", "xcodeProject", "scheme", "configuration"])
        let fields = try decoder.container(keyedBy: ConfigurationKey.self)
        workspace = try fields.decodeIfPresent(String.self, forKey: .init(stringValue: "workspace"))
        xcodeProject = try fields.decodeIfPresent(
            String.self, forKey: .init(stringValue: "xcodeProject"))
        scheme = try fields.decodeIfPresent(String.self, forKey: .init(stringValue: "scheme"))
        configuration = try fields.decodeIfPresent(
            String.self, forKey: .init(stringValue: "configuration"))
    }
}

struct ControlKitConfiguration: Decodable {
    let schemaVersion: Int
    let defaultProfile: String?
    let profiles: [String: BuildSettings]

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["schemaVersion", "defaultProfile", "profiles"])
        let fields = try decoder.container(keyedBy: ConfigurationKey.self)
        schemaVersion = try fields.decode(Int.self, forKey: .init(stringValue: "schemaVersion"))
        defaultProfile = try fields.decodeIfPresent(
            String.self, forKey: .init(stringValue: "defaultProfile"))
        profiles = try fields.decode(
            [String: BuildSettings].self, forKey: .init(stringValue: "profiles"))
    }

    func validate() throws {
        guard schemaVersion == 1 else {
            throw DiscoveryFailure(
                .invalidConfiguration, "Unsupported controlkit.json schemaVersion.")
        }
        guard profiles.count <= DiscoveryLimits.profiles else {
            throw DiscoveryFailure(.resourceLimit, "controlkit.json supports at most 16 profiles.")
        }
        for name in profiles.keys { try validateSetting(name, field: "profile name", limit: 128) }
    }
}

struct ConfigurationLayer {
    let settings: BuildSettings
    let source: Provenance
    let directory: URL
}

struct BuildServerHeader: Decodable {
    let name: String?
    let kind: String?
}

struct BuildServerSettings: Decodable {
    let workspace: String?
    let scheme: String?
}

func validateSetting(_ value: String, field: String, limit: Int = DiscoveryLimits.fieldBytes) throws
{
    guard !value.isEmpty, value.utf8.count <= limit,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
        throw DiscoveryFailure(
            .invalidConfiguration, "Invalid \(field); check its text and length.")
    }
}
