// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lang-flip",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-update framework. Release builds must resolve reproducibly.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3"),
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
        ),
        .testTarget(
            name: "LangFlipTests",
            dependencies: ["LangFlip"],
            path: "Tests/LangFlipTests"
        )
    ]
)
