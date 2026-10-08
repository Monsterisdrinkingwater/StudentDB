// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StudentDB",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
    ],
    targets: [
        .executableTarget(
            name: "StudentDB",
            path: "Sources/StudentDB"
        ),
        .testTarget(
            name: "StudentDBTests",
            dependencies: ["StudentDB"],
            path: "Tests/StudentDBTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
