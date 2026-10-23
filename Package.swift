// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "glovebox",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "glovebox-mcp", targets: ["glovebox-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(name: "glovebox-mcp", dependencies: ["GloveboxServer"]),
        .target(
            name: "GloveboxServer",
            dependencies: [
                "SimBridge",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .target(name: "SimBridge", dependencies: ["SimBridgeObjC"]),
        .target(
            name: "SimBridgeObjC",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(name: "SimBridgeTests", dependencies: ["SimBridge"]),
        .testTarget(
            name: "GloveboxServerTests",
            dependencies: [
                "GloveboxServer",
                "SimBridge",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            // Read from the source tree by path, not bundled.
            exclude: ["Golden"]
        ),
    ]
)
