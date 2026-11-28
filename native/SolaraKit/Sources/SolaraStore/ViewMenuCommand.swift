import Foundation
import SolaraModel

public struct ViewMenuPlan: Equatable, Sendable {
  public let commands: [Command]
  public let appliesAppearance: Bool
  public let focusWindow: String?

  public init(commands: [Command] = [], appliesAppearance: Bool = false, focusWindow: String? = nil) {
    self.commands = commands
    self.appliesAppearance = appliesAppearance
    self.focusWindow = focusWindow
  }
}

public struct ViewMenuOutcome: Equatable, Sendable {
  public let focusWindow: String?
  public let appearance: String?
}

public struct BrowserMenuRow: Equatable, Sendable {
  public var enabled: Bool?
  public var checked: Bool?
  public var title: String?

  public init(enabled: Bool? = nil, checked: Bool? = nil, title: String? = nil) {
    self.enabled = enabled
    self.checked = checked
    self.title = title
  }
}

public enum ViewMenuCommand {
  public static let commands: Set<String> = [
    "toggleOpenLinksInLittleSolara", "setAppearance", "toggleFullUrl", "toggleJavaScriptFromAppleEvents", "toggleAddressBar",
    "setSidebarPosition", "toggleSidebarIconsOnly", "setBookmarksBar", "toggleBookmarksBar", "toggleTabLayout", "toggleSidebar",
    "downloads", "openSplitPane", "focusNextPane", "focusPreviousPane",
  ]

  public static func row(_ command: String, arg: String?, windowId: String?, state: BrowserState, product: String = "Solara") -> BrowserMenuRow? {
    let window = windowId.flatMap { state.windows[$0] }
    let settings = state.settings
    let sidebar = (window?.tabLayout ?? settings.string("tabLayout")) == "sidebar"
    let fullWindow = window?.isSmall == false
    switch command {
    case "setAppearance": return BrowserMenuRow(checked: arg == settings.string("appearance"))
    case "setBookmarksBar": return BrowserMenuRow(checked: arg == settings.string("bookmarksBar"))
    case "setSidebarPosition":
      return BrowserMenuRow(enabled: fullWindow && settings.fileSource("sidebarPosition") == nil,
        checked: arg == (window?.effectiveSidebarPosition(settings) ?? settings.string("sidebarPosition") ?? "left"))
    case "toggleOpenLinksInLittleSolara":
      return BrowserMenuRow(title: settings.bool("openLinksInLittleSolara") ? nil : "Open Links from Other Apps in Little \(product)")
    case "toggleFullUrl": return BrowserMenuRow(checked: settings.bool("showFullUrl"))
    case "toggleJavaScriptFromAppleEvents": return BrowserMenuRow(checked: settings.bool("allowJavaScriptFromAppleEvents"))
    case "toggleAddressBar":
      return BrowserMenuRow(enabled: window == nil || (fullWindow && sidebar), checked: settings.string("addressBar") == "sidebar")
    case "toggleSidebarIconsOnly":
      return BrowserMenuRow(enabled: window == nil || (fullWindow && sidebar),
        checked: window?.effectiveSidebarIconsOnly(settings) ?? settings.bool("sidebarIconsOnly"))
    case "toggleTabLayout": return BrowserMenuRow(enabled: fullWindow, checked: sidebar)
    case "toggleSidebar": return BrowserMenuRow(enabled: fullWindow, checked: window?.sidebarOpen == false)
    case "focusNextPane", "focusPreviousPane":
      return BrowserMenuRow(enabled: fullWindow && Splits.splitOf(state, windowId.flatMap { state.activeTabId($0) }) != nil)
    default: return nil
    }
  }

