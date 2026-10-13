import Foundation

public enum WireFailure: String, Error, Sendable {
    case invalidFrame, invalidMessage, deadlineExceeded, disconnected, socketFailure
    case authenticationFailed, identityMismatch, protocolMismatch
}

public struct WireIdentity: Codable, Equatable, Sendable {
    public let supervisorEpoch: UUID
    public let sessionId: UUID
    public let helperGeneration: UInt64
    public let launchId: UUID

    public init(epoch: UUID, session: UUID, generation: UInt64, launch: UUID) {
        supervisorEpoch = epoch
        sessionId = session
        helperGeneration = generation
        launchId = launch
    }
}

public struct WireMessage: Codable, Sendable {
    public var protocolVersion = 1
    public let type: String
    public let supervisorEpoch: UUID
    public let sessionId: UUID
    public let helperGeneration: UInt64
    public let launchId: UUID
    public var token: String?
    public var capabilities: [String]?
    public var helperPID: Int32?
    public var simulatorUDID: UUID?
    public var requestId: UUID?
    public var operation: String?
    public var remainingMilliseconds: UInt64?
    public var parameters: UIParameters?
    public var result: UIResult?
    public var error: WireError?
    public var effectsUncertain: Bool?

    public var identity: WireIdentity {
        WireIdentity(
            epoch: supervisorEpoch, session: sessionId, generation: helperGeneration,
            launch: launchId)
    }

    public init(type: String, identity: WireIdentity) {
        self.type = type
        supervisorEpoch = identity.supervisorEpoch
        sessionId = identity.sessionId
        helperGeneration = identity.helperGeneration
        launchId = identity.launchId
    }

    public static let lifecycleCapabilities = [
        "lifecycle.attach", "lifecycle.ping", "lifecycle.stop",
    ]

    public func validateHello(
        identity expected: WireIdentity, token secret: String, device: UUID,
        capabilities expectedCapabilities: [String] = WireMessage.lifecycleCapabilities
    ) throws {
        guard type == "hello", protocolVersion == 1 else { throw WireFailure.protocolMismatch }
        guard identity == expected, identity.helperGeneration > 0, simulatorUDID == device else {
            throw WireFailure.identityMismatch
        }
        guard token == secret, secret.utf8.count == 64 else {
            throw WireFailure.authenticationFailed
        }
        guard capabilities == expectedCapabilities, let helperPID, helperPID > 0 else {
            throw WireFailure.invalidMessage
        }
    }

    public func validateReply(to request: WireMessage) throws {
        guard protocolVersion == 1, type == "reply", identity == request.identity,
            requestId == request.requestId, operation == request.operation
        else { throw WireFailure.identityMismatch }
    }
}

enum WireJSON {
    static func decode(_ data: Data, maximumBytes: Int = 65_536) throws -> WireMessage {
        guard (1...2 * 1_024 * 1_024).contains(maximumBytes) else {
            throw WireFailure.invalidFrame
        }
        // Phase-specific byte limits precede this parser; cap nesting before Foundation recursion.
        let fieldCount = try JSONShape.validate(
            data, maximumBytes: maximumBytes, maximumDepth: 8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { throw WireFailure.invalidMessage }
        let identityKeys: Set<String> = [
            "supervisorEpoch", "sessionId", "helperGeneration", "launchId",
        ]
        var allowed: Set<String> = ["protocolVersion", "type"]
        allowed.formUnion(identityKeys)
        var required = allowed
        switch type {
        case "hello":
            required.formUnion(["token", "capabilities", "helperPID", "simulatorUDID"])
            allowed.formUnion(required)
        case "ready":
            required.insert("capabilities")
            allowed.insert("capabilities")
        case "request":
            required.formUnion(["requestId", "operation", "remainingMilliseconds"])
            allowed.formUnion(["requestId", "operation", "remainingMilliseconds", "parameters"])
        case "reply":
            required.formUnion(["requestId", "operation"])
            allowed.formUnion(["requestId", "operation", "result", "error", "effectsUncertain"])
        default: throw WireFailure.invalidMessage
        }
        // The schema has one object. Counting syntax-level keys also rejects duplicates
        // that Foundation would otherwise collapse, including escaped spellings of a known key.
        let keys = Set(object.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys), fieldCount == keys.count,
            let message = try? JSONDecoder().decode(WireMessage.self, from: data),
            message.identity.helperGeneration > 0, message.protocolVersion == 1
        else { throw WireFailure.invalidMessage }
        if type == "request" || type == "reply" {
            guard let operation = message.operation, message.requestId != nil,
                WireMessage.allCapabilities.contains(operation)
            else { throw WireFailure.invalidMessage }
        }
        if type == "request" {
            guard let remaining = message.remainingMilliseconds, (1...120_000).contains(remaining)
            else { throw WireFailure.invalidMessage }
        }
        return message
    }

}

extension WireMessage {
    public static let uiCapabilities = [
        "ui.inspect", "ui.find", "ui.screenshot", "ui.tap", "ui.type", "ui.set_text",
        "ui.swipe", "ui.scroll", "ui.wait", "ui.system_alert.inspect", "ui.system_alert.tap",
    ]
    public static let allCapabilities = lifecycleCapabilities + uiCapabilities
}

public struct WireError: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct UISelector: Codable, Sendable {
    public var identifier: String?
    public var label: String?
    public var elementType: UInt?
    public var reference: String?
    public var x: Double?
    public var y: Double?
    public var snapshotId: UUID?

