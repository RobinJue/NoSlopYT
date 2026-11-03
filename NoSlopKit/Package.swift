// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoSlopKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "NoSlopKit", targets: ["NoSlopKit"]),
    ],
    targets: [
        .target(
            name: "NoSlopKit"
        ),
        .testTarget(
            name: "NoSlopKitTests",
            dependencies: ["NoSlopKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
