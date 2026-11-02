import Foundation

public enum SettingsDevActionAdmission {
  public static func admits(_ action: String, environment: [String: String]) -> Bool {
    #if DEBUG
    guard action == "pairingFixture", environment["SOLARA_BACKGROUND"] == "1",
      environment["SOLARA_SYNC_PAIRING_FIXTURE"] == "1",
      let path = environment["SOLARA_DATA_DIR"], path.hasPrefix("/"), path != "/" else { return false }
    let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    let marker = directory.appendingPathComponent(".solara-probe-scratch")
    guard let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true else { return false }
    return true
    #else
    return false
    #endif
  }
}
