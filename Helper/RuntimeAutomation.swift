import CryptoKit
import Foundation
import UIKit
import XCTest

struct RuntimeAutomationFailure: Error {
    let code: String
    let message: String
    let uncertain: Bool

    init(_ code: String, _ message: String, uncertain: Bool = false) {
        self.code = code
        self.message = message
        self.uncertain = uncertain
    }
}

@MainActor
final class RuntimeAutomation {
    private let app: XCUIApplication
    private let springboard: XCUIApplication
    private let bundleIdentifier: String
    private let generation: UInt64
    private var snapshotID: UUID?
    private var snapshotFrame: CGRect?
    private var snapshotOrientation: Int?
    private var references: [String: RuntimeReference] = [:]
    private static let origin = ContinuousClock.now

    init(bundleIdentifier: String, generation: UInt64) throws {
        try UISelector.text(bundleIdentifier)
        app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        self.bundleIdentifier = bundleIdentifier
        self.generation = generation
    }

    func validateAttachment() throws {
        try foreground()
    }

    func execute(_ request: WireMessage) throws -> (UIResult, Data?) {
        guard let operation = request.operation else { throw WireFailure.invalidMessage }
        let parameters = request.parameters ?? UIParameters()
        try parameters.validate(operation: operation)
        switch operation {
        case "ui.inspect":
            return try inspect(includeScreenshot: parameters.includeScreenshot == true)
        case "ui.find": return try find(parameters.selector)
        case "ui.screenshot": return try screenshot()
        case "ui.tap": return try tap(parameters.selector)
        case "ui.type":
            return try type(parameters.selector, text: parameters.text)
        case "ui.set_text":
            return try setText(
                parameters.selector, text: parameters.text,
                milliseconds: request.remainingMilliseconds!)
        case "ui.swipe":
            return try gesture(parameters.selector, direction: parameters.direction, content: false)
        case "ui.scroll":
            return try gesture(parameters.selector, direction: parameters.direction, content: true)
        case "ui.wait":
            return try wait(
                parameters.selector, state: parameters.waitState,
                milliseconds: request.remainingMilliseconds!)
        case "ui.system_alert.inspect": return try inspectSystemAlert()
        case "ui.system_alert.tap": return try tapSystemAlert(parameters.selector)
        default: throw WireFailure.invalidMessage
        }
    }

    private func inspect(includeScreenshot: Bool) throws -> (UIResult, Data?) {
        try foreground()
        let root = try app.snapshot()
        let flattened = RuntimeSnapshot.flatten(root)
        let frame = app.frame
        let snapshot = UISnapshot(
            id: flattened.id, capturedMonotonicMilliseconds: Self.now(),
            bundleIdentifier: bundleIdentifier, generation: generation,
            orientation: XCUIDevice.shared.orientation.rawValue, coordinateSpace: "screen_points",
            screenWidthPoints: frame.width, screenHeightPoints: frame.height,
            nodes: flattened.nodes, truncated: flattened.truncated,
            truncationReasons: flattened.reasons, visitedCount: flattened.visited,
            emittedCount: flattened.nodes.count)
        snapshotID = flattened.id
        snapshotFrame = frame
        snapshotOrientation = XCUIDevice.shared.orientation.rawValue
        references = flattened.references
        var result = UIResult()
        result.snapshot = snapshot
        if includeScreenshot {
            let captured = try capture()
            result.screenshot = captured.manifest
            return (result, captured.data)
        }
        return (result, nil)
    }

