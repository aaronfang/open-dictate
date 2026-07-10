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
            path: "Sources",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Info.plist",
                ])
            ]
        )
    ]
)

