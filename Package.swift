// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    products: [
        .executable(name: "transcriber-linux", targets: ["TranscriberLinux"]),
        .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
        .executable(name: "transcriber-mac", targets: ["TranscriberMac"])
    ],
    dependencies: [
        // Note: gir2swift and SwiftGtk don't have stable releases yet.
        // These are pinned to specific commits for reproducibility.
        .package(url: "https://github.com/rhx/gir2swift.git", revision: "5e36269"),
        .package(url: "https://github.com/rhx/SwiftGtk.git", revision: "1c7e0f9"),
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.14.0")
    ],
    targets: [
        .executableTarget(
            name: "TranscriberLinux",
            dependencies: [
                .product(name: "Gtk", package: "SwiftGtk"),
                "TranscriberCore"
            ],
            linkerSettings: [.linkedLibrary("pulse")]
        ),
        .target(
            name: "TranscriberCore",
            dependencies: [
                .product(name: "OpenCombine", package: "OpenCombine", condition: .when(platforms: [.linux])),
                .product(name: "OpenCombineDispatch", package: "OpenCombine", condition: .when(platforms: [.linux])),
                .product(name: "OpenCombineFoundation", package: "OpenCombine", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/TranscriberCore"
        ),
        .executableTarget(
            name: "TranscriberMac",
            dependencies: ["TranscriberCore"],
            path: "Sources/TranscriberMac"
        )
    ]
)
