// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhereDatSpace",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SpaceCore", targets: ["SpaceCore"]), .executable(name: "WhereDatSpace", targets: ["WhereDatSpace"])],
    targets: [
        .target(name: "SpaceScan", publicHeadersPath: "include"),
        .target(name: "SpaceCore", dependencies: ["SpaceScan"]),
        .executableTarget(name: "WhereDatSpace", dependencies: ["SpaceCore"], resources: [.process("Resources")]),
        .testTarget(name: "SpaceCoreTests", dependencies: ["SpaceCore"])
    ]
)
