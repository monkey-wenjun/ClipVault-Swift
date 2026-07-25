// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipVault",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipVault",
            path: "Sources/MyPaste",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
