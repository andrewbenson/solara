import SolaraModel
import SolaraStore

public enum ToolbarActionCommand {
  public enum HistoryDisposition: String, Sendable {
    case current, background, foreground, window
  }

  public enum Reload: Equatable, Sendable {
    case stop, duplicate, forceReload, reload
  }

  public static func reload(_ click: ToolbarClick, loading: Bool, ignoresCache: Bool) -> Reload {
    if loading { return .stop }
    if click.meta { return .duplicate }
    return click.shift || ignoresCache ? .forceReload : .reload
  }

  public struct Target {
    public let windowId: String
    public let tab: Tab
    public let activation: Command?
    public let bookmarkProfile: String
    public let privateWindow: Bool
    public let small: Bool
    public let peek: Bool

    public func isCurrent(in state: BrowserState, closing: Set<String>) -> Bool {
      guard let current = resolve(windowId: windowId, tabId: tab.id, state: state, closing: closing) else { return false }
      return current.activation == nil && current.peek == peek && current.small == small && current.privateWindow == privateWindow
        && current.bookmarkProfile == bookmarkProfile && current.tab.profileId == tab.profileId && current.tab.createdAt == tab.createdAt
        && current.tab.url == tab.url && current.tab.navigation == tab.navigation
    }
  }

  public static func resolve(windowId: String, tabId: String, state: BrowserState, closing: Set<String>) -> Target? {
    guard !closing.contains(windowId), let window = state.windows[windowId], let tab = state.tabs[tabId],
      tab.windowId == windowId, tab.profileId == window.profileId else { return nil }
    let peek = state.peeks[windowId]
    let active = peek?.tabId ?? state.activeTabId(windowId)
    let activation: Command?
    if active == tabId, peek != nil || window.tabIds.contains(tabId) {
      activation = nil
    } else {
      guard peek == nil, window.tabIds.contains(tabId), let split = Splits.splitOf(state, active),
        split.windowId == windowId, split.tabIds.contains(tabId) else { return nil }
      activation = Command("activate", [.string(tabId)])
    }
    return Target(windowId: windowId, tab: tab, activation: activation, bookmarkProfile: state.bookmarkProfileId(window),
      privateWindow: window.incognito, small: window.isSmall, peek: peek != nil)
  }

  public static func historyDisposition(_ click: ToolbarClick) -> HistoryDisposition {
    if click.meta || click.kind == .middle { return click.shift ? .foreground : .background }
    return click.shift && !click.alt ? .window : .current
  }
}
