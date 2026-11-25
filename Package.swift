// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flux", targets: ["Flux"]),
        .library(name: "FluxCore", targets: ["FluxCore"]),
    ],
    targets: [
        .target(
            name: "FluxCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Flux",
            dependencies: ["FluxCore"]
        ),
        .testTarget(
            name: "FluxCoreTests",
            dependencies: ["FluxCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
