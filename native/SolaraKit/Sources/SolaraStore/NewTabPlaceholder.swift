import SolaraModel

extension Session {
  func withNewTabPlaceholder(_ s: BrowserState, _ id: String, openerId: String? = nil) -> BrowserState {
    guard var tab = s.tabs[id] else { return s }
    tab.newTabPlaceholder = true
    if truthy(openerId) { tab.openerId = openerId }
    tab.navigation = navigationTo("about:blank")
    tab.engine = "chromium"
    var next = s
    next.tabs[id] = tab
    return next
  }

  func settlingNewTab(_ s: BrowserState, _ id: String) -> BrowserState {
    guard var tab = s.tabs[id], tab.newTabPlaceholder == true else { return s }
    tab.newTabPlaceholder = nil
    var next = s
    next.tabs[id] = tab
    if let opener = tab.openerId, next.tabs[opener] != nil {
      next = forgetOpeners(next, tab.windowId, keep: id)
      if !next.inPinnedContainer(opener) { next = groupWithOpener(next, id, opener, background: false) }
    }
    return next
  }

  func activeTabIdsWithoutPlaceholders(_ s: BrowserState, _ w: BrowserWindow, keeping kept: [String]) -> JSMap<String> {
    let keptSet = Set(kept)
    var out = w.activeTabIds.filter { _, id in keptSet.contains(id) }
    for (profileId, id) in w.activeTabIds where out[profileId] == nil && s.tabs[id]?.newTabPlaceholder == true {
      let previous = kept.filter { s.tabs[$0]?.profileId == profileId }
        .reduce(nil as String?) { best, t in best == nil || shownAt(s.tabs[t]!) > shownAt(s.tabs[best!]!) ? t : best }
      if let previous { out[profileId] = previous }
    }
    return out
  }

  public func settleNewTab(_ id: String) {
    set(settlingNewTab(state, id))
  }

  func normalizedNewTabPlaceholders(_ s: BrowserState) -> BrowserState {
    var next = s
    var gone: [String] = []
    let candidates = Set((state.windows.values + s.windows.values).flatMap { $0.activeTabIds.values })
    for id in candidates {
      guard let original = s.tabs[id], original.newTabPlaceholder == true else { continue }
      guard let window = s.windows[original.windowId] else { continue }
      let navigation = original.navigation
      let navigated = navigation.map { $0.url != "about:blank" || $0.userInitiated == true } ?? false
      if !original.url.isEmpty || navigated || truthy(original.adoptId) || original.pinned
        || Groups.innermostGroupOf(s.groups, original.id) != nil || Splits.splitOf(s, original.id) != nil {
        next = settlingNewTab(next, original.id)
      } else if window.profileId != original.profileId || window.activeTabIds[original.profileId] != original.id {
        gone.append(original.id)
      }
    }
    return removeTabs(next, gone, record: false)
  }
}
