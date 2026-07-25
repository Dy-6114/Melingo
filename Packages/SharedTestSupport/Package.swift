// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SharedTestSupport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SharedTestSupport", targets: ["SharedTestSupport"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "SharedTestSupport",
            dependencies: [
                .product(name: "Domain", package: "Domain"),
            ]
        ),
    ]
)
