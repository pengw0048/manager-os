// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SlackWebKitSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SlackWebKitSpike", exclude: ["hook.js"]),
    ],
    swiftLanguageVersions: [.v5]
)
