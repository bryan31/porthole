// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Porthole",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Porthole", targets: ["Porthole"])
    ],
    targets: [
        // Pure logic: models, ssh command builder, parsers, proxy handshakes. No UI.
        .target(
            name: "PortholeCore",
            path: "Sources/PortholeCore"
        ),
        // The macOS app (SwiftUI) plus the askpass / proxy helper modes of the same executable.
        .executableTarget(
            name: "Porthole",
            dependencies: ["PortholeCore"],
            path: "Sources/Porthole"
        ),
        .testTarget(
            name: "PortholeCoreTests",
            dependencies: ["PortholeCore"],
            path: "Tests/PortholeCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
