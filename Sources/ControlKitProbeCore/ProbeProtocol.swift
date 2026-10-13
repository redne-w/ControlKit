import Foundation

/// These are experimental limits, not the production protocol contract.
public enum ProbeLimits {
    public static let requestBytes = 65_536
    public static let responseBytes = 16 * 1_024 * 1_024
    public static let elements = 256
    public static let treeDepth = 32
    public static let textCharacters = 4_096
    public static let commands = 200
    public static let lifetimeSeconds: TimeInterval = 600
}

public enum ProbeOperation: String, Codable, CaseIterable, Sendable {
    case ping, inspect, tap, type, swipe, screenshot, stop
}

public struct ProbeRequest: Codable, Sendable {
    public var version = 1
    public var id: UUID
    public var token: String
    public var operation: ProbeOperation
    public var identifier: String?
    public var text: String?

    public init(
        id: UUID = UUID(), token: String, operation: ProbeOperation,
        identifier: String? = nil, text: String? = nil
    ) {
        self.id = id
        self.token = token
        self.operation = operation
        self.identifier = identifier
        self.text = text
    }

    public func validate() throws {
        guard version == 1 else {
            throw ProbeFailure("unsupported_version", "Expected probe protocol version 1.")
        }
        guard (32...128).contains(token.utf8.count) else {
            throw ProbeFailure("invalid_token", "A 32–128 byte runtime token is required.")
        }
        if let identifier {
            guard !identifier.isEmpty, identifier.count <= ProbeLimits.textCharacters else {
                throw ProbeFailure("invalid_identifier", "Identifier is empty or too long.")
            }
        }
        if let text {
            guard text.count <= ProbeLimits.textCharacters else {
                throw ProbeFailure("invalid_text", "Text exceeds the probe limit.")
            }
        }
        switch operation {
        case .tap, .swipe:
            guard identifier != nil, text == nil else {
                throw ProbeFailure("invalid_arguments", "This operation requires only --id.")
            }
        case .type:
            guard identifier != nil, text != nil else {
                throw ProbeFailure("invalid_arguments", "Typing requires --id and --text.")
            }
        case .ping, .inspect, .screenshot, .stop:
            guard identifier == nil, text == nil else {
                throw ProbeFailure("invalid_arguments", "This operation takes no element or text.")
            }
        }
    }
}

public struct ProbeFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct ProbeElement: Codable, Sendable {
    public let index: Int
    public let parent: Int?
    public let type: UInt
    public let identifier: String
    public let label: String
    public let value: String?
    public let enabled: Bool
    public let frame: ProbeFrame

    public init(
        index: Int, parent: Int?, type: UInt, identifier: String, label: String,
        value: String?, enabled: Bool, frame: ProbeFrame
    ) {
        self.index = index
        self.parent = parent
        self.type = type
        self.identifier = identifier
        self.label = label
        self.value = value
        self.enabled = enabled
        self.frame = frame
    }
}

public struct ProbeFrame: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ProbeResponse: Codable, Sendable {
    public var version = 1
    public var id: UUID
    public var ok = true
    public var elapsedMilliseconds: Double = 0
    public var error: ProbeFailure?
    public var elements: [ProbeElement]?
    public var truncated: Bool?
    public var screenshotPNG: Data?
    public var screenshotPath: String?
    public var orientation: Int?
    public var screenScale: Double?
    public var coordinateSpace: String?

    public init(id: UUID) {
        self.id = id
    }
}
