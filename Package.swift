// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "TSRP",
    platforms: [
        .macOS("15.1")
    ],
    products: [
        .library(
            name: "TSRP",
            targets: ["TSRP"]
        )
    ],
    targets: [
        .target(
            name: "TSRP",
            dependencies: []
        )
    ]
)
