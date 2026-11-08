// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirDox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AirDox",
            path: "Sources/AirDox"
        )
    ]
)
