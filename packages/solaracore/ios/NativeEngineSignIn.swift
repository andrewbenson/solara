import Foundation

@MainActor
public enum NativeEngineSignIn {
  public static var enabled: Bool { ProcessInfo.processInfo.environment["SOLARA_WEBKIT_SIGN_IN"] == "on" }
  public static func storeKey(profile: String) -> String { WebKitHub.shared.storeKey(profile) }
  public static func copy(cookies: [[String: Any]], profile: String, key: String, completion: @escaping (Int) -> Void) {
    let now = Date().timeIntervalSince1970
    let eligible = cookies.filter { cookie in
      guard let name = cookie["name"] as? String, !name.isEmpty, let domain = cookie["domain"] as? String, !domain.isEmpty,
        cookie["partitionKey"] == nil || cookie["partitionKey"] is NSNull, cookie["partitionKeyOpaque"] as? Bool != true else { return false }
      let expires = cookie["expires"] as? Double ?? 0
      return cookie["session"] as? Bool == true || expires <= 0 || expires > now
    }
    WebKitHub.shared.importCookies(eligible, profile: profile, storeKey: key, completion: completion)
  }
}
