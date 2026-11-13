// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Filsynk",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FilsynkCore"),
        .executableTarget(name: "Filsynk", dependencies: ["FilsynkCore"]),
        .testTarget(name: "FilsynkCoreTests", dependencies: ["FilsynkCore"]),
    ]
)
