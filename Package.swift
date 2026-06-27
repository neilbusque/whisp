// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisp",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WhispCore"),
        .testTarget(name: "WhispCoreTests", dependencies: ["WhispCore"]),
    ]
)
