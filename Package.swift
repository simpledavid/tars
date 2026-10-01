// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tars",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "HermesPet",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(name: "HermesPetTests", dependencies: ["HermesPet"], path: "Tests")
    ]
)
