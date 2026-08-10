// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Griasa",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Griasa",
            path: "Sources/Griasa"
        )
    ]
)
