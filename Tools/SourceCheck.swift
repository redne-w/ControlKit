import Foundation

// Development audit only. The compiler supplies declaration ranges; do not count braces in strings.
struct AuditFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func readText(_ path: String, limit: Int) throws -> String {
    let handle =
        path == "-"
        ? FileHandle.standardInput
        : try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { if path != "-" { try? handle.close() } }
    var data = Data()
    while data.count <= limit {
        let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
        throw AuditFailure("\(path): exceeds input limit or is not UTF-8")
    }
    return text
}

func checkLines(_ source: String, path: String) throws {
    for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
    {
        guard line.count <= 100 else {
            throw AuditFailure("\(path):\(index + 1): exceeds 100 columns")
        }
        guard !line.contains("\t") else {
            throw AuditFailure("\(path):\(index + 1): tab indentation is not allowed")
        }
    }
}

func checkFunctions(_ ast: String, path: String) throws {
    guard ast.hasPrefix("(source_file ") else {
        throw AuditFailure("\(path): unrecognized compiler parse output")
    }
    let kinds = ["func_decl", "constructor_decl", "destructor_decl", "accessor_decl"]
    let pattern = #"range=\[.*:([0-9]+):[0-9]+ - line:([0-9]+):[0-9]+\]"#
    let range = try NSRegularExpression(pattern: pattern)
    for line in ast.split(separator: "\n") {
        let text = String(line.trimmingCharacters(in: .whitespaces))
        guard kinds.contains(where: { text.hasPrefix("(\($0) ") }) else { continue }
        if text.contains(" implicit ") { continue }
        guard let match = range.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let startRange = Range(match.range(at: 1), in: text),
            let endRange = Range(match.range(at: 2), in: text),
            let start = Int(text[startRange]), let end = Int(text[endRange]),
            start > 0, end >= start
        else { throw AuditFailure("\(path): declaration range format changed; review the checker") }
        guard end - start + 1 <= 70 else {
            throw AuditFailure("\(path):\(start): function exceeds 70 lines")
        }
    }
}

struct Manifest: Decodable {
    struct Target: Decodable {
        struct Dependency: Decodable {
            let byName: [String?]?
            let target: [String?]?
            let product: [String?]?

            func name() throws -> String {
                guard let value = (byName ?? target ?? product)?.first, let value else {
                    throw AuditFailure("Unrecognized target dependency")
                }
                return value
            }
        }
        let name: String
        let type: String
        let dependencies: [Dependency]
    }
    let targets: [Target]
    let swiftLanguageVersions: [String]
}

func checkPackage(_ text: String) throws {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(text.utf8))
    guard manifest.targets.count <= 64, manifest.swiftLanguageVersions == ["6"] else {
        throw AuditFailure("Expected at most 64 targets and explicit Swift 6 language mode")
    }
    var dependencies: [String: [String]] = [:]
    for target in manifest.targets {
        guard dependencies[target.name] == nil else { throw AuditFailure("Duplicate target") }
        dependencies[target.name] = try target.dependencies.map { try $0.name() }
    }
    guard dependencies["ControlKitCore"] == [],
        dependencies["ControlKitContractSpecification"] == []
    else {
        throw AuditFailure("Core and reference specification must remain dependency-free")
    }
    let testOnly = Set(["ControlKitTestSupport", "ControlKitContractSpecification"])
    for target in manifest.targets where target.type != "test" && !testOnly.contains(target.name) {
        var pending = [target.name]
        var visited: Set<String> = []
        while let name = pending.popLast() {
            guard visited.insert(name).inserted else { continue }
            guard !testOnly.contains(name) else {
                throw AuditFailure("\(target.name) reaches test-only target \(name)")
            }
            // Each target is expanded once. The package manifest, not source imports, is authority.
            pending.append(contentsOf: dependencies[name] ?? [])
        }
    }
}

func expectFailure(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch is AuditFailure {
        return
    }
    throw AuditFailure("Source-check self-test failed to reject invalid input")
}

func selfTest() throws {
    try checkLines(String(repeating: "a", count: 100), path: "fixture")
    try expectFailure { try checkLines(String(repeating: "a", count: 101), path: "fixture") }
    try expectFailure { try checkLines("\tlet a = 1", path: "fixture") }
    let prefix = "(source_file \"fixture\"\n"
    try checkFunctions(prefix + "(func_decl range=[fixture:1:1 - line:70:1])", path: "fixture")
    try expectFailure {
        try checkFunctions(prefix + "(func_decl range=[fixture:1:1 - line:71:1])", path: "fixture")
    }
    try expectFailure { try checkFunctions(prefix + "(func_decl unknown)", path: "fixture") }
    let package = """
        {"swiftLanguageVersions":["6"],"targets":[
        {"name":"ControlKitCore","type":"regular","dependencies":[]},
        {"name":"ControlKitContractSpecification","type":"regular","dependencies":[]},
        {"name":"ControlKit","type":"executable","dependencies":[]}]}
        """
    try checkPackage(package)
    let contaminated = package.replacingOccurrences(
        of: #""name":"ControlKit","type":"executable","dependencies":[]"#,
        with: """
            "name":"ControlKit","type":"executable",
            "dependencies":[{"byName":["ControlKitContractSpecification",null]}]
            """)
    try expectFailure { try checkPackage(contaminated) }
    print("Source and package checker self-tests passed.")
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.isEmpty {
        print(
            """
            Usage: SourceCheck self-test | source <file> | functions <source-path> <ast-file>
                   SourceCheck package <dump-package-json>
            Local checks only. Prefer `just source-check`; compiler format changes fail closed.
            Use - for a bounded stdin stream instead of an input file.
            Inputs: source <= 1 MiB; compiler dump <= 8 MiB; manifest <= 1 MiB.
            """)
        if arguments.isEmpty { throw AuditFailure("Missing command") }
        return
    }
    switch arguments.first {
    case "self-test" where arguments.count == 1: try selfTest()
    case "source" where arguments.count == 2:
        try checkLines(readText(arguments[1], limit: 1_048_576), path: arguments[1])
    case "functions" where arguments.count == 3:
        try checkFunctions(readText(arguments[2], limit: 8_388_608), path: arguments[1])
    case "package" where arguments.count == 2:
        try checkPackage(readText(arguments[1], limit: 1_048_576))
    default: throw AuditFailure("Invalid arguments; see --help")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
