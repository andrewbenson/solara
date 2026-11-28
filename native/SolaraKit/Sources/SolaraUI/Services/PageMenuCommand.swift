import Foundation
import SolaraModel
import SolaraStore

public struct BrowserMenuContext {
  private static let externalPageCommands: Set<String> = [
    "print", "findInPage", "findNext", "findPrevious", "reload",
    "forceReload", "useSelectionForFind", "findAndReplace", "jumpToSelection", "zoomReset",
    "zoomIn", "zoomOut", "devTools", "toggleDeveloperMode", "toggleDevTools",
    "javaScriptConsole", "inspectElements", "viewSource", "toggleMute", "share",
    "savePage", "emailPageLocation", "printWithSystemDialog", "stop", "caretBrowsing",
  ]
  private static let anyPageCommands: Set<String> = ["copyUrl", "copyUrlAsMarkdown", "bookmarkPage", "addBookmarkToFolder"]
  private static let windowCommands: Set<String> = [
    "focusCommandBar", "closeTab", "closeAllTabs", "setSidebarPosition", "toggleTabLayout",
    "toggleSidebar", "openSplitPane", "back", "forward", "nextTab",
    "previousTab", "selectTab", "selectLastTab", "togglePin", "togglePinnedRow",
    "duplicateTab", "moveTabToProfile", "moveTabToWindow", "openBookmark", "downloads",
    "mergeAllWindows", "switchProfile", "nextProfile", "previousProfile", "newTabInGroup",
    "newGroupWithTabs", "cleanUpTabs", "searchTabs", "renameTab", "changeTabIcon",
    "returnToPinnedUrl", "tabSwitcher", "moveTabDown", "moveTabUp", "closeTabGroup",
    "openProfileMenu",
  ]
  private static let unavailableInLittleSolara: Set<String> = [
    "closeAllTabs", "setSidebarPosition", "toggleTabLayout", "toggleSidebar", "openSplitPane",
    "focusNextPane", "focusPreviousPane", "toggleAddressBar", "toggleSidebarIconsOnly", "nextTab",
    "previousTab", "selectTab", "selectLastTab", "togglePin", "togglePinnedRow",
    "duplicateTab", "moveTabToProfile", "moveTabToWindow", "mergeAllWindows", "bookmarkAllTabs",
    "newTabInGroup", "newGroupWithTabs", "cleanUpTabs", "searchTabs", "renameTab",
    "changeTabIcon", "returnToPinnedUrl", "tabSwitcher", "moveTabDown", "moveTabUp",
    "closeTabGroup",
  ]

  private let state: BrowserState
  private let window: BrowserWindow?
  private let page: Tab?
  private let active: Tab?
  private let opensPeek: Bool
  private let internalPage: Bool
  private let loading: Bool
  private let back: Bool
  private let forward: Bool
  private let engine: String
  private let bookmarked: Bool
  private let product: String

  public init(state: BrowserState, windowId: String?, pageId: String?, opensPeek: Bool = false, internalPage: Bool = false,
    loading: Bool = false, back: Bool = false, forward: Bool = false, engine: String = "chromium",
    bookmarked: Bool = false, product: String = "Solara") {
    self.state = state
    window = windowId.flatMap { state.windows[$0] }
    active = windowId.flatMap { state.activeTabId($0) }.flatMap { state.tabs[$0] }
    page = pageId.flatMap { state.tabs[$0] }
    self.opensPeek = opensPeek
    self.internalPage = internalPage
    self.loading = loading
    self.back = back
    self.forward = forward
    self.engine = engine
    self.bookmarked = bookmarked
    self.product = product
  }

  private var selection: [String] {
    guard let window, let picked = state.selection[window.id]?.ids else { return [] }
    let ids = Set(picked)
    return state.viewTabIds(window.id).filter { ids.contains($0) }
  }

