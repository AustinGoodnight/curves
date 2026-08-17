// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RawEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RawEngine", targets: ["RawEngine"])
    ],
    targets: [
        .target(name: "RawEngine"),
        .testTarget(name: "RawEngineTests", dependencies: ["RawEngine"])
    ]
)
