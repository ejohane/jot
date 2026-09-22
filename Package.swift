// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Jot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Jot", targets: ["Jot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Jot",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Jot",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "JotTests",
            dependencies: ["Jot"],
            path: "Tests/JotTests"
        ),
    ]
)
