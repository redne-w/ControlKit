import UIKit
import XCTest

@MainActor
enum ProbeAutomation {
    static func execute(_ request: ProbeRequest, app: XCUIApplication) throws -> ProbeResponse {
        var response = ProbeResponse(id: request.id)
        switch request.operation {
        case .ping, .stop:
            return response
        case .inspect:
            try requireForeground(app)
            let snapshot = try app.snapshot()
            let tree = flatten(snapshot)
            response.elements = tree.elements
            response.truncated = tree.truncated
            response.orientation = XCUIDevice.shared.orientation.rawValue
            response.coordinateSpace = "screen_points"
        case .screenshot:
            try requireForeground(app)
            let screenshot = XCUIScreen.main.screenshot()
            response.screenshotPNG = screenshot.pngRepresentation
            response.screenScale = Double(screenshot.image.scale)
            response.orientation = XCUIDevice.shared.orientation.rawValue
            response.coordinateSpace = "screen_points"
        case .tap:
            try target(request.identifier, app: app).tap()
        case .type:
            let element = try target(request.identifier, app: app)
            guard element.elementType == .textField || element.elementType == .textView else {
                throw ProbeFailure(
                    "invalid_element", "The probe types only into plain text fields.")
            }
            element.tap()
            element.typeText(request.text!)
        case .swipe:
            try target(request.identifier, app: app).swipeUp(velocity: .slow)
        }
        return response
    }

    private static func requireForeground(_ app: XCUIApplication) throws {
        guard app.state == .runningForeground else {
            throw ProbeFailure("app_not_foreground", "Launch/activate the app explicitly first.")
        }
    }

    private static func target(_ identifier: String?, app: XCUIApplication) throws -> XCUIElement {
        try requireForeground(app)
        precondition(identifier != nil)
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier!)
        )
        let count = query.count
        guard count > 0 else {
            throw ProbeFailure(
                "element_not_found", "No element matches the accessibility identifier.")
        }
        guard count == 1 else {
            throw ProbeFailure("ambiguous_element", "More than one element matches the identifier.")
        }
        let element = query.element(boundBy: 0)
        guard element.isEnabled, element.isHittable else {
            throw ProbeFailure("element_not_hittable", "Element is disabled or not hittable.")
        }
        return element
    }

    private static func flatten(
        _ root: any XCUIElementSnapshot
    ) -> (elements: [ProbeElement], truncated: Bool) {
        var pending: [(node: any XCUIElementSnapshot, parent: Int?, depth: Int)] = [
            (root, nil, 0)
        ]
        var output: [ProbeElement] = []
        var cursor = 0
        var truncated = false
        // XCTest builds its snapshot internally. This bounds our traversal, not Apple's allocation.
        while cursor < pending.count {
            precondition(pending.count <= ProbeLimits.elements)
            let entry = pending[cursor]
            output.append(describe(entry.node, index: cursor, parent: entry.parent))
            let children = entry.node.children
            if entry.depth < ProbeLimits.treeDepth {
                let capacity = ProbeLimits.elements - pending.count
                let count = min(children.count, capacity)
                for index in 0..<count {
                    pending.append((children[index], cursor, entry.depth + 1))
                }
                truncated = truncated || count < children.count
            } else {
                truncated = truncated || !children.isEmpty
            }
            cursor += 1
        }
        precondition(output.count == pending.count)
        return (output, truncated)
    }

    private static func describe(
        _ node: any XCUIElementSnapshot, index: Int, parent: Int?
    ) -> ProbeElement {
        let frame = node.frame
        let value = node.value.map { String(describing: $0) }
        return ProbeElement(
            index: index, parent: parent, type: node.elementType.rawValue,
            identifier: String(node.identifier.prefix(ProbeLimits.textCharacters)),
            label: String(node.label.prefix(ProbeLimits.textCharacters)),
            value: value.map { String($0.prefix(ProbeLimits.textCharacters)) },
            enabled: node.isEnabled,
            frame: ProbeFrame(
                x: frame.minX, y: frame.minY, width: frame.width, height: frame.height
            )
        )
    }
}