    private func find(_ selector: UISelector?) throws -> (UIResult, Data?) {
        guard let selector, selector.reference == nil, selector.x == nil else {
            throw WireFailure.invalidMessage
        }
        try foreground()
        let found = try elements(
            identifier: selector.identifier ?? "", label: selector.label ?? "",
            type: selector.elementType, limit: 17)
        let snapshot = UUID()
        invalidateSnapshot()
        snapshotID = snapshot
        snapshotFrame = app.frame
        snapshotOrientation = XCUIDevice.shared.orientation.rawValue
        var truncated = found.count > 16
        let matches = found.prefix(16).map { element -> UIElementMatch in
            let identifier = bounded(element.identifier)
            let label = bounded(element.label)
            truncated = truncated || identifier.truncated || label.truncated
            let frame = RuntimeSnapshot.frame(element.frame)
            let reference: String?
            if identifier.truncated || label.truncated {
                reference = nil
            } else {
                let value = UUID().uuidString
                reference = value
                references[value] = RuntimeReference(
                    identifier: identifier.value, label: label.value,
                    elementType: element.elementType.rawValue, frame: frame)
            }
            return UIElementMatch(
                reference: reference, elementType: element.elementType.rawValue,
                identifier: identifier.value, label: label.value, enabled: element.isEnabled,
                hittable: element.isHittable, frame: frame)
        }
        var result = UIResult()
        result.find = UIFindResult(
            snapshotId: snapshot, matches: matches, truncated: truncated)
        return (result, nil)
    }

    private func screenshot() throws -> (UIResult, Data?) {
        try foreground()
        let captured = try capture()
        var result = UIResult()
        result.screenshot = captured.manifest
        return (result, captured.data)
    }

    private func mutate(
        _ selector: UISelector?, action: (XCUIElement) -> Void
    ) throws -> (UIResult, Data?) {
        let element = try target(selector)
        action(element)
        invalidateSnapshot()
        var result = UIResult()
        result.acknowledged = true
        return (result, nil)
    }

    private func tap(_ selector: UISelector?) throws -> (UIResult, Data?) {
        guard let selector else { throw WireFailure.invalidMessage }
        if selector.x != nil {
            try coordinate(selector).tap()
            invalidateSnapshot()
            var result = UIResult()
            result.acknowledged = true
            return (result, nil)
        }
        return try mutate(selector) { $0.tap() }
    }

    private func type(_ selector: UISelector?, text: String?) throws -> (UIResult, Data?) {
        guard let text else { throw WireFailure.invalidMessage }
        let element = try textInput(selector)
        try focusTextInput(selector, element: element)
        element.typeText(text)
        invalidateSnapshot()
        var result = UIResult()
        result.acknowledged = true
        return (result, nil)
    }

