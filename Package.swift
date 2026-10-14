// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DictationIsland",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "DictationIsland",
            path: "Sources/DictationIsland",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
