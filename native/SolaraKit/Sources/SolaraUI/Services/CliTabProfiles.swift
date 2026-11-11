import SolaraModel

public func cliTabProfileNames(_ state: BrowserState, sessionIds: [String: Int]) -> [String: String] {
  var names: [String: String] = [:]
  for (key, id) in sessionIds where id >= 0 {
    guard let tab = state.tabs[key], let window = state.windows[tab.windowId], !window.incognito,
      let profile = state.profiles[tab.profileId]
    else { continue }
    names[String(id)] = profile.name
  }
  return names
}
