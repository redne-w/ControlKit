import Foundation

package enum ControlKitVersion {
    /// Git tags are the only version source. Packaging writes `git describe` output beside the
    /// installed helper sources: "v1.2.3" for a release, "v1.2.3-4-gabc1234-dirty" for a local
    /// build. A binary run straight from a build directory has no such file.
    package static let description: String = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return "development build"
        }
        let info = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/ControlKit/build-info")
        guard let data = try? RuntimeFiles.read(info, limit: 256),
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty, !text.contains(where: \.isNewline)
        else { return "development build" }
        return text.hasPrefix("v") ? String(text.dropFirst()) : text
    }()
}
