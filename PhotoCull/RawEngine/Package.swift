// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RawEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RawEngine", targets: ["RawEngine"])
    ],
    targets: [
        // Prebuilt Open Image Denoise 2.5.1 (Apache-2.0) dylibs, wrapped as XCFrameworks —
        // see Vendor/OpenImageDenoise-LICENSE.txt. Split into three binary targets (one per
        // dylib) because OIDN ships as a main library plus two co-dependent dylibs (a shared
        // "core" and a Metal device backend the main library dlopens by name at runtime,
        // never linked against directly) rather than one self-contained bundle; each needs to
        // land in the app's embedded-binaries output for `@loader_path`-relative resolution to
        // work; see the target comment below and `DenoiseFilter.swift` for the runtime story.
        .binaryTarget(name: "OpenImageDenoiseXCF", path: "Vendor/OpenImageDenoise.xcframework"),
        .binaryTarget(name: "OpenImageDenoiseCoreXCF", path: "Vendor/OpenImageDenoiseCore.xcframework"),
        .binaryTarget(name: "OpenImageDenoiseDeviceMetalXCF", path: "Vendor/OpenImageDenoiseDeviceMetal.xcframework"),
        // Thin C target exposing OpenImageDenoise/oidn.h to Swift as a Clang module. Depends on
        // all three binary targets (not just the one it links symbols from) purely so the other
        // two ride along in the link/embed graph — OIDN's main library dlopens them by relative
        // path at runtime, so nothing in Swift ever calls into them directly, but they still have
        // to end up embedded next to it in the app bundle.
        .target(
            name: "COpenImageDenoise",
            dependencies: ["OpenImageDenoiseXCF", "OpenImageDenoiseCoreXCF", "OpenImageDenoiseDeviceMetalXCF"]
        ),
        .target(
            name: "RawEngine",
            dependencies: ["COpenImageDenoise"],
            resources: [.copy("LensCorrection/Resources/db")]
        ),
        .testTarget(name: "RawEngineTests", dependencies: ["RawEngine"])
    ]
)
