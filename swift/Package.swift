// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Fringe",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Fringe", targets: ["Fringe"])
    ],
    targets: [
        .target(
            name: "CFringeCore",
            path: "Sources/CFringeCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Fringe",
            dependencies: ["CFringeCore"],
            path: "Sources/Fringe",
            linkerSettings: [
                .unsafeFlags(["-L../target/release", "-lfringe_core"]),
                // faer's thread pool (spindle, via atomic-wait) calls libc++'s atomic
                // wait/notify; `cargo rustc -- --print native-static-libs` lists it.
                .linkedLibrary("c++")
            ]
        )
    ]
)
