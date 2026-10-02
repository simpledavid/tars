// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tars",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/simpledavid/greenbubbles.git", revision: "f3fab5ae0bc3fce20bc813569f2fac770081d9c7")
    ],
    targets: [
        .executableTarget(
            name: "HermesPet",
            dependencies: [
                .product(name: "GreenBubblesKnowledgeUI", package: "greenbubbles"),
                .product(name: "GreenBubblesHistoryUI", package: "greenbubbles")
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(name: "HermesPetTests", dependencies: ["HermesPet"], path: "Tests")
    ]
)
