import SolaraModel

public enum WorkspaceCloseIntent: Equatable, Sendable {
  case tabs(windowId: String, tabIds: [String])
  case window(String)
}

public struct WorkspaceMenuPlan: Equatable, Sendable {
  public let commands: [Command]
  public let close: WorkspaceCloseIntent?
  public let focusWindow: String?

  public init(commands: [Command] = [], close: WorkspaceCloseIntent? = nil, focusWindow: String? = nil) {
    self.commands = commands
    self.close = close
    self.focusWindow = focusWindow
  }
}

public enum WorkspaceMenuCommand {
  public static let commands: Set<String> = [
    "newTab", "closeTab", "reopenClosedTab", "restoreClosed", "duplicateTab", "moveTabUp", "moveTabDown",
    "moveTabToWindow", "moveTabToProfile", "selectTab", "selectLastTab", "nextTab", "previousTab",
    "newWindow", "newIncognitoWindow", "closeWindow", "reopenClosedWindow", "mergeAllWindows",
  ]

  public static let unavailableInSmall: Set<String> = [
    "duplicateTab", "moveTabUp", "moveTabDown", "moveTabToWindow", "moveTabToProfile", "selectTab", "selectLastTab", "nextTab", "previousTab", "mergeAllWindows",
  ]

  public static func available(_ command: String, arg: String? = nil, windowId: String?, state: BrowserState) -> Bool? {
    guard commands.contains(command) else { return nil }
    if let windowId, state.windows[windowId]?.isSmall == true, unavailableInSmall.contains(command) { return false }
    if command == "reopenClosedWindow" { return !state.closedWindows.isEmpty }
    if command == "reopenClosedTab" { return !state.closedTabs.isEmpty || !state.closedGroups.isEmpty || !state.closedWindows.isEmpty }
    guard let plan = plan(command, arg: arg, windowId: windowId, state: state) else { return false }
    return !plan.commands.isEmpty || plan.close != nil
  }

