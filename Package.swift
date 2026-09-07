// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SideloadManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SideloadManager", targets: ["SideloadManager"])
    ],
    targets: [
        .executableTarget(
            name: "SideloadManager",
            path: "Sources/SideloadManager"
        ),
        .testTarget(
            name: "SideloadManagerTests",
            dependencies: ["SideloadManager"]
        )
    ]
)
