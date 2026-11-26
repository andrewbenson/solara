import Foundation

enum ImportEnvironment {
  #if DEBUG
  static var isolated: Bool { !(ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] ?? "").isEmpty }

  static func fixtureValue(_ key: String) -> String? {
    guard isolated, let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
    return value
  }
  #endif

  static var applicationSupport: URL {
    #if DEBUG
    if let support = fixtureValue("SOLARA_IMPORT_SOURCE_DIR") { return URL(fileURLWithPath: support, isDirectory: true) }
    #endif
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  static var safariHome: URL {
    #if DEBUG
    if let home = fixtureValue("SOLARA_IMPORT_SAFARI_HOME") { return URL(fileURLWithPath: home, isDirectory: true) }
    if let support = fixtureValue("SOLARA_IMPORT_SOURCE_DIR") {
      return URL(fileURLWithPath: support, isDirectory: true).deletingLastPathComponent().deletingLastPathComponent()
    }
    #endif
    return FileManager.default.homeDirectoryForCurrentUser
  }

  static var secret: Importer.SecretProvider {
    #if DEBUG
    if let fixed = fixtureValue("SOLARA_IMPORT_TEST_SECRET") { return { _, _ in Data(fixed.utf8) } }
    #endif
    return SafeStorageKeychain.secret
  }

  static var diaBundleId: String {
    #if DEBUG
    if let bundle = fixtureValue("SOLARA_IMPORT_DIA_BUNDLE_ID") { return bundle }
    #endif
    return DiaAutomation.bundleIdentifier
  }

  #if DEBUG
  static var diaFixture: String? { fixtureValue("SOLARA_IMPORT_DIA_FIXTURE") }
  #endif
}