  public static func plan(_ command: String, arg: String? = nil, windowId requested: String?, state: BrowserState) -> WorkspaceMenuPlan? {
    guard commands.contains(command) else { return nil }
    if let requested, state.windows[requested]?.isSmall == true, unavailableInSmall.contains(command) {
      let session = Session(state: state, memory: StoreMemory(), env: PlainWebAddressing(), config: StoreConfig(), now: 0)
      guard let target = session.mainWindowFor(state), let redirected = plan(command, arg: arg, windowId: target, state: state) else { return WorkspaceMenuPlan() }
      return WorkspaceMenuPlan(commands: redirected.commands, close: redirected.close, focusWindow: target)
    }
    func run(_ name: String, _ args: [JSONValue] = []) -> WorkspaceMenuPlan { WorkspaceMenuPlan(commands: [Command(name, args)]) }
    if command == "newWindow" || command == "newIncognitoWindow" {
      let source = requested.flatMap { state.windows[$0] != nil ? $0 : nil }
        ?? state.ui.focusOrder.first { state.windows[$0] != nil } ?? state.windowOrder.first { state.windows[$0] != nil }
      let window = source.flatMap { state.windows[$0] }
      let profile = window.flatMap { $0.incognito ? $0.originalProfileId : $0.profileId }.flatMap { state.profiles[$0] != nil ? $0 : nil }
      var options: JSONObject = [:]
      if let profile = command == "newWindow" ? (arg ?? profile) : profile { options["profileId"] = .string(profile) }
      if command == "newIncognitoWindow" { options["incognito"] = true }
      return run("createWindow", [.object(options)])
    }
    if command == "reopenClosedWindow" { return run("reopenClosedWindow") }
    guard let windowId = state.resolveWindowId(requested), let window = state.windows[windowId] else {
      if command == "newTab" { return run("createWindow") }
      if command == "reopenClosedTab" { return run("reopenCommandClosed", [.null]) }
      if command == "restoreClosed", let arg { return run("restoreClosed", [.string(arg), .null]) }
      return WorkspaceMenuPlan()
    }
    let active = state.activeTabId(windowId)
    let tab = active.flatMap { state.tabs[$0] }
    let panel = state.windowUi[windowId]?.json["panel"]
    let targetWindow = JSONValue.string(windowId)
    switch command {
    case "newTab":
      if arg != "create", state.settings.string("newTabOpens") == "commandBar", !window.isSmall {
        if panel?["newTab"]?.truthy == true { return run("closePanel", [targetWindow]) }
        let target: JSONValue
        if let tab, !tab.pinned, tab.url.isEmpty, tab.navigation == nil, !truthy(tab.adoptId), Splits.splitOf(state, tab.id) == nil {
          target = ["kind": "into", "tabId": .string(tab.id)]
        } else { target = ["kind": "list"] }
        return run("openPanel", [targetWindow, "", target])
      }
      return run("newTab", [targetWindow, ["newTabCommand": true]])
    case "closeWindow": return WorkspaceMenuPlan(close: .window(windowId))
    case "closeTab":
      if panel?["open"]?.truthy == true, !window.isSmall || tab?.url.isEmpty == false { return run("closePanel", [targetWindow]) }
      if let peek = state.peeks[windowId] {
        if state.find[peek.tabId]?.json["open"]?.truthy == true {
          return run("setFind", [.string(peek.tabId), ["open": false, "count": .null, "active": 0]])
        }
        return run("closePeek", [targetWindow])
      }
      if window.isSmall { return WorkspaceMenuPlan(close: .window(windowId)) }
      let selected = Set(state.selection[windowId]?.ids ?? [])
      let picked = state.viewTabIds(windowId).filter { selected.contains($0) }
      let ids = picked.count > 1 ? picked : active.map { [$0] } ?? []
      return ids.isEmpty ? WorkspaceMenuPlan() : WorkspaceMenuPlan(close: .tabs(windowId: windowId, tabIds: ids))
    case "reopenClosedTab": return run("reopenCommandClosed", [targetWindow])
    case "restoreClosed": return arg.map { run("restoreClosed", [.string($0), targetWindow]) } ?? WorkspaceMenuPlan()
    case "duplicateTab": return tab.map { run("duplicateTab", [.string($0.id)]) } ?? WorkspaceMenuPlan()
    case "moveTabUp", "moveTabDown":
      return tab.map { run("moveTabBy", [.string($0.id), .number(command == "moveTabDown" ? 1 : -1)]) } ?? WorkspaceMenuPlan()
    case "moveTabToWindow":
      guard let tab, let arg else { return WorkspaceMenuPlan() }
      return run("moveTabsToWindow", [[.string(tab.id)], arg == "new" ? .null : .string(arg)])
    case "moveTabToProfile":
      guard let tab, let arg, !window.incognito else { return WorkspaceMenuPlan() }
      return run("moveTabToProfile", [.string(tab.id), .string(arg)])
    case "selectTab", "selectLastTab":
      guard let number = command == "selectLastTab" ? 9 : arg.flatMap(Int.init), (1...9).contains(number) else { return WorkspaceMenuPlan() }
      return run("activateNumberedTab", [targetWindow, .number(Double(number))])
    case "nextTab", "previousTab": return run("cycle", [targetWindow, .number(command == "nextTab" ? 1 : -1)])
    case "mergeAllWindows": return run("mergeAllWindows", [targetWindow])
    default: return WorkspaceMenuPlan()
    }
  }
}

extension Session {
  public func closeCommandTabs(_ ids: [String]) {
    let before = Set(state.closedTabs.map(\.id))
    closeTabs(ids, lastClosesWindow: true)
    let closed = state.closedTabs.filter { !before.contains($0.id) }.map(\.id)
    memory.commandClosedTogether = closed.count > 1 ? closed : []
  }

