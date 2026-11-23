// swift-tools-version:6.0
import PackageDescription

// AIDEV-NOTE: SwiftPM-only build (no Xcode on this box). scripts/build.sh assembles + signs Hermes.app.
let package = Package(
    name: "HermesMac",
    platforms: [.macOS("26.0")],
    dependencies: [
        // AIDEV-NOTE: keep in step with SPARKLE_VERSION in scripts/ci/sparkle-tools.sh (sign_update/appcast).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "HermesKit",
            path: "Sources/HermesKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Loopback MCP listener (Network.framework) for the browser tool; kept out of HermesKit, which also builds on iOS.
        .target(
            name: "HermesMCPServer",
            dependencies: ["HermesKit"],
            path: "Sources/HermesMCPServer",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Network")]
        ),
        .executableTarget(
            name: "HermesMac",
            dependencies: ["HermesKit", "HermesMCPServer", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/HermesMac",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Speech"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        // AIDEV-NOTE: CLT has no XCTest and no Testing macro plugin, so checks are a plain executable:
        // `swift run hermes-checks` (exit 1 on any failure).
        .executableTarget(
            name: "hermes-checks",
            dependencies: ["HermesKit", "HermesMCPServer"],
            path: "Sources/HermesChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
