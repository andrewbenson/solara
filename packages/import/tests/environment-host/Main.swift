import Foundation

@main
struct ImportEnvironmentHost {
  static func main() throws {
    let support = ImportEnvironment.applicationSupport.path
    let home = ImportEnvironment.safariHome.path
    let secret = try ImportEnvironment.secret("controlled-service", "controlled-account")
    let bundle = ImportEnvironment.diaBundleId
    #if DEBUG
    let enabled = !(ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] ?? "").isEmpty
    #else
    let enabled = false
    #endif
    let expectedSupport = enabled ? "/fixture/Library/Application Support" : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
    let expectedHome = enabled ? "/safari-fixture" : FileManager.default.homeDirectoryForCurrentUser.path
    precondition(support == expectedSupport)
    precondition(home == expectedHome)
    precondition(secret == Data((enabled ? "fixture-secret" : "controlled-keychain-provider").utf8))
    precondition(bundle == (enabled ? "fixture.dia" : DiaAutomation.bundleIdentifier))
    #if DEBUG
    precondition(ImportEnvironment.diaFixture == (enabled ? "/fixture/dia.json" : nil))
    #endif
    print("environment behavior verified")
  }
}