    public init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier, label, elementType, reference, x, y, snapshotId
    }

    public init(from decoder: Decoder) throws {
        try Self.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        label = try values.decodeIfPresent(String.self, forKey: .label)
        elementType = try values.decodeIfPresent(UInt.self, forKey: .elementType)
        reference = try values.decodeIfPresent(String.self, forKey: .reference)
        x = try values.decodeIfPresent(Double.self, forKey: .x)
        y = try values.decodeIfPresent(Double.self, forKey: .y)
        snapshotId = try values.decodeIfPresent(UUID.self, forKey: .snapshotId)
    }

    public func validate() throws {
        let namedFamilies = [
            identifier != nil, label != nil, reference != nil, x != nil || y != nil,
        ].filter { $0 }.count
        let typeOnly = namedFamilies == 0 && elementType != nil
        guard namedFamilies == 1 || typeOnly else { throw WireFailure.invalidMessage }
        if let identifier { try Self.text(identifier) }
        if let label { try Self.text(label) }
        if reference != nil || x != nil || y != nil, elementType != nil {
            throw WireFailure.invalidMessage
        }
        if reference != nil, snapshotId == nil { throw WireFailure.invalidMessage }
        if snapshotId != nil, reference == nil, x == nil, y == nil {
            throw WireFailure.invalidMessage
        }
        if x != nil || y != nil {
            guard let x, let y, x.isFinite, y.isFinite, snapshotId != nil else {
                throw WireFailure.invalidMessage
            }
        }
    }

    public func validateSystemAlert() throws {
        let families = [identifier != nil, label != nil].filter { $0 }.count
        guard families == 1, elementType == nil, reference == nil,
            x == nil, y == nil, snapshotId == nil
        else { throw WireFailure.invalidMessage }
        if let identifier { try Self.text(identifier) }
        if let label { try Self.text(label) }
    }

    static func text(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4_096,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw WireFailure.invalidMessage }
    }

    static func rejectUnknown(_ decoder: Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: WireCodingKey.self)
        guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw WireFailure.invalidMessage
        }
    }
}

public struct UIParameters: Codable, Sendable {
    public var selector: UISelector?
    public var text: String?
    public var direction: String?
    public var waitState: String?
    public var includeScreenshot: Bool?
    public var faultDisconnectAfterDispatch: Bool?

