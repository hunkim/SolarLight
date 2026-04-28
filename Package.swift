// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SolarLight",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SolarLight", targets: ["SolarLight"])
    ],
    targets: [
        .executableTarget(
            name: "SolarLight",
            path: "Sources"
        )
    ]
)
