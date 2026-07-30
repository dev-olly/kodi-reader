// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EpubReaderCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EpubKit", targets: ["EpubKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        .target(
            name: "EpubKit",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .testTarget(name: "EpubKitTests", dependencies: ["EpubKit"]),
    ]
)
