// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Beam",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Beam", targets: ["Beam"])
    ],
    targets: [
        .target(
            name: "CBeamCore",
            path: "Sources/CBeamCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Beam",
            dependencies: ["CBeamCore"],
            path: "Sources/Beam",
            linkerSettings: [
                .unsafeFlags(["-L../target/release", "-lbeam_core"])
            ]
        )
    ]
)
