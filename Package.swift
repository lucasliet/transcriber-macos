// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "transcriber-linux", targets: ["TranscriberLinux"]),
        .library(name: "TranscriberCore", targets: ["TranscriberCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/rhx/gir2swift.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGtk.git", branch: "gtk3"),
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
