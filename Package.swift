// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Jot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Jot", targets: ["Jot"]),
    ],
    targets: [
        .executableTarget(
            name: "Jot",
            path: "Sources/Jot",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "JotTests",
            dependencies: ["Jot"],
            path: "Tests/JotTests"
        ),
    ]
)
