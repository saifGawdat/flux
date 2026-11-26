// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flux", targets: ["Flux"]),
        .library(name: "FluxCore", targets: ["FluxCore"]),
        // Installed as `flux`; a different build name avoids clashing with `Flux` on
        // case-insensitive disks.
        .executable(name: "flux-cli", targets: ["FluxCLI"]),
    ],
    dependencies: [
        // In-app updates (Phase 7). Pinned: updates change what users run.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ],
    targets: [
        .target(
            name: "FluxCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Flux",
            dependencies: ["FluxCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "FluxCLI",
            dependencies: ["FluxCore"]
        ),
        .testTarget(
            name: "FluxCoreTests",
            dependencies: ["FluxCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
