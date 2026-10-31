// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "darkroom",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Darkroom", targets: ["Darkroom"]),
        .executable(name: "darkroom", targets: ["DarkroomCLI"]),
    ],
    targets: [
        .target(name: "Darkroom"),
        .target(name: "DarkroomSetup"),
        .executableTarget(name: "DarkroomCLI", dependencies: ["DarkroomSetup"]),
        .testTarget(name: "DarkroomSetupTests", dependencies: ["DarkroomSetup"]),
    ]
)
