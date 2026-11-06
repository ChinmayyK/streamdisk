// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamDisk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "streamdisk", targets: ["streamdisk"]),
    ],
    targets: [
        // NFSv3 + MOUNT server over ONC RPC. Knows nothing about Drive.
        .target(name: "NFSServer"),
        // Google Drive client, auth, chunk cache, and the Drive-backed file system.
        .target(name: "StreamDiskCore", dependencies: ["NFSServer"]),
        .executableTarget(name: "streamdisk", dependencies: ["StreamDiskCore", "NFSServer"]),
        // Sample volume for website screenshots; not part of the app.
        .executableTarget(name: "demo-volume", dependencies: ["NFSServer"]),
        .testTarget(name: "NFSServerTests", dependencies: ["NFSServer"]),
        .testTarget(name: "StreamDiskCoreTests", dependencies: ["StreamDiskCore", "NFSServer"]),
    ]
)
