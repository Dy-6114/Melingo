// swift-tools-version: 6.0
import PackageDescription

/// Workspace package: aggregates local SPM packages for CI (`swift test`).
/// The macOS App target is the Xcode composition root; it links these packages.
let package = Package(
    name: "MelingoMac",
    platforms: [.macOS(.v15)],
    products: [],
    dependencies: [
        .package(path: "Packages/Domain"),
        .package(path: "Packages/DataKit"),
        .package(path: "Packages/SharedTestSupport"),
    ],
    targets: [
        .testTarget(
            name: "DomainUseCaseTests",
            dependencies: [
                .product(name: "Domain", package: "Domain"),
                .product(name: "SharedTestSupport", package: "SharedTestSupport"),
            ],
            path: "Tests/DomainUseCaseTests"
        ),
    ]
)
