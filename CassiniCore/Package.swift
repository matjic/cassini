// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CassiniCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CassiniCore", targets: ["CassiniCore"]),
    ],
    targets: [
        .target(name: "CassiniCore"),
        .testTarget(name: "CassiniCoreTests", dependencies: ["CassiniCore"]),
    ]
)
