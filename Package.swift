// swift-tools-version:6.0
import PackageDescription

// AIDEV-NOTE: SwiftPM-only build (no Xcode on this box). scripts/build.sh assembles + signs Hermes.app.
let package = Package(
    name: "HermesMac",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "HermesKit",
            path: "Sources/HermesKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HermesMac",
            dependencies: ["HermesKit"],
            path: "Sources/HermesMac",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("Speech"),
                .linkedFramework("Security"),
            ]
        ),
        // AIDEV-NOTE: CLT has no XCTest and no Testing macro plugin, so checks are a plain executable:
        // `swift run hermes-checks` (exit 1 on any failure).
        .executableTarget(
            name: "hermes-checks",
            dependencies: ["HermesKit"],
            path: "Sources/HermesChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
