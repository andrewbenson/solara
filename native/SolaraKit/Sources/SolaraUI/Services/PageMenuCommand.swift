import Foundation
import SolaraModel
import SolaraStore

public struct PageMenuPlan: Equatable, Sendable {
  public var commands: [Command]
  public var tabId: String?
  public var page: PageCommand?
  public var external: String?
  public var needsLivePage: Bool
  public var focusWindow: String?

  public init(commands: [Command] = [], tabId: String? = nil, page: PageCommand? = nil, external: String? = nil, needsLivePage: Bool = false, focusWindow: String? = nil) {
    self.commands = commands
    self.tabId = tabId
    self.page = page
    self.external = external
    self.needsLivePage = needsLivePage
    self.focusWindow = focusWindow
  }
}

public enum PageMenuCommand {
  public static let commands: Set<String> = [
    "reload", "forceReload", "stop", "print", "printWithSystemDialog", "savePage", "caretBrowsing", "zoomIn", "zoomOut", "zoomReset",
    "devTools", "toggleDevTools", "inspectElements", "javaScriptConsole", "viewSource", "toggleMute", "emailPageLocation",
  ]

  public static func plan(_ command: String, arg: String?, windowId requested: String?, state: BrowserState, closing: Set<String>) -> PageMenuPlan? {
    guard commands.contains(command) else { return nil }
    let route = CommandRoute.resolve(command, windowId: requested, state: state, closing: closing)
    let none = PageMenuPlan(focusWindow: route.focusWindow)
    switch route.kind {
    case .noWindow: return none
    case .main: break
    default: return nil
    }
    guard let windowId = route.windowId, let tabId = route.tabId, let tab = state.tabs[tabId] else { return none }
    let page = tab.url.isEmpty ? nil : tab
    func on(_ action: PageCommand) -> PageMenuPlan { PageMenuPlan(tabId: tabId, page: action, focusWindow: route.focusWindow) }
    switch command {
    case "reload", "forceReload":
      if let holder = tab.pageIn, !holder.isEmpty { return nil }
      return on(command == "reload" ? .reload : .forceReload)
    case "stop": return on(.stopLoading)
    case "print": return on(.print)
    case "printWithSystemDialog": return on(.runPageCommand("systemPrint"))
    case "savePage": return on(.runPageCommand("savePage"))
    case "caretBrowsing": return on(.runPageCommand("caretBrowsing"))
    case "devTools": return on(.showDevTools(nil))
    case "toggleDevTools": return on(.showDevTools("toggle"))
    case "inspectElements": return on(.showDevTools("inspect"))
    case "javaScriptConsole": return on(.showDevTools("console"))
    case "zoomIn", "zoomOut", "zoomReset":
      guard page != nil else { return none }
      return on(.zoomStep(command == "zoomIn" ? 1 : command == "zoomOut" ? -1 : 0))
    case "toggleMute":
      guard page != nil else { return none }
      var plan = on(.setMuted(!tab.muted))
      plan.commands = [Command("setSiteMuted", [.string(tabId), .bool(!tab.muted)])]
      return plan
    case "viewSource":
      guard let page, page.url.range(of: "^(https?|file):", options: .regularExpression) != nil else { return none }
      let options: JSONObject = ["url": .string("view-source:\(page.url)"), "openerId": .string(page.id), "profileId": .string(page.profileId)]
      return PageMenuPlan(commands: [Command("newTab", [.string(windowId), .object(options)])], tabId: tabId, needsLivePage: true, focusWindow: route.focusWindow)
    case "emailPageLocation":
      guard let page, page.url.range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil else { return none }
      let subject = [page.customTitle ?? "", page.title].first { !$0.isEmpty } ?? page.url
      let mail = "mailto:?subject=\(AppDiagnostics.encodeURIComponent(subject))&body=\(AppDiagnostics.encodeURIComponent(page.url))"
      return PageMenuPlan(external: mail, focusWindow: route.focusWindow)
    default:
      return nil
    }
  }
}
