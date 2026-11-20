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

public enum ViewMenuCommand {
  public static let commands: Set<String> = [
    "toggleOpenLinksInLittleSolara", "setAppearance", "toggleFullUrl", "toggleJavaScriptFromAppleEvents", "toggleAddressBar",
    "setBookmarksBar", "toggleBookmarksBar", "toggleTabLayout", "toggleSidebar", "downloads", "focusNextPane", "focusPreviousPane",
  ]

  public static func plan(_ command: String, arg: String?, windowId requested: String?, state: BrowserState, closing: Set<String>) -> ViewMenuPlan? {
    guard commands.contains(command) else { return nil }
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
      case "toggleAddressBar":
        return settings(["addressBar": .string(state.settings.string("addressBar") == "sidebar" ? "toolbar" : "sidebar")])
      case "setBookmarksBar":
        guard let arg, ["always", "newTab", "never"].contains(arg) else { return ViewMenuPlan() }
        return settings(["bookmarksBar": .string(arg)])
      case "toggleBookmarksBar":
        let mode = state.settings.string("bookmarksBar")
        let active = state.resolveWindowId(route.windowId).flatMap { state.activeTabId($0) }
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
