// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Domain",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(
            name: "DomainEntityTests",
            dependencies: ["Domain"],
            path: "Tests/DomainEntityTests",
            resources: [
                .copy("Fixtures/fsrs_golden_v1.json"),
            ]
        ),
    ]
)