    private func setText(
        _ selector: UISelector?, text: String?, milliseconds: UInt64
    ) throws -> (UIResult, Data?) {
        guard let text else { throw WireFailure.invalidMessage }
        let element = try textInput(selector)
        guard element.elementType != .secureTextField else {
            throw RuntimeAutomationFailure(
                "unsupported_element", "Secure text cannot be safely replaced and verified.")
        }
        let current = try textValue(element)
        let placeholder = element.placeholderValue ?? ""
        let deleteCount = current == placeholder ? 0 : current.count
        guard deleteCount <= 16_384 else {
            throw RuntimeAutomationFailure("resource_limit", "Existing text exceeds 16 KiB.")
        }
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(min(milliseconds, 5_000))))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if deleteCount > 0 { element.typeText(String(repeating: "\u{8}", count: deleteCount)) }
        try verifyCleared(element, placeholder: placeholder, deadline: deadline)
        if !text.isEmpty { element.typeText(text) }
        try verifyText(element, expected: text, deadline: deadline)
        invalidateSnapshot()
        var result = UIResult()
        result.acknowledged = true
        return (result, nil)
    }

    private func textInput(_ selector: UISelector?) throws -> XCUIElement {
        guard let selector else { throw WireFailure.invalidMessage }
        let element: XCUIElement
        if let x = selector.x, let y = selector.y {
            _ = try coordinate(selector)
            let matches = try textInputs(at: CGPoint(x: x, y: y))
            guard matches.count == 1 else {
                throw RuntimeAutomationFailure(
                    "element_not_found", "Coordinate does not identify exactly one text field.")
            }
            element = matches[0]
        } else {
            element = try target(selector)
        }
        guard Self.isTextInput(element.elementType) else {
            throw RuntimeAutomationFailure("invalid_element", "Target is not a text field.")
        }
        return element
    }

    private func focusTextInput(
        _ selector: UISelector?, element: XCUIElement
    ) throws {
        guard let selector else { throw WireFailure.invalidMessage }
        if selector.x != nil {
            try coordinate(selector).tap()
        } else {
            element.tap()
        }
    }

    private func textInputs(at point: CGPoint) throws -> [XCUIElement] {
        var matches: [XCUIElement] = []
        for type: XCUIElement.ElementType in [.textField, .textView, .secureTextField] {
            let query = app.descendants(matching: type)
            let count = query.count
            guard count <= 64 else {
                throw RuntimeAutomationFailure("resource_limit", "Text-field query exceeds 64.")
            }
            for index in 0..<count {
                let element = query.element(boundBy: index)
                if element.frame.contains(point), element.isEnabled, element.isHittable {
                    matches.append(element)
                }
            }
        }
        return matches
    }

    private func verifyCleared(
        _ element: XCUIElement, placeholder: String, deadline: ContinuousClock.Instant
    ) throws {
        for _ in 0..<100 {
            let actual = try uncertainTextValue(element)
            if actual.isEmpty || !placeholder.isEmpty && actual == placeholder { return }
            guard ContinuousClock.now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw RuntimeAutomationFailure(
            "value_mismatch", "Text field could not be cleared.", uncertain: true)
    }

    private func verifyText(
        _ element: XCUIElement, expected: String, deadline: ContinuousClock.Instant
    ) throws {
        for _ in 0..<100 {
            let actual = try uncertainTextValue(element)
            if actual == expected { return }
            guard ContinuousClock.now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw RuntimeAutomationFailure(
            "value_mismatch", "Text field did not reach the final value.", uncertain: true)
    }

    private func uncertainTextValue(_ element: XCUIElement) throws -> String {
        do {
            return try textValue(element)
        } catch let failure as RuntimeAutomationFailure {
            throw RuntimeAutomationFailure(failure.code, failure.message, uncertain: true)
        }
    }

    private func textValue(_ element: XCUIElement) throws -> String {
        guard let raw = element.value else { return "" }
        guard let value = raw as? String, value.utf8.count <= 16_384 else {
            throw RuntimeAutomationFailure("resource_limit", "Text field value exceeds 16 KiB.")
        }
        return value
    }

    private static func isTextInput(_ type: XCUIElement.ElementType) -> Bool {
        type == .textField || type == .textView || type == .secureTextField
    }

    private func gesture(
        _ selector: UISelector?, direction: String?, content: Bool
    ) throws -> (UIResult, Data?) {
        guard let direction else { throw WireFailure.invalidMessage }
        let element = try target(selector)
        let motion =
            content
            ? ["up": "down", "down": "up", "left": "right", "right": "left"][
                direction] : direction
        switch motion {
        case "up": element.swipeUp(velocity: .slow)
        case "down": element.swipeDown(velocity: .slow)
        case "left": element.swipeLeft(velocity: .slow)
        case "right": element.swipeRight(velocity: .slow)
        default: throw WireFailure.invalidMessage
        }
        invalidateSnapshot()
        var result = UIResult()
        result.acknowledged = true
        return (result, nil)
    }

    private func wait(
        _ selector: UISelector?, state: String?, milliseconds: UInt64
    ) throws -> (UIResult, Data?) {
        guard let state else { throw WireFailure.invalidMessage }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(milliseconds)))
        var samples = 0
        while samples < 300 {
            let matches = try query(selector, requireHittable: false)
            let satisfied =
                state == "absent"
                ? matches.isEmpty
                : state == "exists"
                    ? matches.count == 1
                    : matches.count == 1 && matches[0].isHittable
            if satisfied {
                var result = UIResult()
                result.waitMatched = true
                return (result, nil)
            }
            guard ContinuousClock.now < deadline else {
                throw RuntimeAutomationFailure("deadline_exceeded", "Wait condition did not match.")
            }
            Thread.sleep(forTimeInterval: 0.2)
            samples += 1
        }
        throw RuntimeAutomationFailure("resource_limit", "Wait reached 300 samples.")
    }

    private func target(_ selector: UISelector?) throws -> XCUIElement {
        guard let selector else { throw WireFailure.invalidMessage }
        try foreground()
        guard selector.x == nil, selector.y == nil else { throw WireFailure.invalidMessage }
        let matches = try query(selector, requireHittable: true)
        guard !matches.isEmpty else {
            throw RuntimeAutomationFailure("element_not_found", "No element matches the selector.")
        }
        guard matches.count == 1 else {
            throw RuntimeAutomationFailure("ambiguous_element", "More than one element matches.")
        }
        return matches[0]
    }

    private func query(_ selector: UISelector?, requireHittable: Bool) throws -> [XCUIElement] {
        guard let selector else { throw WireFailure.invalidMessage }
        if let reference = selector.reference {
            guard selector.snapshotId == snapshotID, let saved = references[reference] else {
                throw RuntimeAutomationFailure("stale_reference", "Element reference is stale.")
            }
            let found = try referenceElements(saved)
            guard found.count == 1 else {
                throw RuntimeAutomationFailure("stale_reference", "Referenced element changed.")
            }
            return try actionable(found, required: requireHittable)
        }
        let found = try elements(
            identifier: selector.identifier ?? "", label: selector.label ?? "",
            type: selector.elementType, limit: requireHittable ? 513 : 2)
        if requireHittable, found.count > 512 {
            throw RuntimeAutomationFailure("resource_limit", "Action query exceeds 512 elements.")
        }
        return try actionable(found, required: requireHittable)
    }

    private func actionable(_ found: [XCUIElement], required: Bool) throws -> [XCUIElement] {
        guard required else { return found }
        let matches = found.filter { $0.isEnabled && $0.isHittable }
        if !matches.isEmpty { return matches }
        if found.count == 1 {
            throw RuntimeAutomationFailure("element_not_hittable", "Element is not hittable.")
        }
        return found
    }

    private func elements(
        identifier: String, label: String, type: UInt?, limit: Int
    ) throws -> [XCUIElement] {
        precondition((1...513).contains(limit))
        let elementType: XCUIElement.ElementType
        if let type {
            guard let value = XCUIElement.ElementType(rawValue: type) else {
                throw RuntimeAutomationFailure("invalid_argument", "Element type is unsupported.")
            }
            elementType = value
        } else {
            elementType = .any
        }
        var query = app.descendants(matching: elementType)
        if !identifier.isEmpty {
            query = query.matching(NSPredicate(format: "identifier == %@", identifier))
        } else if !label.isEmpty {
            query = query.matching(NSPredicate(format: "label == %@", label))
        }
        let count = min(query.count, limit)
        return (0..<count).map { query.element(boundBy: $0) }
    }

    private func referenceElements(_ saved: RuntimeReference) throws -> [XCUIElement] {
        guard let type = XCUIElement.ElementType(rawValue: saved.elementType) else {
            throw RuntimeAutomationFailure("stale_reference", "Element type is unavailable.")
        }
        var query = app.descendants(matching: type)
        if !saved.identifier.isEmpty {
            query = query.matching(NSPredicate(format: "identifier == %@", saved.identifier))
        } else if !saved.label.isEmpty {
            query = query.matching(NSPredicate(format: "label == %@", saved.label))
        }
        let count = query.count
        guard count <= 512 else {
            throw RuntimeAutomationFailure(
                "resource_limit", "Reference query exceeds 512 elements.")
        }
        var matches: [XCUIElement] = []
        for index in 0..<count {
            let element = query.element(boundBy: index)
            guard element.identifier == saved.identifier, element.label == saved.label,
                RuntimeSnapshot.frame(element.frame) == saved.frame
            else { continue }
            matches.append(element)
            if matches.count == 2 { break }
        }
        return matches
    }

    private func coordinate(_ selector: UISelector) throws -> XCUICoordinate {
        guard let x = selector.x, let y = selector.y else { throw WireFailure.invalidMessage }
        try foreground()
        let frame = app.frame
        guard selector.snapshotId == snapshotID, snapshotFrame == frame,
            snapshotOrientation == XCUIDevice.shared.orientation.rawValue,
            frame.width > 0, frame.height > 0, frame.contains(CGPoint(x: x, y: y))
        else {
            throw RuntimeAutomationFailure("stale_reference", "Coordinate snapshot is stale.")
        }
        return app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (x - frame.minX) / frame.width, dy: (y - frame.minY) / frame.height))
    }

    private func inspectSystemAlert() throws -> (UIResult, Data?) {
        invalidateSnapshot()
        guard let alert = try systemAlert() else {
            var result = UIResult()
            result.systemAlert = UISystemAlertResult(
                capturedMonotonicMilliseconds: Self.now(), present: false, label: nil,
                buttons: [], truncated: false)
            return (result, nil)
        }
        let label = bounded(alert.label)
        let query = alert.buttons
        let total = query.count
        let count = min(total, 8)
        var truncated = label.truncated || total > count
        let buttons = (0..<count).map { index -> UISystemAlertButton in
            let button = query.element(boundBy: index)
            let identifier = bounded(button.identifier)
            let buttonLabel = bounded(button.label)
            truncated = truncated || identifier.truncated || buttonLabel.truncated
            return UISystemAlertButton(
                identifier: identifier.value, label: buttonLabel.value,
                enabled: button.isEnabled, hittable: button.isHittable)
        }
        var result = UIResult()
        result.systemAlert = UISystemAlertResult(
            capturedMonotonicMilliseconds: Self.now(), present: true, label: label.value,
            buttons: buttons, truncated: truncated)
        return (result, nil)
    }

    private func tapSystemAlert(_ selector: UISelector?) throws -> (UIResult, Data?) {
        guard let selector else { throw WireFailure.invalidMessage }
        invalidateSnapshot()
        guard let alert = try systemAlert() else {
            throw RuntimeAutomationFailure("alert_not_found", "No iOS system alert is present.")
        }
        var query = alert.buttons
        if let identifier = selector.identifier {
            query = query.matching(NSPredicate(format: "identifier == %@", identifier))
        } else if let label = selector.label {
            query = query.matching(NSPredicate(format: "label == %@", label))
        } else {
            throw WireFailure.invalidMessage
        }
        let count = min(query.count, 2)
        guard count > 0 else {
            throw RuntimeAutomationFailure("element_not_found", "No alert button matches.")
        }
        guard count == 1 else {
            throw RuntimeAutomationFailure("ambiguous_element", "Multiple alert buttons match.")
        }
        let button = query.element(boundBy: 0)
        guard button.isEnabled, button.isHittable else {
            throw RuntimeAutomationFailure("element_not_hittable", "Alert button is not hittable.")
        }
        button.tap()
        invalidateSnapshot()
        var result = UIResult()
        result.acknowledged = true
        return (result, nil)
    }

    private func systemAlert() throws -> XCUIElement? {
        let query = springboard.alerts
        let count = min(query.count, 2)
        guard count < 2 else {
            throw RuntimeAutomationFailure(
                "ambiguous_system_alert", "More than one iOS system alert is present.")
        }
        return count == 0 ? nil : query.element(boundBy: 0)
    }

    private func invalidateSnapshot() {
        references.removeAll(keepingCapacity: true)
        snapshotID = nil
        snapshotFrame = nil
        snapshotOrientation = nil
    }

    private func bounded(_ value: String) -> (value: String, truncated: Bool) {
        guard value.utf8.count > 4_096 else { return (value, false) }
        var end = value.utf8.index(value.utf8.startIndex, offsetBy: 4_096)
        while end > value.utf8.startIndex {
            if let result = String(value.utf8[..<end]) { return (result, true) }
            end = value.utf8.index(before: end)
        }
        return ("", true)
    }

    private func foreground() throws {
        let state = app.state
        guard state == .runningForeground else {
            throw RuntimeAutomationFailure(
                "app_not_foreground",
                "Launch or activate the app explicitly (XCTest state \(state.rawValue)).")
        }
    }

    private func capture() throws -> (manifest: ArtifactManifest, data: Data) {
        let screenshot = XCUIScreen.main.screenshot()
        let data = screenshot.pngRepresentation
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw RuntimeAutomationFailure("resource_limit", "Screenshot exceeds 32 MiB.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let image = screenshot.image
        return (
            ArtifactManifest(
                id: UUID(), mediaType: "image/png", byteCount: data.count, sha256: digest,
                pixelWidth: Int(image.size.width * image.scale),
                pixelHeight: Int(image.size.height * image.scale), scale: Double(image.scale),
                capturedMonotonicMilliseconds: Self.now()),
            data
        )
    }

    private static func now() -> UInt64 {
        let parts = origin.duration(to: .now).components
        return UInt64(parts.seconds) * 1_000
            + UInt64(parts.attoseconds) / 1_000_000_000_000_000
    }
}
