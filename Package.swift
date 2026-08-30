// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Oatmeal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OatmealCore", targets: ["OatmealCore"]),
        .executable(name: "Oatmeal", targets: ["OatmealApp"]),
    ],
    targets: [
        .target(name: "OatmealCore"),
        .executableTarget(name: "OatmealApp", dependencies: ["OatmealCore"]),
        .testTarget(name: "OatmealCoreTests", dependencies: ["OatmealCore"]),
    ]
)
