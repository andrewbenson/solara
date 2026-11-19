import Foundation

enum SettingsAdapters {
  static var safe = false
  static var calls: [[Any]] = []
  static var effects = 0
  static func js(_ name: String, _ args: Any...) async -> Any? {
    calls.append([name] + args)
    if !safe { effects += 1 }
    return nil
  }
}
enum SolaraCoreHost {
  static var safeMode = false
}
enum SolaraCoreServices {
  static func clearBrowsingData(profile: String, types: [String], since: Double, completion: () -> Void) {
    SettingsAdapters.calls.append(["engine", profile, types, since])
    SettingsAdapters.effects += 1
    completion()
  }
}
enum SolaraCoreSettingsBridge {
  static func clearWebKitBrowsingData(profile: String, types: [String], since: Double, completion: () -> Void) {
    SettingsAdapters.calls.append(["webKit", profile, types, since])
    SettingsAdapters.effects += 1
    completion()
  }
}

__PRODUCTION__

var results: [[String: Any]] = []
for safe in [true, false] {
  SettingsAdapters.safe = safe
  SolaraCoreHost.safeMode = safe
  SettingsAdapters.calls = []
  SettingsAdapters.effects = 0
  await Adapter().clearBrowsingData(engineProfile: "engine-work", kinds: [.history, .siteData], since: Date(timeIntervalSince1970: 123))
  results.append(["safe": safe, "calls": SettingsAdapters.calls, "effects": SettingsAdapters.effects])
}
print(String(decoding: try JSONSerialization.data(withJSONObject: results), as: UTF8.self))
