// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContentImportKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ContentImportKit", targets: ["ContentImportKit"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "ContentImportKit",
            dependencies: [
                .product(name: "Domain", package: "Domain"),
            ]
        ),
        .testTarget(
            name: "ContentImportKitTests",
            dependencies: ["ContentImportKit"]
        ),
    ]
)
