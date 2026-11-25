import SolaraModel
import SolaraStore

public struct BrowserServicePlan: Equatable, Sendable {
  public let command: String
  public let route: CommandRoute
  public let profileId: String
  public let settingsProfile: String
  public let tabId: String?
  public let url: String?
  public let navigation: Navigation?
  public let passwords: Bool
}

public struct BrowserServiceReceipt: Sendable {
  public let plan: BrowserServicePlan
  public let ownership: Int
  public let identity: PageIdentity?

  public init(plan: BrowserServicePlan, ownership: Int, identity: PageIdentity?) {
    self.plan = plan
    self.ownership = ownership
    self.identity = identity
  }

  public func accepts(ownership: Int, identity: PageIdentity?, state: BrowserState, closing: Set<String>) -> Bool {
    self.ownership == ownership && self.identity == identity && BrowserServiceCommand.current(plan, state: state, closing: closing)
  }
}

public enum BrowserServiceCommand {
  public static let commands: Set<String> = ["openFile", "autofill"]

  public static func plan(_ command: String, arg: String?, windowId: String?, state: BrowserState, closing: Set<String>) -> BrowserServicePlan? {
    guard commands.contains(command) else { return nil }
    if let windowId, !CommandRoute.utilityWindowIds.contains(windowId), state.windows[windowId] == nil { return nil }
    let route = CommandRoute.resolve(command, windowId: windowId, state: state, closing: closing)
    let target = route.windowId ?? state.resolveWindowId(nil)
    guard target.map({ !closing.contains($0) }) ?? true else { return nil }
    let window = target.flatMap { state.windows[$0] }
    let tabId = route.tabId ?? target.flatMap { state.activeTabId($0) }
    let tab = tabId.flatMap { state.tabs[$0] }
    guard command == "openFile" || window != nil else { return nil }
    guard tab == nil || tab?.windowId == target && tab?.profileId == window?.profileId else { return nil }
    let resolved = CommandRoute(route.kind, windowId: target, focusWindow: route.focusWindow, tabId: tabId)
    return BrowserServicePlan(command: command, route: resolved, profileId: window?.profileId ?? state.settings.defaultProfileId,
      settingsProfile: state.bookmarkProfileId(window), tabId: tabId, url: tab?.url, navigation: tab?.navigation, passwords: arg == "passwords")
  }

  public static func current(_ plan: BrowserServicePlan, state: BrowserState, closing: Set<String>) -> Bool {
    Self.plan(plan.command, arg: plan.passwords ? "passwords" : nil, windowId: plan.route.windowId, state: state, closing: closing) == plan
  }

  public static func settingsPane(_ plan: BrowserServicePlan, shown: Bool) -> String? {
    shown ? nil : (plan.passwords ? "passwords" : "autofill")
  }

  public static func open(_ urls: [String], plan: BrowserServicePlan, store: Store) throws {
    guard plan.command == "openFile", current(plan, state: store.state, closing: store.memory.closingWindows), !urls.isEmpty else { return }
    var target = plan.route.windowId
    for url in urls {
      if let id = target {
        try store.dispatch(Command("newTab", [.string(id), ["url": .string(url), "profileId": .string(plan.profileId)]]), origin: .native)
      } else {
        target = try store.dispatch(Command("createWindow", [["url": .string(url), "profileId": .string(plan.profileId)]]), origin: .native).result?.string
        guard target != nil else { return }
      }
    }
  }

  public static func promote(_ plan: BrowserServicePlan, store: Store) throws -> String? {
    guard current(plan, state: store.state, closing: store.memory.closingWindows), let id = plan.route.windowId else { return nil }
    if plan.route.kind == .peekPromote {
      try store.dispatch(Command("peekToTab", [.string(id)]), origin: .native)
      return id
    }
    guard plan.route.kind == .littleSolara else { return nil }
    let s = store.state
    var seen = Set<String>()
    let order = (s.ui.focusOrder + s.windowOrder).filter { seen.insert($0).inserted }
    let main = order.filter { s.windows[$0].map { !$0.isSmall && !$0.incognito && !store.memory.closingWindows.contains($0.id) } ?? false }
    let target = main.first { s.windows[$0]?.profileId == plan.profileId } ?? main.first
    if plan.url?.isEmpty != false {
      try store.dispatch(Command("closeWindow", [.string(id)]), origin: .native)
      if let target { return target }
      return try store.dispatch(Command("createWindow", [["profileId": .string(plan.profileId)]]), origin: .native).result?.string
    }
    guard let tabId = plan.tabId else { return nil }
    return try store.dispatch(Command("moveTabsToWindow", [JSONValue([tabId]), target.map(JSONValue.string) ?? .null]), origin: .native).result?.string
  }
}
