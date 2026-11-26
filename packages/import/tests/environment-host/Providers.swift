import Foundation

enum Importer {
  typealias SecretProvider = (String, String) throws -> Data
}

enum SafeStorageKeychain {
  static func secret(_ service: String, _ account: String) throws -> Data {
    precondition(service == "controlled-service" && account == "controlled-account")
    return Data("controlled-keychain-provider".utf8)
  }
}

enum DiaAutomation {
  static let bundleIdentifier = "company.thebrowser.dia"
}
