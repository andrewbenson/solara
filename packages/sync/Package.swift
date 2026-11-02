// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "SolaraLegacySyncCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "SolaraLegacySyncCore", targets: ["SolaraLegacySyncCore"]),
  ],
  targets: [
    .target(name: "SolaraLegacySyncCore", path: "ios", exclude: ["SyncModule.swift", "SolaraSyncAdapter.podspec"], sources: ["Core", "PairingCoordinator.swift"], swiftSettings: [.define("SOLARA_PAIRING_TESTING", .when(configuration: .debug))]),
    .testTarget(name: "SolaraLegacySyncCoreTests", dependencies: ["SolaraLegacySyncCore"], path: "tests", exclude: ["fixtures"]),
  ]
)
