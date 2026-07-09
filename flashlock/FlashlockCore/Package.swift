// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlashlockCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "FlashlockCore", targets: ["FlashlockCore"]),
        .executable(name: "flashlock-demo", targets: ["FlashlockDemo"]),
    ],
    targets: [
        .target(name: "FlashlockCore"),
        .executableTarget(name: "FlashlockDemo", dependencies: ["FlashlockCore"]),
        .testTarget(
            name: "FlashlockCoreTests",
            dependencies: ["FlashlockCore"],
            resources: [.copy("Resources")]
        ),
    ]
)
