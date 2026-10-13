import Foundation

enum JSONShape {
    private struct Scope {
        let object: Bool
        var expectingKey: Bool
        var keys: Set<String> = []
    }

    static func validate(_ data: Data, maximumBytes: Int, maximumDepth: Int) throws -> Int {
        guard data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else {
            throw WireFailure.invalidMessage
        }
        let bytes = Array(data)
        var scopes: [Scope] = []
        var rootFields = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 123 || byte == 91 {
                guard scopes.count < maximumDepth else { throw WireFailure.invalidMessage }
                scopes.append(Scope(object: byte == 123, expectingKey: byte == 123))
            } else if byte == 125 || byte == 93 {
                guard let scope = scopes.popLast(), scope.object == (byte == 125) else {
                    throw WireFailure.invalidMessage
                }
                if scopes.isEmpty { rootFields = scope.keys.count }
            } else if byte == 44, scopes.last?.object == true {
                scopes[scopes.count - 1].expectingKey = true
            } else if byte == 34 {
                let end = try stringEnd(bytes, start: index)
                if scopes.last?.expectingKey == true {
                    try admitKey(Data(bytes[index...end]), into: &scopes[scopes.count - 1])
                }
                index = end
            }
            index += 1
        }
        guard scopes.isEmpty else { throw WireFailure.invalidMessage }
        return rootFields
    }

    private static func admitKey(_ data: Data, into scope: inout Scope) throws {
        guard let key = try? JSONDecoder().decode(String.self, from: data),
            scope.keys.insert(key).inserted
        else { throw WireFailure.invalidMessage }
        scope.expectingKey = false
    }

    private static func stringEnd(_ bytes: [UInt8], start: Int) throws -> Int {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == 34 { return index }
            if bytes[index] == 92 { index += 1 }
            index += 1
        }
        throw WireFailure.invalidMessage
    }
}
