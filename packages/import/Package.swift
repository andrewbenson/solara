// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "SolaraLegacyImportCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "SolaraLegacyImportCore", targets: ["SolaraLegacyImportCore"])],
  targets: [
    .target(name: "SolaraLegacyImportCore", path: "ios/Core", linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(
      name: "SolaraLegacyImportCoreTests",
      dependencies: ["SolaraLegacyImportCore"],
      path: "tests",
      exclude: ["environment-host"]
    ),
  ]
)
