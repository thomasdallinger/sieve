// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sieve",
    platforms: [.macOS(.v14)],
    targets: [
        // UI-free engine: directory reading, the filename index, matching, sorting, filtering, the local LLM client.
        .target(name: "SieveCore", path: "Sources/SieveCore"),
        .executableTarget(
            name: "Sieve",
            dependencies: ["SieveCore"],
            path: "Sources/Sieve",
            linkerSettings: [.linkedFramework("Quartz"), .linkedFramework("QuickLookThumbnailing")]
        ),
        // Assertions and benchmarks for SieveCore (XCTest is not available with the Command Line Tools alone).
        .executableTarget(name: "sieve-check", dependencies: ["SieveCore"], path: "Sources/SieveCheck"),
    ]
)
