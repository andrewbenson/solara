import SolaraModel

public struct PageOpenSource: Equatable, Sendable {
  public let tabId: String
  public let windowId: String
  public let profileId: String
  public let page: String
  private let createdAt: Double
  private let navigation: Double?
  private let peekGeneration: UInt64

  public init?(state: BrowserState, memory: StoreMemory, tabId: String) {
    guard let tab = state.tabs[tabId], let window = state.windows[tab.windowId],
      !memory.closingWindows.contains(window.id), !memory.dismissingPeeks.contains(window.id),
      window.tabIds.contains(tabId) || state.peeks[window.id]?.tabId == tabId else { return nil }
    self.tabId = tabId
    windowId = window.id
    profileId = tab.profileId
    page = samePageKey(tab.url)
    createdAt = tab.createdAt
    navigation = tab.navigation?.seq
    peekGeneration = memory.peekGenerations[window.id, default: 0]
  }

  public func isVisible(in state: BrowserState) -> Bool {
    guard state.windows[windowId]?.profileId == profileId, let active = state.activeTabId(windowId) else { return false }
    return active == tabId || Splits.splitOf(state, active)?.tabIds.contains(tabId) == true
  }
}

extension Session {
  public func openFromPage(_ receipt: PageOpenSource, request: JSONObject, pinned: Bool = false) {
    let s = state
    guard let window = s.windows[receipt.windowId], let url = request["url"]?.string,
      receipt == PageOpenSource(state: s, memory: memory, tabId: receipt.tabId) else { return }
    var disposition = request["disposition"]?.string ?? "foreground"
    let adopt = request["adoptId"]?.string
    let peek = s.peeks[window.id].flatMap { $0.tabId == receipt.tabId ? $0 : nil }
    let opener = peek?.sourceId ?? receipt.tabId
    if pinned && !receipt.isVisible(in: s) { disposition = "background" }
    if disposition == "current" || (disposition == "peek" && (peek != nil || window.isSmall)) {
      navigate(receipt.tabId, url, userInitiated: false)
      return
    }
    if disposition == "peek" {
      guard receipt.isVisible(in: s) else { return }
      _ = openPeek(opener, url, from: request["point"].flatMap { try? PeekPoint(value: $0) })
      return
    }
    if disposition == "littleSolara" || (window.isSmall && disposition == "foreground" && adopt != nil
      && s.settings["littleSolaraKeepsNewTabLinks"]?.truthy == true) {
      var options = CreateWindowOptions()
      options.small = true
      options.profileId = receipt.profileId
      options.url = url
      options.adoptId = adopt
      _ = createWindow(options)
      return
    }
    if disposition == "window" || disposition == "incognito" {
      var options = CreateWindowOptions()
      options.url = url
      if disposition == "incognito" || window.incognito {
        options.incognito = true
        let named = (request["profile"]?.string).flatMap { name in s.profileOrder.first { s.engineProfile($0) == name } }
        options.profileId = (disposition == "incognito" ? named : nil) ?? originalProfile(s, window)
        if disposition == "incognito", adopt?.hasPrefix("tab:") == true { options.adoptId = adopt }
      } else {
        options.profileId = receipt.profileId
        options.adoptId = adopt
      }
      _ = createWindow(options)
      return
    }
    if disposition == "split", !window.isSmall {
      guard receipt.isVisible(in: s) || peek != nil else { return }
      var options = OpenPaneOptions()
      options.anchorTabId = opener
      options.url = url
      options.adoptId = adopt
      options.side = "right"
      options.background = true
      if let split = Splits.splitOf(s, opener), let index = split.tabIds.firstIndex(of: opener) {
        let replacement = split.tabIds.dropFirst(index + 1).first ?? (split.tabIds.count >= Splits.maxPanes ? split.tabIds.last : nil)
        if let replacement, replacement != opener { options.inPlaceOf = replacement }
      }
      _ = openSplitPane(window.id, options)
      return
    }
    var options = NewTabOptions()
    options.url = url
    options.adoptId = adopt
    options.openerId = opener
    options.profileId = receipt.profileId
    options.background = window.isSmall || disposition == "background" || receipt.profileId != window.profileId
    _ = newTab(window.id, options)
  }
}
