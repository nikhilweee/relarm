// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Relarm",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RelarmCore", targets: ["RelarmCore"]),
        .executable(name: "Relarm", targets: ["Relarm"]),
    ],
    targets: [
        .target(name: "RelarmCore"),
        .executableTarget(name: "Relarm", dependencies: ["RelarmCore"]),
        .testTarget(name: "RelarmCoreTests", dependencies: ["RelarmCore"]),
    ]
)
