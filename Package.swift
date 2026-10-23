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
        ),
        .testTarget(
            name: "TSRPTests",
            dependencies: ["TSRP"]
        ),
        // A development tool that checks TSRP against a real Voice Memos library.
        // It is not a product, so packages that depend on TSRP don't build it.
        .executableTarget(
            name: "Validate",
            dependencies: ["TSRP"],
            path: "Tools/Validate"
        ),
    ]
)