  public func reopenCommandClosed(_ windowId: String?) {
    let ids = memory.commandClosedTogether
    memory.commandClosedTogether = []
    let entries = state.closedTabs.filter { ids.contains($0.id) }
    let newest = (state.closedTabs.map(\.closedAt) + state.closedWindows.map(\.closedAt) + state.closedGroups.map(\.closedAt)).max() ?? 0
    let recent = state.closedTabs.suffix(entries.count).allSatisfy { ids.contains($0.id) }
    if entries.count > 1, recent, entries.allSatisfy({ $0.closedAt >= newest }) {
      for entry in entries.sorted(by: { $0.index < $1.index }) { restoreClosed(entry.id, windowId) }
    } else { reopenClosed(windowId) }
  }
}

public struct WorkspaceCloseDecision: Equatable, Sendable {
  public let tabIds: [String]
  public let closesWindow: Bool
  public let warningSetting: String?
}

public enum WorkspaceClosePolicy {
  public static func tabs(_ ids: [String], windowId: String, state: BrowserState, lastTabKeepsWindow: Bool = false) -> WorkspaceCloseDecision {
    let open = ids.filter { state.tabs[$0]?.windowId == windowId }
    guard let window = state.windows[windowId], let last = open.last else {
      return WorkspaceCloseDecision(tabIds: [], closesWindow: false, warningSetting: nil)
    }
    var memory = StoreMemory()
    memory.lastTabKeepsWindow = lastTabKeepsWindow
    let session = Session(state: state, memory: memory, env: PlainWebAddressing(), config: StoreConfig(), now: 0)
    let closes = session.closingTabs(state, open, lastClosesWindow: true).1.contains(windowId)
    let rest = session.removeTabs(state, Array(open.dropLast()), record: false)
    let otherProfiles = rest.closesWindow(last) && (rest.windows[windowId]?.tabIds.contains { $0 != last } ?? false)
    let warning = otherProfiles && closes ? "warnBeforeClosingWindow" : closes && !window.incognito ? "warnBeforeClosingLastTab" : nil
    return WorkspaceCloseDecision(tabIds: open, closesWindow: closes, warningSetting: warning)
  }

  public static func windowWarning(windowId: String, state: BrowserState) -> String? {
    guard let window = state.windows[windowId], !window.isSmall, window.tabIds.count >= 2 else { return nil }
    return "warnBeforeClosingWindow"
  }

  public static func canFinishClose(windowId: String, leaving: Set<String>, state: BrowserState) -> Bool {
    guard let window = state.windows[windowId] else { return false }
    return window.tabIds.allSatisfy { leaving.contains($0) }
  }
}

extension Session {
  public func restoreCommandWindow(_ windowId: String, chromeWindow: String, live: [JSONValue]) -> String? {
    pruneClosingWindows()
    guard !chromeWindow.isEmpty, let undo = memory.closingWindowUndos[windowId], let window = undo.before.windows[windowId] else { return nil }
    var matched: [(id: String, offer: String?)] = []
    for request in live {
      let named = request["storeTabId"]?.string.flatMap { window.tabIds.contains($0) ? $0 : nil }
      let browser = request["browserId"]?.number.flatMap { number -> String? in
        guard let browserId = Int(exactly: number) else { return nil }
        return window.tabIds.first { undo.heldPages[$0]?.page.ready?.browserId == browserId }
      }
      guard let id = named ?? browser, !matched.contains(where: { $0.id == id }) else { continue }
      matched.append((id, request["adoptId"]?.string))
    }
    guard !matched.isEmpty else { return nil }
    let tabs = window.tabIds.compactMap { undo.before.tabs[$0] }
    let groups = undo.before.groups.values.filter { $0.windowId == windowId }
    let splits = undo.before.splits.values.filter { $0.windowId == windowId }
    guard let restored = restoreClosingWindow(window, tabs, groups, splits, chromeWindow: chromeWindow, liveTabIds: matched.map(\.id)) else { return nil }
    for match in matched where undo.heldPages[match.id] == nil {
      guard let offer = match.offer, !offer.isEmpty, var tab = state.tabs[match.id] else { continue }
      tab.adoptId = offer
      tab.navigation = nil
      update { $0.tabs[match.id] = tab }
    }
    return restored
  }
}
