import SolaraModel
import SolaraStore

@MainActor
enum NativeExtensionPageNavigation {
  static func openWindow(_ request: [String: Any], windowId: String, pageProfile: String) {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      let window = store.state.windows[windowId], let url = request["url"] as? String else { return }
    let state = store.state
    let profile = state.engineProfile(window.profileId) == pageProfile ? window.profileId
      : state.profileOrder.first { state.engineProfile($0) == pageProfile } ?? window.profileId
    let disposition = request["disposition"] as? String ?? "foreground"
    let adopt = request["adoptId"] as? String
    var options: JSONObject = ["url": .string(url), "profileId": .string(profile)]
    if let adopt { options["adoptId"] = .string(adopt) }
    if disposition == "current" || disposition == "peek" { return }
    if window.isSmall, disposition == "foreground", adopt != nil, state.settings["littleSolaraKeepsNewTabLinks"]?.truthy == true {
      options["small"] = true
      _ = try? store.dispatch(Command("createWindow", [.object(options)]), origin: .native)
    } else if window.isSmall, disposition != "window", disposition != "incognito" {
      options["background"] = true
      _ = try? store.dispatch(Command("newTab", [.string(window.id), .object(options)]), origin: .native)
    } else if disposition == "split" {
      _ = try? store.dispatch(Command("openSplitPane", [.string(window.id), .object(options)]), origin: .native)
    } else if disposition == "window" || disposition == "incognito" {
      if disposition == "incognito" || window.incognito {
        options["incognito"] = true
        let named = (request["profile"] as? String).flatMap { name in state.profileOrder.first { state.engineProfile($0) == name } }
        let original = window.incognito ? window.originalProfileId : window.profileId
        if let own = disposition == "incognito" ? named ?? original : original, state.profiles[own] != nil { options["profileId"] = .string(own) }
        else { options.removeValue(forKey: "profileId") }
        if disposition == "window" || adopt?.hasPrefix("tab:") != true { options.removeValue(forKey: "adoptId") }
      }
      _ = try? store.dispatch(Command("createWindow", [.object(options)]), origin: .native)
    } else {
      options["background"] = .bool(disposition == "background" || profile != window.profileId)
      _ = try? store.dispatch(Command("newTab", [.string(window.id), .object(options)]), origin: .native)
    }
  }
}
