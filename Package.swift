// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cjkfts5",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "cjkfts5",
            targets: ["cjkfts5"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            .upToNextMajor(from: "7.5.0")
        )
    ],
    targets: [
        .target(
            name: "cjkfts5",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "cjkfts5"
        ),
        .testTarget(
            name: "cjkfts5Tests",
            dependencies: [
                "cjkfts5",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "cjkfts5Tests"
        )
    ]
)
