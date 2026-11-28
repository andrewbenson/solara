import SolaraModel

func samePageKey(_ url: String) -> String { url.jsBeforeFirst("#") }

func peekable(_ url: String) -> Bool {
  let lower = url.lowercased()
  return lower.hasPrefix("http://") || lower.hasPrefix("https://")
}

extension Session {
  func isPeekTab(_ s: BrowserState, _ id: String?) -> Bool {
    guard let id, let tab = s.tabs[id] else { return false }
    return s.peeks[tab.windowId]?.tabId == id
  }

  func withoutPeek(_ s: BrowserState, _ windowId: String) -> BrowserState {
    guard let peek = s.peeks[windowId] else { return s }
    var next = removeTabs(s, [peek.tabId], record: false)
    next.peeks.remove([windowId])
    return next
  }

  func settlePeeks(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    if !s.peeks.changed(from: prev.peeks) && !s.tabs.changed(from: prev.tabs) && !s.windows.changed(from: prev.windows) { return nil }
    var next = s
    var changed = false
    for (windowId, peek) in s.peeks {
      let source = s.tabs[peek.sourceId]
      let stale =
        s.windows[windowId] == nil || s.tabs[peek.tabId] == nil || source == nil || s.activeTabId(windowId) != peek.sourceId
        || samePageKey(source!.url) != peek.sourcePage
      if stale {
        next = withoutPeek(next, windowId)
        changed = true
      }
    }
    return changed ? next : nil
  }

  public func openPeek(_ sourceTabId: String, _ url: String, from: PeekPoint?) -> String {
    var s = state
    guard let source = s.tabs[sourceTabId], let w = s.windows[source.windowId], !w.isSmall, !memory.closingWindows.contains(w.id), !memory.dismissingPeeks.contains(w.id), peekable(url), w.tabIds.contains(sourceTabId) else {
      return ""
    }
    s = withoutPeek(s, w.id)
    if s.activeTabId(w.id) != sourceTabId { s = activated(s, sourceTabId) }
    var tab = makeTab(w.id, source.profileId, url)
    tab.openerId = sourceTabId
    tab.navigation = navigationTo(url, userInitiated: true)
    s.tabs[tab.id] = tab
    s.peeks[w.id] = Peek(tabId: tab.id, sourceId: sourceTabId, sourcePage: samePageKey(s.tabs[sourceTabId]!.url), from: from)
    set(s)
    return tab.id
  }

  public func beginPeekDismissal(_ windowId: String, tabId: String) -> Bool {
    guard state.peeks[windowId]?.tabId == tabId, memory.dismissingPeeks.insert(windowId).inserted else { return false }
    return true
  }

  public func closePeek(_ windowId: String, tabId: String? = nil) {
    let s = state
    guard let peek = s.peeks[windowId], tabId == nil || peek.tabId == tabId else { return }
    set(withoutPeek(s, windowId))
  }

  public func peekToTab(_ windowId: String, activate: Bool = true, tabId: String? = nil) -> String? {
    var s = state
    guard let peek = s.peeks[windowId], tabId == nil || tabId == peek.tabId, let tab = s.tabs[peek.tabId],
      s.windows[windowId] != nil, !memory.dismissingPeeks.contains(windowId) else { return nil }
    s.peeks.remove([windowId])
    if activate { s = forgetOpeners(s, windowId) }
    let loaded = hasNavigatedPage(tab)
    var moved = tab
    moved.openerId = s.tabs[peek.sourceId] != nil ? peek.sourceId : nil
    moved.navigation = loaded ? navigationTo(tab.url) : tab.navigation
    moved.lastActiveAt = now
    s.tabs[tab.id] = moved
    var w = s.windows[windowId]!
    var tabIds = w.tabIds
    tabIds.jsSplice(min(insertionIndex(s, w, moved, false), tabIds.count), 0, [tab.id])
    w.tabIds = pinnedFirst(tabIds, s.tabs)
    s.windows[windowId] = w
    if let opener = moved.openerId { s = groupWithOpener(s, tab.id, opener, background: false) }
    if activate { s = activated(s, tab.id) }
    set(s)
    return tab.id
  }
}
