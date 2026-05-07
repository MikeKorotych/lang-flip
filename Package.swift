// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lang-flip",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-update framework. Pinned to a known-good 2.x release.
        // Bumping is fine within 2.x; 3.x will be a deliberate decision.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "LangFlip",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/LangFlip",
            resources: [
                .copy("Dictionaries"),
            ]
        )
    ]
)
