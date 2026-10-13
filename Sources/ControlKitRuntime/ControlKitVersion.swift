import Foundation

package enum ControlKitVersion {
    package static let number = "0.1.0"

    /// Testers install from source, so the commit identifies their build more precisely than the
    /// version number. `install-local.sh` records it beside the installed helper sources.
    package static let description: String = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return number
        }
        let info = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/ControlKit/build-info")
        guard let data = try? RuntimeFiles.read(info, limit: 256),
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty, !text.contains(where: \.isNewline)
        else { return "\(number) (development build)" }
        return "\(number) (\(text))"
    }()
}
