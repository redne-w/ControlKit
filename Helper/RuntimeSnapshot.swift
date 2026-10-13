import Foundation
import XCTest

struct RuntimeReference {
    let identifier: String
    let label: String
    let elementType: UInt
    let frame: UIFrame
}

struct RuntimeFlattened {
    let id: UUID
    let nodes: [UINode]
    let references: [String: RuntimeReference]
    let truncated: Bool
    let reasons: [String]
    let visited: Int
}

@MainActor
enum RuntimeSnapshot {
    private struct Pending {
        let node: any XCUIElementSnapshot
        let parent: Int?
        let depth: Int
    }

    static func flatten(_ root: any XCUIElementSnapshot) -> RuntimeFlattened {
        var pending = [Pending(node: root, parent: nil, depth: 0)]
        var nodes: [UINode] = []
        var references: [String: RuntimeReference] = [:]
        var reasons: Set<String> = []
        var cursor = 0
        var textBytes = 0
        var visited = 0
        while cursor < pending.count {
            let entry = pending[cursor]
            visited += 1
            let described = describe(entry.node, parent: entry.parent, textBytes: &textBytes)
            guard described != nil else {
                reasons.insert("bytes")
                break
            }
            nodes.append(described!.node)
            if let reference = described!.reference {
                references[reference.key] = reference.value
            }
            appendChildren(entry, parent: cursor, pending: &pending, reasons: &reasons)
            cursor += 1
        }
        if cursor < pending.count { visited += pending.count - cursor }
        return RuntimeFlattened(
            id: UUID(), nodes: nodes, references: references, truncated: !reasons.isEmpty,
            reasons: reasons.sorted(), visited: visited)
    }

    private static func appendChildren(
        _ entry: Pending, parent: Int, pending: inout [Pending], reasons: inout Set<String>
    ) {
        let children = entry.node.children
        guard entry.depth < 32 else {
            if !children.isEmpty { reasons.insert("depth") }
            return
        }
        let capacity = 512 - pending.count
        let count = min(children.count, max(0, capacity))
        for index in 0..<count {
            pending.append(Pending(node: children[index], parent: parent, depth: entry.depth + 1))
        }
        if count < children.count { reasons.insert("nodes") }
    }

    private static func describe(
        _ source: any XCUIElementSnapshot, parent: Int?, textBytes: inout Int
    ) -> (node: UINode, reference: (key: String, value: RuntimeReference)?)? {
        let identifier = bounded(source.identifier)
        let label = bounded(source.label)
        let secure = source.elementType == .secureTextField
        let rawValue = secure ? nil : source.value.map { String(describing: $0) }
        let value = rawValue.map(bounded)
        let strings =
            identifier.value.utf8.count + label.value.utf8.count
            + (value?.value.utf8.count ?? 0)
        guard textBytes + strings <= 2 * 1_024 * 1_024 - 512 * 1_024 else { return nil }
        textBytes += strings
        let textInput =
            source.elementType == .textField || source.elementType == .textView
            || source.elementType == .secureTextField
        let reference =
            identifier.value.isEmpty && label.value.isEmpty && !textInput
            ? nil : UUID().uuidString
        let truncated = [
            identifier.truncated ? "identifier" : nil,
            label.truncated ? "label" : nil,
            value?.truncated == true ? "value" : nil,
        ].compactMap { $0 }
        let node = UINode(
            reference: reference, parent: parent, elementType: source.elementType.rawValue,
            identifier: identifier.value, label: label.value, value: value?.value,
            enabled: source.isEnabled, selected: source.isSelected, frame: frame(source.frame),
            truncatedAttributes: truncated)
        guard let reference else { return (node, nil) }
        return (
            node,
            (
                reference,
                RuntimeReference(
                    identifier: identifier.value, label: label.value,
                    elementType: source.elementType.rawValue, frame: frame(source.frame))
            )
        )
    }

    static func frame(_ value: CGRect) -> UIFrame {
        UIFrame(x: value.minX, y: value.minY, width: value.width, height: value.height)
    }

    private static func bounded(_ value: String) -> (value: String, truncated: Bool) {
        guard value.utf8.count > 4_096 else { return (value, false) }
        var end = value.utf8.index(value.utf8.startIndex, offsetBy: 4_096)
        while end > value.utf8.startIndex {
            if let result = String(value.utf8[..<end]) { return (result, true) }
            end = value.utf8.index(before: end)
        }
        return ("", true)
    }
}
