// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lang-flip",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LangFlip",
            path: "Sources/LangFlip",
            resources: [
                .copy("Dictionaries"),
            ]
        )
    ]
)
