import Foundation

/// Preflight bounds decoder nesting and rejects duplicate keys, including escaped spellings.
/// JSONDecoder remains responsible for JSON syntax; this is not another JSON implementation.
enum ConfigurationJSON {
    private struct Scope {
        let object: Bool
        var expectingKey: Bool
        var keys: Set<String> = []
    }

    static func decode<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
        try checkShape(data)
        do { return try JSONDecoder().decode(type, from: data) } catch {
            // Foundation diagnostics can echo input, including argv or unknown credential fields.
            throw DiscoveryFailure(
                .invalidConfiguration, "Invalid configuration JSON or field types.")
        }
    }

    static func checkShape(_ data: Data) throws {
        guard data.count <= DiscoveryLimits.fileBytes else {
            throw DiscoveryFailure(.resourceLimit, "Configuration exceeds 64 KiB.")
        }
        let bytes = Array(data)
        var scopes: [Scope] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 123 || byte == 91 {
                guard scopes.count < DiscoveryLimits.jsonDepth else {
                    throw DiscoveryFailure(
                        .resourceLimit, "Configuration nesting exceeds 32 levels.")
                }
                scopes.append(Scope(object: byte == 123, expectingKey: byte == 123))
            } else if byte == 125 || byte == 93 {
                guard let scope = scopes.popLast(), scope.object == (byte == 125) else {
                    throw DiscoveryFailure(.invalidConfiguration, "Unbalanced configuration JSON.")
                }
            } else if byte == 44, !scopes.isEmpty, scopes[scopes.count - 1].object {
                scopes[scopes.count - 1].expectingKey = true
            } else if byte == 34 {
                let end = try stringEnd(bytes, after: index)
                if !scopes.isEmpty, scopes[scopes.count - 1].expectingKey {
                    try admitKey(Data(bytes[index...end]), into: &scopes[scopes.count - 1])
                }
                index = end
            }
            index += 1
        }
    }

    private static func stringEnd(_ bytes: [UInt8], after start: Int) throws -> Int {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == 34 { return index }
            if bytes[index] == 92 { index += 1 }
            index += 1
        }
        throw DiscoveryFailure(.invalidConfiguration, "Unterminated configuration string.")
    }

    private static func admitKey(_ data: Data, into scope: inout Scope) throws {
        let key: String
        do { key = try JSONDecoder().decode(String.self, from: data) } catch {
            throw DiscoveryFailure(.invalidConfiguration, "Invalid configuration key.")
        }
        guard scope.keys.insert(key).inserted else {
            throw DiscoveryFailure(
                .invalidConfiguration, "Duplicate configuration keys are not allowed.")
        }
        scope.expectingKey = false
    }
}

struct ConfigurationKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
    init(stringValue: String) { self.stringValue = stringValue }
}

func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: ConfigurationKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DiscoveryFailure(.invalidConfiguration, "Unknown ControlKit configuration field.")
    }
}
