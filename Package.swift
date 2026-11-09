// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cartridge",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Cartridge",
            path: "Sources/Cartridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
