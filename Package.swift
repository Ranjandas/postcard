// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Postcard",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.0"),
    ],
    targets: [
        .executableTarget(
            name: "Postcard",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ],
            resources: [
                .copy("Public")
            ]
        ),
    ]
)
