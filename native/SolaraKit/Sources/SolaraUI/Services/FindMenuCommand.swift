import Foundation
import SolaraModel
import SolaraStore

public struct FindMenuPlan: Equatable, Sendable {
  public var commands: [Command]
  public var tabId: String?
  public var windowId: String?
  public var page: PageCommand?
  public var readsSelection: Bool
  public var claimsFocus: Bool
  public var focusWindow: String?

  public init(commands: [Command] = [], tabId: String? = nil, windowId: String? = nil, page: PageCommand? = nil, readsSelection: Bool = false, claimsFocus: Bool = false, focusWindow: String? = nil) {
    self.commands = commands
    self.tabId = tabId
    self.windowId = windowId
    self.page = page
    self.readsSelection = readsSelection
    self.claimsFocus = claimsFocus
    self.focusWindow = focusWindow
  }
}

public enum FindMenuCommand {
  public static let commands: Set<String> = ["findInPage", "findAndReplace", "findNext", "findPrevious", "useSelectionForFind"]
  public static let selectionScript = "post('result', JSON.stringify(String(getSelection() || '').trim().slice(0, 500)))"

  public static func plan(_ command: String, windowId requested: String?, state: BrowserState, closing: Set<String>, focusRequest: Int) -> FindMenuPlan? {
    guard commands.contains(command) else { return nil }
    let route = CommandRoute.resolve(command, windowId: requested, state: state, closing: closing)
    let none = FindMenuPlan(focusWindow: route.focusWindow)
    switch route.kind {
    case .noWindow: return none
    case .main: break
    default: return nil
    }
    guard let windowId = route.windowId, let tabId = route.tabId, let tab = state.tabs[tabId], !tab.url.isEmpty else { return none }
    func setFind(_ patch: JSONObject) -> [Command] { [Command("setFind", [.string(tabId), .object(patch)])] }
    let request = JSONValue.number(Double(focusRequest))
    switch command {
    case "findInPage":
      return FindMenuPlan(commands: setFind(["open": true, "replace": false, "focusRequest": request]), tabId: tabId, windowId: windowId, claimsFocus: true, focusWindow: route.focusWindow)
    case "findAndReplace":
      return FindMenuPlan(commands: setFind(["open": true, "replace": true, "focusRequest": request]), tabId: tabId, windowId: windowId, focusWindow: route.focusWindow)
    case "findNext", "findPrevious":
      let query = state.find[tabId]?.json["query"]?.string ?? ""
      if query.isEmpty { return FindMenuPlan(commands: setFind(["open": true]), tabId: tabId, windowId: windowId, focusWindow: route.focusWindow) }
      return FindMenuPlan(tabId: tabId, windowId: windowId, page: .find(query, command == "findNext", true), focusWindow: route.focusWindow)
    case "useSelectionForFind":
      return FindMenuPlan(tabId: tabId, windowId: windowId, page: .evaluate(selectionScript), readsSelection: true, focusWindow: route.focusWindow)
    default:
      return nil
    }
  }

  public static func nextFocusRequest(after last: Int, nowMilliseconds: Int) -> Int {
    min(-max(nowMilliseconds, 1), last - 1)
  }

  public static func focusAllowed(expired: Bool, pendingGateLive: Bool?) -> Bool {
    guard !expired else { return false }
    return pendingGateLive ?? true
  }

  public static func selectionQuery(_ value: PageValue) -> String? {
    guard case .string(let text) = value, let data = text.data(using: .utf8),
      let query = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { return nil }
    return query
  }

  public static func selectionFind(_ query: String, tabId: String, focusRequest: Int) -> Command? {
    guard !query.isEmpty else { return nil }
    return Command("setFind", [.string(tabId), .object(["open": true, "query": .string(query), "focusRequest": .number(Double(focusRequest))])])
  }
}
