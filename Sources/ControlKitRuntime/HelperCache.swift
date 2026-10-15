import CryptoKit
import Foundation

struct CachedHelper {
    let products: URL
    let template: URL
    let key: String
    let reused: Bool
}

enum HelperCache {
    static let inputs = [
        "Helper/ControlKitRuntime.xcodeproj/project.pbxproj",
        "Helper/ControlKitRuntime.xcodeproj/xcshareddata/xcschemes/ControlKitRuntime.xcscheme",
        "Helper/RuntimeTests.swift", "Helper/RuntimeAutomation.swift",
        "Helper/RuntimeSnapshot.swift",
        "Sources/ControlKitWire/JSONShape.swift", "Sources/ControlKitWire/WireMessage.swift",
        "Sources/ControlKitWire/WireSocket.swift", "Sources/ControlKitWire/WireListener.swift",
    ]

    static func prepare(
        source: URL, cache: URL, tools: AppleTools, budget: OperationBudget? = nil
    ) throws -> CachedHelper {
        let root = try PrivateDirectory(cache)
        let lock = try FileLock(directory: root, name: "build.lock")
        defer { withExtendedLifetime(lock) {} }
        let key = try fingerprint(source: source, identity: tools.identity)
        let entry = cache.appendingPathComponent(key, isDirectory: true)
        let names = try root.entries(limit: 16)
        let directory: PrivateDirectory
        let reused = names.contains(key)
        if !reused {
            try requireRuntime(
                names.filter { $0 != "build.lock" }.count < 4,
                "resource_limit",
                "Helper cache is full; stop sessions, then run 'ControlKit cache clean'."
            )
        }
        directory = try PrivateDirectory(entry)
        _ = try RuntimeFiles.cacheBytes(cache)
        if reused {
            try requireRuntime(
                try directory.exists("complete"), "cache_incomplete",
                "Interrupted helper build left an incomplete entry; run 'ControlKit cache clean'."
            )
            let marker = try RuntimeFiles.read(entry.appendingPathComponent("complete"), limit: 64)
            try requireRuntime(
                marker == Data(key.utf8), "cache_invalid", "Invalid cache identity marker.")
        } else {
            _ = try tools.run(
                [
                    "xcodebuild", "build-for-testing", "-quiet", "-project",
                    source.appendingPathComponent("Helper/ControlKitRuntime.xcodeproj").path,
                    "-scheme", "ControlKitRuntime", "-configuration", "Debug",
                    "-destination", "generic/platform=iOS Simulator",
                    "-derivedDataPath", entry.path, "-parallel-testing-enabled", "NO",
                    "CODE_SIGNING_ALLOWED=NO", "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
                ], milliseconds: 900_000, budget: budget,
                allowTruncatedDiagnostics: true, label: "helper_build")
            _ = try RuntimeFiles.cacheBytes(cache)
            // Publish only a finished build whose inputs did not change during compilation.
            try requireRuntime(
                try fingerprint(source: source, identity: tools.identity) == key,
                "cache_changed", "Helper build inputs changed during compilation.")
            try directory.write("complete", data: Data(key.utf8))
        }
        let products = entry.appendingPathComponent("Build/Products", isDirectory: true)
        let templates = try RuntimeFiles.entries(products, limit: 32).filter {
            $0.hasSuffix(".xctestrun")
        }
        try requireRuntime(
            templates.count == 1, "cache_invalid", "Expected one helper test configuration.")
        return CachedHelper(
            products: products, template: products.appendingPathComponent(templates[0]),
            key: key, reused: reused)
    }

    static func fingerprint(source: URL, identity: ToolchainIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        hash.update(data: try encoder.encode(identity))
        hash.update(data: Data("Debug;generic-iOS-Simulator;unsigned;protocol-1;lifecycle-1".utf8))
        for path in inputs {
            let data = try RuntimeFiles.read(source.appendingPathComponent(path), limit: 1_048_576)
            hash.update(data: Data("\(path):\(data.count):".utf8))
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
