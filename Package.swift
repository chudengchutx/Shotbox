// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shotbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Shotbox",
            path: "Sources/Shotbox",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
