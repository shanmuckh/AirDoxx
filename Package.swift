// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirDoxx",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AirDoxx",
            path: "Sources/AirDoxx"
        )
    ]
)