  public func row(_ command: String, arg: String? = nil) -> BrowserMenuRow? {
    if let row = ViewMenuCommand.row(command, arg: arg, windowId: window?.id, state: state, product: product) { return row }
    var row = BrowserMenuRow()
    let hasPage = window != nil && page?.url.isEmpty == false
    if Self.anyPageCommands.contains(command) || Self.externalPageCommands.contains(command) {
      row.enabled = hasPage && (!internalPage || Self.anyPageCommands.contains(command))
    } else if Self.windowCommands.contains(command), window == nil {
      row.enabled = false
    }
    if window?.isSmall == true, Self.unavailableInLittleSolara.contains(command) { row.enabled = false }
    switch command {
    case "back": row.enabled = window != nil && back
    case "forward": row.enabled = window != nil && forward
    case "stop": row.enabled = row.enabled == true && loading
    case "toggleDeveloperMode":
      if let page {
        let context: JSONValue = ["url": .string(page.url), "profileId": .string(page.profileId),
          "privatePage": .bool(Ids.isIncognitoProfile(page.profileId)), "developerMode": state.settings["developerMode"] ?? [:]]
        row.enabled = row.enabled == true && SiteControlsLogic.canToggleDeveloper(context: context)
        if SiteControlsLogic.developerEnabled(context: context) { row.title = "Turn off Developer Mode for this site" }
      }
    case "togglePageEngine":
      row.enabled = hasPage && page.map { EngineCommand.plan(tab: $0, currentEngine: engine, destination: engine == "webkit" ? "chromium" : "webkit") != nil } == true
      if engine == "webkit" { row.title = "Open Page in Chromium" }
    case "toggleMute":
      if page?.muted == true { row.title = "Unmute Site" }
    case "bookmarkPage":
      if bookmarked { row.title = "Edit Bookmark…" }
    case "togglePin":
      if arg == "tile" {
        if active?.isPinnedRow == true { row.title = "Move to Top Apps" }
        else { row.enabled = false }
      } else if active?.pinned == true {
        row.title = active?.isPinnedRow == true ? "Unpin" : "Unpin from Top Apps"
      }
    case "togglePinnedRow":
      if window != nil {
        let profile = active.flatMap { state.profiles[$0.profileId]?.name } ?? "Profile"
        row.title = active?.pinned == true ? "Move out of Pinned" : "Move to Pinned in \(profile)"
      }
    case "newGroupWithTabs":
      if window != nil {
        let picked = selection
        let ids = picked.isEmpty ? active.map { [$0.id] } ?? [] : picked
        let count = ids.filter { state.tabs[$0]?.pinSection != .tile }.count
        if count == 0 { row.enabled = false }
        if count > 1 { row.title = "New Group with \(count) Tabs" }
      }
    case "closeTab":
      if opensPeek { row.title = "Close Peek" }
      else {
        let count = selection.count
        if count > 1 { row.title = "Close \(count) Tabs" }
      }
    case "openFile":
      if window?.isSmall == true { row.title = "Open in \(product)" }
      else if opensPeek { row.title = "Open Peek as Tab" }
    case "moveTabToProfile":
      if window?.incognito == true || (arg != nil && arg == active?.profileId) { row.enabled = false }
    case "moveTabToWindow", "switchProfile", "nextProfile", "previousProfile":
      if window?.incognito == true { row.enabled = false }
    case "mergeAllWindows":
      if let window, !window.incognito, !window.isSmall, state.windows.values.lazy.filter({ !$0.incognito && !$0.isSmall }).prefix(2).count < 2 {
        row.enabled = false
      }
    default: break
    }
    return row == BrowserMenuRow() ? nil : row
  }
}

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
  private static let jumpSelectionScript = #"""
    (() => {
      const focused = () => {
        let el = document.activeElement;
        for (;;) {
          if (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
          else if (el && el.tagName === "IFRAME") {
            try { el = el.contentDocument.activeElement; } catch (e) { return el; }
          } else return el;
        }
      };
      const isTextField = (el) => !!el && !el.readOnly && !el.disabled &&
        (el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && /^(text|search|url|email|tel|)$/i.test(el.getAttribute("type") || "")));
      const el = focused();
      if (isTextField(el)) {
        const [start, end] = [el.selectionStart, el.selectionEnd];
        el.scrollIntoView({ block: "center", inline: "nearest" });
        el.setSelectionRange(end, end);
        el.setSelectionRange(start, end);
        if (el.tagName === "TEXTAREA") {
          const style = getComputedStyle(el);
          const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.2;
          const line = el.value.slice(0, start).split("\n").length - 1;
          el.scrollTop = Math.max(0, line * lineHeight - el.clientHeight / 2);
        }
        return post("result", "true");
      }
      const win = el ? el.ownerDocument.defaultView : window;
      const sel = win.getSelection();
      if (!sel || !sel.rangeCount || (sel.isCollapsed && !(el && el.isContentEditable))) return post("result", "false");
      const range = sel.getRangeAt(0);
      const node = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
      node.scrollIntoView({ block: "center", inline: "nearest" });
      const r = range.getBoundingClientRect();
      if (r.height && (r.top < 0 || r.bottom > win.innerHeight)) win.scrollBy(0, r.top + r.height / 2 - win.innerHeight / 2);
      post("result", "true");
    })()
    """#

  public static let commands: Set<String> = [
    "reload", "forceReload", "stop", "print", "printWithSystemDialog", "savePage", "caretBrowsing", "zoomIn", "zoomOut", "zoomReset",
    "devTools", "toggleDevTools", "inspectElements", "javaScriptConsole", "viewSource", "toggleMute", "emailPageLocation", "jumpToSelection",
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
      return on(command == "reload" ? .reload : .forceReload)
    case "jumpToSelection":
      guard page != nil else { return none }
      return on(.evaluate(jumpSelectionScript))
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