    public init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case selector, text, direction, waitState, includeScreenshot
        case faultDisconnectAfterDispatch
    }

    public init(from decoder: Decoder) throws {
        try UISelector.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selector = try values.decodeIfPresent(UISelector.self, forKey: .selector)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        direction = try values.decodeIfPresent(String.self, forKey: .direction)
        waitState = try values.decodeIfPresent(String.self, forKey: .waitState)
        includeScreenshot = try values.decodeIfPresent(Bool.self, forKey: .includeScreenshot)
        faultDisconnectAfterDispatch = try values.decodeIfPresent(
            Bool.self, forKey: .faultDisconnectAfterDispatch)
    }

    public func validate(operation: String) throws {
        if let text {
            guard !text.isEmpty, text.utf8.count <= 16_384 else {
                throw WireFailure.invalidMessage
            }
        }
        if faultDisconnectAfterDispatch == true,
            ![
                "ui.tap", "ui.type", "ui.set_text", "ui.swipe", "ui.scroll",
                "ui.system_alert.tap",
            ].contains(operation)
        {
            throw WireFailure.invalidMessage
        }
        if let direction, !["up", "down", "left", "right"].contains(direction) {
            throw WireFailure.invalidMessage
        }
        if let waitState, !["exists", "absent", "hittable"].contains(waitState) {
            throw WireFailure.invalidMessage
        }
        if operation == "ui.inspect" {
            guard selector == nil, text == nil, direction == nil, waitState == nil else {
                throw WireFailure.invalidMessage
            }
        } else if operation == "ui.screenshot" || operation == "ui.system_alert.inspect" {
            guard selector == nil, text == nil, direction == nil, waitState == nil,
                includeScreenshot == nil
            else { throw WireFailure.invalidMessage }
        } else {
            guard let selector else { throw WireFailure.invalidMessage }
            if operation == "ui.system_alert.tap" {
                try selector.validateSystemAlert()
            } else {
                try selector.validate()
            }
            let coordinateOperations = ["ui.tap", "ui.type", "ui.set_text"]
            if selector.x != nil, !coordinateOperations.contains(operation) {
                throw WireFailure.invalidMessage
            }
            switch operation {
            case "ui.tap", "ui.system_alert.tap":
                guard text == nil, direction == nil, waitState == nil else {
                    throw WireFailure.invalidMessage
                }
            case "ui.find":
                guard selector.reference == nil, selector.x == nil, selector.snapshotId == nil,
                    text == nil, direction == nil, waitState == nil
                else { throw WireFailure.invalidMessage }
            case "ui.type", "ui.set_text":
                guard text != nil, direction == nil, waitState == nil else {
                    throw WireFailure.invalidMessage
                }
            case "ui.swipe", "ui.scroll":
                guard text == nil, direction != nil, waitState == nil else {
                    throw WireFailure.invalidMessage
                }
            case "ui.wait":
                guard text == nil, direction == nil, waitState != nil else {
                    throw WireFailure.invalidMessage
                }
            default: throw WireFailure.invalidMessage
            }
        }
    }
}

private struct WireCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(intValue: Int) { return nil }
    init(stringValue: String) { self.stringValue = stringValue }
}

public struct UIFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct UIElementMatch: Codable, Sendable {
    public let reference: String?
    public let elementType: UInt
    public let identifier: String
    public let label: String
    public let enabled: Bool
    public let hittable: Bool
    public let frame: UIFrame
}

public struct UIFindResult: Codable, Sendable {
    public let snapshotId: UUID
    public let matches: [UIElementMatch]
    public let truncated: Bool
}

public struct UISystemAlertButton: Codable, Sendable {
    public let identifier: String
    public let label: String
    public let enabled: Bool
    public let hittable: Bool
}

public struct UISystemAlertResult: Codable, Sendable {
    public let capturedMonotonicMilliseconds: UInt64
    public let present: Bool
    public let label: String?
    public let buttons: [UISystemAlertButton]
    public let truncated: Bool
}

public struct UINode: Codable, Sendable {
    public let reference: String?
    public let parent: Int?
    public let elementType: UInt
    public let identifier: String
    public let label: String
    public let value: String?
    public let enabled: Bool
    public let selected: Bool
    public let frame: UIFrame
    public let truncatedAttributes: [String]
}

public struct UISnapshot: Codable, Sendable {
    public let id: UUID
    public let capturedMonotonicMilliseconds: UInt64
    public let bundleIdentifier: String
    public let generation: UInt64
    public let orientation: Int
    public let coordinateSpace: String
    public let screenWidthPoints: Double
    public let screenHeightPoints: Double
    public let nodes: [UINode]
    public let truncated: Bool
    public let truncationReasons: [String]
    public let visitedCount: Int
    public let emittedCount: Int
}

public struct ArtifactManifest: Codable, Sendable {
    public let id: UUID
    public let mediaType: String
    public let byteCount: Int
    public let sha256: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double
    public let capturedMonotonicMilliseconds: UInt64
}

public struct UIResult: Codable, Sendable {
    public var snapshot: UISnapshot?
    public var find: UIFindResult?
    public var systemAlert: UISystemAlertResult?
    public var screenshot: ArtifactManifest?
    public var acknowledged: Bool?
    public var waitMatched: Bool?

    public init() {}
}
