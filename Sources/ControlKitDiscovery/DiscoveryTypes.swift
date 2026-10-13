import Foundation

package struct DiscoveryOptions: Sendable {
    package var projectDirectory: String?
    package var profile: String?
    package var workspace: String?
    package var xcodeProject: String?
    package var scheme: String?
    package var configuration: String?
    package var timeoutMilliseconds: UInt64 = 5_000

    package init() {}
}

package struct DiscoveryFailure: Error, Codable, Equatable, Sendable {
    package enum Code: String, Codable, Sendable {
        case invalidConfiguration = "invalid_configuration"
        case configurationMissing = "configuration_missing"
        case configurationAmbiguous = "configuration_ambiguous"
        case resourceLimit = "resource_limit"
        case filesystemError = "filesystem_error"
        case deadlineExceeded = "deadline_exceeded"
    }
    package let code: Code
    package let message: String

    package init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

package struct Provenance: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case explicit
        case profile
        case buildServer
        case discovery
    }
    package let kind: Kind
    package let file: String?
    package let profile: String?
}

package struct DiscoveredValue: Codable, Equatable, Sendable {
    package let value: String
    package let source: Provenance
}

package struct BuildContainer: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case project, workspace }
    package let kind: Kind
    package let path: String
    package let source: Provenance
}

package struct DiscoveryFinding: Codable, Equatable, Sendable {
    package let code: String
    package let message: String
    package let file: String?
}

package struct DiscoveryReport: Encodable, Equatable, Sendable {
    package let root: String
    package let rootSource: String
    package var buildServerFile: String?
    package var controlkitFile: String?
    package var selectedProfile: String?
    package var availableProfiles: [String] = []
    package var container: BuildContainer?
    package var scheme: DiscoveredValue?
    package var configuration: DiscoveredValue?
    package var candidates: [BuildContainer] = []
    package var requiredChoices: [String] = []
    package var findings: [DiscoveryFinding] = []
    // Filesystem shape is not evidence of valid schemes, configurations, destinations, or builds.
    package let validation = "filesystem_only"

    package var readyForXcodeValidation: Bool { requiredChoices.isEmpty }

    package var failure: DiscoveryFailure? {
        guard !requiredChoices.isEmpty else { return nil }
        if requiredChoices.contains("container"), candidates.count > 1 {
            return DiscoveryFailure(
                .configurationAmbiguous, "Choose one workspace or Xcode project explicitly.")
        }
        return DiscoveryFailure(
            .configurationMissing, "Required choices: \(requiredChoices.joined(separator: ", ")).")
    }
}
