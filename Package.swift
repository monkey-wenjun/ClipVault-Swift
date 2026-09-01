// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipVault",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClipVault",
            path: "Sources/MyPaste",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
