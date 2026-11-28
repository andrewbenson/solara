import AppKit
import SolaraModel
import SolaraStore

public struct CommandBarFocusPlan: Equatable, Sendable {
  public enum Destination: Equatable, Sendable { case developer, panel, newTab, sidebar, hero }
  public let windowId: String
  public let tabId: String
  public let profileId: String
  public let text: String
  public let destination: Destination
  public let commands: [Command]

  public func isCurrent(state: BrowserState, closing: Set<String>, gateLive: Bool) -> Bool {
    guard gateLive, let next = CommandBarFocusCommand.plan(windowId: windowId, state: state, closing: closing) else { return false }
    return next.windowId == windowId && next.tabId == tabId && next.profileId == profileId && next.text == text && next.destination == destination
  }

  @MainActor
  public func allowsPageHandoff(from source: ObjectIdentifier?, to responder: NSResponder?, page: NSView?, in window: NSWindow) -> Bool {
    guard destination == .developer, source == ObjectIdentifier(window), let page, page.window === window,
      let view = responder as? NSView else { return false }
    return view.isDescendant(of: page)
  }
}

public struct CommandBarFocusReceipt: Sendable {
  public let plan: CommandBarFocusPlan
  public let request: Int
  public let ownership: Int
  public let deadline: Double

  public init(plan: CommandBarFocusPlan, request: Int, ownership: Int, deadline: Double) {
    self.plan = plan
    self.request = request
    self.ownership = ownership
    self.deadline = deadline
  }

  public func allows(request: Int, ownership: Int, now: Double, gateLive: Bool, state: BrowserState, closing: Set<String>) -> Bool {
    self.request == request && self.ownership == ownership && now < deadline && plan.isCurrent(state: state, closing: closing, gateLive: gateLive)
  }
}

public enum CommandBarFocusCommand {
  public static func plan(windowId: String?, state s: BrowserState, closing: Set<String>) -> CommandBarFocusPlan? {
    let route = CommandRoute.resolve("focusCommandBar", windowId: windowId, state: s, closing: closing)
    guard let id = route.windowId, !closing.contains(id), let w = s.windows[id],
      let tabId = s.activeTabId(id), let tab = s.tabs[tabId], tab.windowId == id, tab.profileId == w.profileId else { return nil }
    let destination: CommandBarFocusPlan.Destination
    let commands: [Command]
    let inSplit = s.splits.values.contains { $0.tabIds.contains(tabId) }
    let empty = !tab.pinned && tab.url.isEmpty && (tab.navigation == nil || tab.navigation?.url == "about:blank" && tab.navigation?.userInitiated != true)
      && (tab.adoptId ?? "").isEmpty && !inSplit
    if w.isSmall { destination = .panel }
    else if !tab.url.isEmpty && OmniboxCommandSources.isDeveloperURL(tab.url, settings: s.settings, profileId: tab.profileId) { destination = .developer }
    else if !tab.url.isEmpty || inSplit { destination = .panel }
    else if empty && s.settings.string("newTabOpens") == "commandBar" { destination = .newTab }
    else if s.settings.string("addressBar") == "sidebar" && (w.tabLayout ?? s.settings.string("tabLayout")) != "top" && (!w.sidebarOpen || !SidebarRail.contains(width: SidebarRail.effectiveWidth(w, s.settings))) && s.settings.string("commandBarPlacement") != "centred" { destination = .sidebar }
    else { destination = .hero }
    switch destination {
    case .developer: commands = []
    case .hero: commands = s.windowUi[id]?.panelOpen == true ? [Command("closePanel", [.string(id)])] : []
    case .newTab: commands = [Command("openPanel", [.string(id), "", .object(["kind": "into", "tabId": .string(tabId)])])]
    case .panel, .sidebar: commands = [Command("openPanel", [.string(id), .string(tab.url)])]
    }
    return CommandBarFocusPlan(windowId: id, tabId: tabId, profileId: tab.profileId, text: tab.url, destination: destination, commands: commands)
  }
}
