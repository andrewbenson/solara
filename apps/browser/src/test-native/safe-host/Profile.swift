import Foundation

enum SolaraCoreHost {
  static var safeMode = false
  static var dataDirectory: String { ProcessInfo.processInfo.environment["TMPDIR"]! }
  static func deleteProfileData(_ profile: String, deletionAllowed: () -> Bool, completion: ([String]) -> Void) { completion([]) }
}
enum SolaraCoreServices {
  static var calls: [String] = []
  static func clearBrowsingData(profile: String, types: [String], since: Int, completion: () -> Void) { calls.append("clearBrowsingData"); completion() }
  static func call(_ name: String, profile: String, args: [String: Any]?, completion: ([String: Any]) -> Void) { calls.append(name); completion(["ok": true]) }
  static func addresses(profile: String, completion: ([String: Any]) -> Void) { calls.append("addresses"); completion(["addresses": []]) }
  static func cards(profile: String, completion: ([String: Any]) -> Void) { calls.append("cards"); completion(["cards": []]) }
  static func deleteAutofillEntry(_ id: String, profile: String, completion: (Bool) -> Void) { calls.append("deleteAutofillEntry"); completion(true) }
  static func setExtension(_ id: String, enabled: Bool, profile: String, completion: (Bool) -> Void) { calls.append("setExtension"); completion(true) }
  static func listPasswords(profile: String, completion: ([String: Any]) -> Void) { calls.append("listPasswords"); completion(["passwords": []]) }
  static func neverSaveOrigins(profile: String, completion: ([String: Any]) -> Void) { calls.append("neverSaveOrigins"); completion(["origins": []]) }
  static func allowSaving(profile: String, origin: String, completion: (Bool) -> Void) { calls.append("allowSaving"); completion(true) }
  static func deletePassword(profile: String, origin: String, username: String, completion: (Bool) -> Void) { calls.append("deletePassword"); completion(true) }
  static func listExtensions(profile: String, completion: ([String: Any]) -> Void) { calls.append("listExtensions"); completion(["extensions": []]) }
  static func siteSettingsOrigins(profile: String, completion: ([String]) -> Void) { calls.append("siteSettingsOrigins"); completion([]) }
  static func zoomLevels(profile: String, completion: ([String: Double]) -> Void) { calls.append("zoomLevels"); completion([:]) }
  static func setZoom(_ level: Double, profile: String, host: String) { calls.append("setZoom") }
}

__PRODUCTION__

var results: [[String: Any]] = []
for safe in [true, false] {
  SolaraCoreHost.safeMode = safe
  SolaraCoreServices.calls = []
  var callbacks = 0
  var remaining: [String] = []
  SolaraCoreProfileData.deleteDefault { callbacks += 1; remaining = $0 }
  results.append(["safe": safe, "remaining": remaining, "callbacks": callbacks, "calls": SolaraCoreServices.calls])
}
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