  public static func plan(_ command: String, arg: String?, windowId requested: String?, state: BrowserState, closing: Set<String>) -> ViewMenuPlan? {
    guard commands.contains(command) else { return nil }
    guard CommandRoute.acceptsWorkspaceInvoker(requested, state: state, closing: closing) else { return ViewMenuPlan() }
    let route = CommandRoute.resolve(command, windowId: requested, state: state, closing: closing)
    func settings(_ patch: JSONObject, appearance: Bool = false) -> ViewMenuPlan {
      ViewMenuPlan(commands: [Command("updateSettings", [.object(patch)])], appliesAppearance: appearance)
    }
    func toggled(_ key: String) -> ViewMenuPlan { settings([key: .bool(!state.settings.bool(key))]) }
    switch route.kind {
    case .window:
      switch command {
      case "toggleOpenLinksInLittleSolara": return toggled("openLinksInLittleSolara")
      case "toggleFullUrl": return toggled("showFullUrl")
      case "toggleJavaScriptFromAppleEvents": return toggled("allowJavaScriptFromAppleEvents")
      case "setAppearance":
        guard let arg, ["auto", "light", "dark"].contains(arg) else { return ViewMenuPlan() }
        return settings(["appearance": .string(arg)], appearance: true)
      case "setSidebarPosition", "toggleSidebarIconsOnly":
        guard let target = state.resolveWindowId(route.windowId, excluding: closing),
          let window = state.windows[target], !window.isSmall else { return ViewMenuPlan() }
        let id = JSONValue.string(target)
        if command == "setSidebarPosition" {
          guard let arg, ["left", "right"].contains(arg), state.settings.fileSource("sidebarPosition") == nil else { return ViewMenuPlan() }
          return ViewMenuPlan(commands: [Command("setSidebarPosition", [id, .string(arg)])])
        }
        guard (window.tabLayout ?? state.settings.string("tabLayout")) != "top" else { return ViewMenuPlan() }
        return ViewMenuPlan(commands: [Command("setWindowSidebar", [id, ["sidebarIconsOnly": .bool(!window.effectiveSidebarIconsOnly(state.settings))]])])
      case "toggleAddressBar":
        return settings(["addressBar": .string(state.settings.string("addressBar") == "sidebar" ? "toolbar" : "sidebar")])
      case "setBookmarksBar":
        guard let arg, ["always", "newTab", "never"].contains(arg) else { return ViewMenuPlan() }
        return settings(["bookmarksBar": .string(arg)])
      case "toggleBookmarksBar":
        let mode = state.settings.string("bookmarksBar")
        let active = state.resolveWindowId(route.windowId, excluding: closing).flatMap { state.activeTabId($0) }
        let onPage = active.flatMap { state.tabs[$0] }.map { !$0.url.isEmpty } ?? false
        let shown = mode == "always" || (mode == "newTab" && !onPage)
        return settings(["bookmarksBar": .string(shown ? "never" : "always")])
      default: return nil
      }
    case .main:
      guard let windowId = route.windowId else { return ViewMenuPlan() }
      let target = JSONValue.string(windowId)
      func run(_ name: String, _ args: [JSONValue]) -> ViewMenuPlan {
        ViewMenuPlan(commands: [Command(name, args)], focusWindow: route.focusWindow)
      }
      switch command {
      case "toggleTabLayout": return run("toggleTabLayout", [target])
      case "toggleSidebar": return run("toggleSidebar", [target])
      case "downloads": return run("setDownloadsOpen", [target, .bool(!(state.windowUi[windowId]?.downloadsOpen ?? false))])
      case "openSplitPane": return run("openSplitPane", [target])
      case "focusNextPane": return run("focusPane", [target, .number(1)])
      case "focusPreviousPane": return run("focusPane", [target, .number(-1)])
      default: return nil
      }
    case .noWindow:
      return ViewMenuPlan(focusWindow: route.focusWindow)
    default:
      return nil
    }
  }

  public static func perform(_ command: String, arg: String?, windowId: String?, store: Store) -> ViewMenuOutcome? {
    guard let plan = plan(command, arg: arg, windowId: windowId, state: store.state, closing: store.memory.closingWindows) else { return nil }
    if let target = plan.focusWindow {
      do { try store.dispatch(Command("setFocusedWindow", [.string(target)]), origin: .native) } catch { return nil }
    }
    if !plan.commands.isEmpty {
      do { try store.dispatch(plan.commands, origin: .native) } catch { NSLog("[commands] %@ failed: %@", command, String(describing: error)) }
    }
    return ViewMenuOutcome(focusWindow: plan.focusWindow, appearance: plan.appliesAppearance ? store.state.settings.string("appearance") ?? "auto" : nil)
  }
}
