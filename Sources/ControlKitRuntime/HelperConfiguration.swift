import ControlKitWire
import Foundation
import Security

enum HelperConfiguration {
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        try requireRuntime(
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
            "random_failed", "Cannot create a launch credential.")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func write(
        cached: CachedHelper, runtime: PrivateDirectory, identity: WireIdentity, token: String,
        port: UInt16, appBundleIdentifier: String = "com.apple.springboard"
    ) throws -> URL {
        let data = try RuntimeFiles.read(cached.template, limit: 1_048_576)
        guard
            var plist = try PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
            var target = plist["ControlKitRuntime"] as? [String: Any]
        else { throw RuntimeFailure("test_schema", "Unsupported xctestrun schema; do not guess.") }
        for key in ["TestBundlePath", "TestHostPath"] {
            guard let path = target[key] as? String else {
                throw RuntimeFailure("test_schema", "Missing helper product path.")
            }
            target[key] = path.replacingOccurrences(of: "__TESTROOT__", with: cached.products.path)
        }
        let paths = target["DependentProductPaths"] as? [String] ?? []
        target["DependentProductPaths"] = paths.map {
            $0.replacingOccurrences(of: "__TESTROOT__", with: cached.products.path)
        }
        for key in ["TestingEnvironmentVariables", "UITargetAppEnvironmentVariables"] {
            let values = target[key] as? [String: String] ?? [:]
            target[key] = values.mapValues {
                $0.replacingOccurrences(of: "__TESTROOT__", with: cached.products.path)
            }
        }
        target["EnvironmentVariables"] = [
            "CONTROLKIT_LAUNCH_TOKEN": token, "CONTROLKIT_HOST_PORT": "\(port)",
            "CONTROLKIT_IDENTITY": try JSONEncoder().encode(identity).base64EncodedString(),
            "CONTROLKIT_APP_BUNDLE_ID": appBundleIdentifier,
        ]
        plist["ControlKitRuntime"] = target
        let configured = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try runtime.write("launch.xctestrun", data: configured)
        return runtime.url.appendingPathComponent("launch.xctestrun")
    }
}
