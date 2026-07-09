// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenDictateMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OpenDictateMac", targets: ["OpenDictateMac"])
    ],
    targets: [
        .executableTarget(
            name: "OpenDictateMac",
            path: "Sources"
        )
    ]
)

