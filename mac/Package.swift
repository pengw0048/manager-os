// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ManagerOS",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ManagerOS", targets: ["ManagerOSApp"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "ManagerCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ManagerOSApp", dependencies: ["ManagerCore"]),
        .testTarget(name: "ManagerCoreTests", dependencies: ["ManagerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
