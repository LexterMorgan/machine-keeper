// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "machine-keeper-bar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "mkbar", targets: ["MkBar"])
    ],
    targets: [
        .target(name: "MkBarCore"),
        .executableTarget(name: "MkBar", dependencies: ["MkBarCore"]),
        .testTarget(
            name: "MkBarCoreTests",
            dependencies: ["MkBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
