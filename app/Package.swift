// swift-tools-version:5.9
// The kirki Mac app. Build the app bundle with ./build-app.sh (it runs swift build and signs the app);
// run the tests with: swift test
import PackageDescription

let package = Package(
    name: "kirki",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "kirki", targets: ["kirki"])],
    targets: [
        // Everything that doesn't need a window or a virtual machine, so it can be tested on its own
        .target(name: "KirkiCore", path: "Sources/KirkiCore"),
        .executableTarget(
            name: "kirki",
            dependencies: ["KirkiCore"],
            path: "Sources/kirki",
            linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "KirkiCoreTests",
            dependencies: ["KirkiCore"],
            path: "Tests/KirkiCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
