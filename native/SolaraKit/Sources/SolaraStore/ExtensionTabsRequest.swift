import SolaraModel

public struct ExtensionTabsRequest {
  private var offers: Set<String> = []
  private var closed: Set<String> = []
  private var moves: [String: String] = [:]

  public init() {}

  @discardableResult
  public mutating func apply(_ request: JSONValue, to store: Store) throws -> String? {
    try store.sequence {
      let state = store.state
      let chrome = nonempty(request["chromeWindow"])
      let appWindow = nonempty(request["appWindow"])
      let made = chrome.flatMap { token in state.windows.values.first { $0.chromeWindow == token } }
      switch request["action"]?.string {
      case "windowCloseStarted":
        if let appWindow { try store.dispatch(Command("setChromeWindowClosePending", [.string(appWindow), true]), origin: .native) }
      case "windowCloseCommitted", "closeWindow":
        let id = appWindow ?? made?.id
        let token = chrome ?? id.flatMap { state.windows[$0]?.chromeWindow }
        if let id { try store.dispatch(Command("commitChromeWindowClose", [.string(id)]), origin: .native) }
        if let token {
          closed.insert(token)
          moves = moves.filter { $0.value != token }
        }
      case "closeCancelled":
        guard let chrome, !closed.contains(chrome), let live = request["tabs"] else { return nil }
        if let made { return made.id }
        let result = try store.dispatch(Command("restoreCommandWindow", [.string(appWindow ?? ""), .string(chrome), live]), origin: .native)
        if result.result?.string == nil, let appWindow {
          try store.dispatch(Command("setChromeWindowClosePending", [.string(appWindow), false]), origin: .native)
        }
        return result.result?.string
      case "open":
        guard chrome.map({ !closed.contains($0) }) != false else { return nil }
        if let chrome, let id = nonempty(request["tabKey"]) {
          guard let tab = state.tabs[id], !Ids.isIncognitoProfile(tab.profileId),
            made?.incognito != true, tab.windowId != made?.id, moves[id] != chrome else { return nil }
          if let made {
            try store.dispatch(Command("moveTabsToWindow", [[.string(id)], .string(made.id)]), origin: .native)
          } else {
            try store.dispatch(Command("createWindow", [["profileId": .string(tab.profileId), "tabIds": [.string(id)],
              "chromeWindow": .string(chrome), "background": .bool(request["focused"] == false)]]), origin: .native)
          }
          moves[id] = chrome
        } else {
          try open(request, chrome: chrome, made: made, state: state, store: store)
        }
      default: break
      }
      return nil
    }
  }

  private mutating func open(_ request: JSONValue, chrome: String?, made: BrowserWindow?, state: BrowserState, store: Store) throws {
    let offer = nonempty(request["adoptId"])
    guard let url = request["url"]?.string, !url.isEmpty || offer != nil,
      offer.map({ !offers.contains($0) }) != false else { return }
    let profile = request["profile"]?.string ?? ""
    let privateTab = request["incognito"]?.bool ?? profile.hasPrefix("incognito")
    let requested = nonempty(request["window"]).flatMap { state.windows[$0] }
    let focused = (state.ui.focusOrder + state.windowOrder).compactMap { state.windows[$0] }
    let eligible: (BrowserWindow) -> Bool = { window in
      window.incognito == privateTab && state.engineProfile(window.profileId) == profile
    }
    var options: JSONObject = ["url": .string(url), "background": .bool(request["active"] == false)]
    let target: BrowserWindow?
    if let offer {
      options["adoptId"] = .string(offer)
      let matching = requested.flatMap { eligible($0) ? $0 : nil } ?? focused.first(where: eligible)
      let profileId = matching?.profileId ?? state.profileOrder.first { state.engineProfile($0) == profile }
      if privateTab && matching == nil { return }
      if let made {
        guard eligible(made) else { return }
        target = made
      } else { target = chrome == nil ? matching : nil }
      options["profileId"] = (target?.profileId ?? profileId).map(JSONValue.string)
      if privateTab {
        options["incognito"] = true
        if target == nil && chrome == nil { return }
      }
    } else {
      target = privateTab ? (requested.flatMap { eligible($0) ? $0 : nil } ?? focused.first(where: eligible))
        : (requested ?? focused.first(where: eligible) ?? focused.first)
      if privateTab && target == nil { return }
    }
    let command: Command
    if let target {
      command = Command("newTab", [.string(target.id), .object(options)])
    } else {
      options["chromeWindow"] = chrome.map(JSONValue.string)
      options["background"] = .bool(chrome != nil && request["focused"] == false)
      command = Command("createWindow", [.object(options)])
    }
    let result = try store.dispatch(command, origin: .native)
    if let offer, result.result?.string != nil { offers.insert(offer) }
  }

  private func nonempty(_ value: JSONValue?) -> String? {
    value?.string.flatMap { $0.isEmpty ? nil : $0 }
  }
}
