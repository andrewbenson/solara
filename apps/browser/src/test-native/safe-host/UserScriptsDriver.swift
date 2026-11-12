import Foundation

enum SolaraCoreHost {
  static var safeMode = false
}

struct Setting { var bool: Bool }
struct BrowserState { var settings: [String: Setting] }
struct UserScriptsTarget { var engine = "" }

enum NativeProfileLoading {
  static func isLoaded(_ engine: String) -> Bool { true }
}

enum NativeStoreHandle {
  static var subscriptions = 0
  static func subscribeLifecycle(_ callback: @escaping () -> Void) -> Int {
    subscriptions += 1
    return subscriptions
  }
}

enum UserScriptsSync {
  static func targets(_ state: BrowserState) -> [UserScriptsTarget] { [] }
}

final class ScriptsSync {
  var requested: [Bool] = []
  func sync(enabled: Bool, targets: [UserScriptsTarget]) { requested.append(enabled) }
}

@MainActor
final class NativeUserScripts {
  static let shared = NativeUserScripts()
  var requested = false
  var lifecycle: Int?
  let sync = ScriptsSync()
  func prepare() {}
  __PRODUCTION__

  func change(_ state: BrowserState) { stateChanged(state) }
}

var results: [[String: Any]] = []
MainActor.assumeIsolated {
  for safe in [true, false] {
    SolaraCoreHost.safeMode = safe
    NativeStoreHandle.subscriptions = 0
    let scripts = NativeUserScripts()
    scripts.startWhenReady()
    scripts.change(BrowserState(settings: ["cliControl": Setting(bool: true)]))
    results.append(["safe": safe, "subscriptions": NativeStoreHandle.subscriptions, "sync": scripts.sync.requested])
  }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: results), as: UTF8.self))
