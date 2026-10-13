// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lidless",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "lidless", targets: ["lidless"]),
        .executable(name: "LidlessApp", targets: ["LidlessApp"]),
    ],
    targets: [
        .target(
            name: "LidlessCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "lidless",
            dependencies: ["LidlessCore"]
        ),
        .executableTarget(
            name: "LidlessApp",
            dependencies: ["LidlessCore"]
        ),
        .testTarget(
            name: "LidlessCoreTests",
            dependencies: ["LidlessCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
