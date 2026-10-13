// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ControlKit",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ControlKit", targets: ["ControlKit"])],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.6.1"
        )
    ],
    targets: [
        // Production primitives have no CLI, XCTest, networking, or reference-model dependency.
        .target(name: "ControlKitCore"),
        .target(name: "ControlKitDiscovery", dependencies: ["ControlKitCore"]),
        .target(name: "ControlKitProcess"),
        .target(name: "ControlKitWire"),
        .target(name: "ControlKitSession"),
        .target(
            name: "ControlKitSupervisor",
            dependencies: [
                "ControlKitDiscovery", "ControlKitRuntime", "ControlKitSession", "ControlKitWire",
            ]),
        .target(
            name: "ControlKitRuntime",
            dependencies: [
                "ControlKitProcess", "ControlKitWire", "ControlKitDiscovery", "ControlKitSession",
            ]),
        .target(name: "ControlKitProbeCore"),
        .target(
            name: "ControlKitProbeCLI",
            dependencies: [
                "ControlKitProbeCore",
                "ControlKitDiscovery",
                "ControlKitRuntime",
                "ControlKitSupervisor",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Executable design examples only; the CLI must not depend on this reference model.
        .target(name: "ControlKitContractSpecification", path: "Specification"),
        .target(
            name: "ControlKitTestSupport", dependencies: ["ControlKitCore"], path: "Tests/Support"
        ),
        .executableTarget(
            name: "ControlKit",
            dependencies: [
                "ControlKitProbeCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ControlKitCoreTests", dependencies: ["ControlKitCore", "ControlKitTestSupport"]
        ),
        .testTarget(
            name: "ControlKitDiscoveryTests",
            dependencies: ["ControlKitDiscovery", "ControlKitCore", "ControlKitTestSupport"]
        ),
        .testTarget(name: "ControlKitProcessTests", dependencies: ["ControlKitProcess"]),
        .testTarget(name: "ControlKitWireTests", dependencies: ["ControlKitWire"]),
        .testTarget(name: "ControlKitSessionTests", dependencies: ["ControlKitSession"]),
        .testTarget(name: "ControlKitSupervisorTests", dependencies: ["ControlKitSupervisor"]),
        .testTarget(
            name: "ControlKitRuntimeTests",
            dependencies: ["ControlKitRuntime", "ControlKitProcess"]
        ),
        .testTarget(
            name: "ControlKitTestSupportTests",
            dependencies: ["ControlKitTestSupport", "ControlKitCore"]),
        .testTarget(name: "ControlKitProbeCoreTests", dependencies: ["ControlKitProbeCore"]),
        .testTarget(
            name: "ControlKitContractTests",
            dependencies: [
                "ControlKitContractSpecification", "ControlKitTestSupport", "ControlKitCore",
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
