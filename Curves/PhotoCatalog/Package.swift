// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhotoCatalog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotoCatalog", targets: ["PhotoCatalog"])
    ],
    targets: [
        .target(name: "PhotoCatalog"),
        .testTarget(name: "PhotoCatalogTests", dependencies: ["PhotoCatalog"])
    ]
)
