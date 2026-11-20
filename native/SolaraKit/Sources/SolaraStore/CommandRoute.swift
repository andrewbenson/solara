import SolaraModel

public struct CommandRoute: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case utilityClose, settingsSearch, littleSolara, peekPromote, peekCloseFind, peekDismiss, window, invoker, noWindow, main
  }

  public let kind: Kind
  public let windowId: String?
  public let focusWindow: String?
  public let tabId: String?

  public init(_ kind: Kind, windowId: String? = nil, focusWindow: String? = nil, tabId: String? = nil) {
    self.kind = kind
    self.windowId = windowId
    self.focusWindow = focusWindow
    self.tabId = tabId
  }

  public var json: JSONValue {
    func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    return .object(["kind": .string(kind.rawValue), "windowId": text(windowId), "focusWindow": text(focusWindow), "tabId": text(tabId)])
  }

  public static let utilityWindowIds: Set<String> = ["settings", "import"]

  public static let littleSolaraCommands: Set<String> = [
    "closeTab", "focusCommandBar", "openFile", "switchProfile", "nextProfile", "previousProfile", "openProfileMenu",
  ]

  public static let windowLevelCommands: Set<String> = [
    "newWindow", "newIncognitoWindow", "newLittleSolara", "toggleOpenLinksInLittleSolara", "reopenClosedWindow", "setAppearance",
    "toggleFullUrl", "toggleJavaScriptFromAppleEvents", "setSidebarPosition", "toggleSidebarIconsOnly", "toggleAddressBar",
    "openSettings", "keyboardShortcuts", "importBrowserData", "openFile", "manageExtensions", "setBookmarksBar", "toggleBookmarksBar",
  ]

  public static let invokerCommands: Set<String> = ["addFolderToSidebar", "restoreArcFolders"]

  public static let littleSolaraPageCommands: Set<String> = [
    "addBookmarkToFolder", "addExtension", "autofill", "back", "bookmarkPage", "caretBrowsing", "cast", "copyUrl", "copyUrlAsMarkdown",
    "devTools", "downloads", "emailPageLocation", "findAndReplace", "findInPage", "findNext", "findPrevious", "forceReload", "forward",
    "inspectElements", "javaScriptConsole", "jumpToSelection", "openBookmark", "openExtension", "print", "printWithSystemDialog", "reload",
    "reopenClosedTab", "restoreClosed", "savePage", "share", "stop", "toggleDevTools", "toggleDeveloperMode", "toggleMute",
    "useSelectionForFind", "viewSource", "zoomIn", "zoomOut", "zoomReset",
  ]

  public static func resolve(_ command: String, windowId requested: String?, state: BrowserState, closing: Set<String>) -> CommandRoute {
    var target = requested
    if let id = target, utilityWindowIds.contains(id) {
      if command == "closeTab" { return CommandRoute(.utilityClose, windowId: id) }
      if command == "findInPage" && id == "settings" { return CommandRoute(.settingsSearch, windowId: id) }
      target = nil
    }
    let small = { (id: String?) in id.flatMap { state.windows[$0]?.isSmall } ?? false }
    if small(target) && littleSolaraCommands.contains(command) { return CommandRoute(.littleSolara, windowId: target) }
    if let peekWindow = state.resolveWindowId(target), let peek = state.peeks[peekWindow] {
      let peekTab = present(peek.tabId)
      if command == "openFile" { return CommandRoute(.peekPromote, windowId: peekWindow, tabId: peekTab) }
      if command == "closeTab" && state.windowUi[peekWindow]?.panelOpen != true {
        let findOpen = state.find[peek.tabId]?.json["open"]?.truthy ?? false
        return CommandRoute(findOpen ? .peekCloseFind : .peekDismiss, windowId: peekWindow, tabId: peekTab)
      }
    }
    if windowLevelCommands.contains(command) { return CommandRoute(.window, windowId: target) }
    let invokedFrom = target
    var focusWindow: String?
    if let id = target, small(id), !littleSolaraPageCommands.contains(command) {
      var memory = StoreMemory()
      memory.closingWindows = closing
      let session = Session(state: state, memory: memory, env: PlainWebAddressing(), config: StoreConfig(), now: 0)
      target = session.mainWindowFor(state, present(state.windows[id]?.profileId))
      focusWindow = target
    }
    if invokerCommands.contains(command) { return CommandRoute(.invoker, windowId: state.resolveWindowId(invokedFrom), focusWindow: focusWindow) }
    guard let windowId = state.resolveWindowId(target) else { return CommandRoute(.noWindow, focusWindow: focusWindow) }
    let peekTab = littleSolaraPageCommands.contains(command) ? present(state.peeks[windowId]?.tabId) : nil
    return CommandRoute(.main, windowId: windowId, focusWindow: focusWindow, tabId: peekTab ?? present(state.activeTabId(windowId)))
  }

  private static func present(_ id: String?) -> String? {
    guard let id, !id.isEmpty else { return nil }
    return id
  }
}
