// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeshDash",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MeshDash", targets: ["MeshDashApp"]),
        .library(name: "MeshtasticCore", targets: ["MeshtasticCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0"),
    ],
    targets: [
        .target(
            name: "MeshtasticProtobufs",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MeshtasticCore",
            dependencies: ["MeshtasticProtobufs"]
        ),
        .executableTarget(
            name: "MeshDashApp",
            dependencies: ["MeshtasticCore", "MeshtasticProtobufs"]
        ),
        .testTarget(
            name: "MeshtasticCoreTests",
            dependencies: ["MeshtasticCore", "MeshtasticProtobufs"]
        ),
    ]
)
