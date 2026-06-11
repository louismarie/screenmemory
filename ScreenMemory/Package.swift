// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenMemory",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ScreenMemory",
            resources: [
                .copy("Resources/Embed.mlpackage"),
                .copy("Resources/vocab.txt"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
