import SolaraModel

extension Session {
  func regular(_ s: BrowserState, _ id: String) -> Bool { !s.inPinnedContainer(id) }

  func insertionIndex(_ s: BrowserState, _ w: BrowserWindow, _ tab: Tab, _ background: Bool) -> Int {
    let opener = tab.openerId.flatMap { s.tabs[$0] }
    var index: Int
    if let opener, opener.windowId == w.id, opener.profileId == tab.profileId, regular(s, opener.id) {
      let panes = Splits.splitOf(s, opener.id)?.tabIds ?? [opener.id]
      let at = JS.max(panes.map { w.tabIds.jsIndexOf($0) }) + 1
      index = background ? afterFamily(s, w, tab, at, opener.id) : at
    } else if let opener, opener.windowId == w.id, opener.profileId == tab.profileId {
      if let gathered = pinnedChildGroup(s, opener.id, tab.profileId) {
        index = JS.max(gathered.tabIds.map { w.tabIds.jsIndexOf($0) }) + 1
      } else {
        index = afterFamily(s, w, tab, firstRegular(s, w, tab), opener.id)
      }
    } else {
      index = listStart(s, w, tab)
      if let opener { index = afterFamily(s, w, tab, index, opener.id) }
    }
    return outsideSplit(s, w, index)
  }

  func firstRegular(_ s: BrowserState, _ w: BrowserWindow, _ tab: Tab) -> Int {
    w.tabIds.firstIndex { s.tabs[$0]?.profileId == tab.profileId && regular(s, $0) } ?? w.tabIds.count
  }

  func nextToActive(_ s: BrowserState, _ windowId: String, _ profileId: String?) -> (openerId: String, index: Int)? {
    guard s.settings.string("newTabPosition") == "nextToCurrent", let w = s.windows[windowId] else { return nil }
    let profile = !w.incognito && truthy(profileId) && s.profiles[profileId!] != nil ? profileId! : w.profileId
    guard let activeId = w.activeTabIds[profile], let active = s.tabs[activeId], active.windowId == w.id else { return nil }
    if !regular(s, active.id) { return (active.id, firstRegular(s, w, active)) }
    let panes = Splits.splitOf(s, active.id)?.tabIds ?? [active.id]
    return (active.id, outsideSplit(s, w, JS.max(panes.map { w.tabIds.jsIndexOf($0) }) + 1))
  }

  func newTabSlot(_ s: BrowserState, _ w: BrowserWindow, _ tab: Tab) -> Int {
    nextToActive(s, w.id, tab.profileId)?.index ?? outsideSplit(s, w, listStart(s, w, tab))
  }

  func listStart(_ s: BrowserState, _ w: BrowserWindow, _ tab: Tab) -> Int {
    s.settings.string("newTabPosition") == "top" ? firstRegular(s, w, tab) : w.tabIds.count
  }

  func afterFamily(_ s: BrowserState, _ w: BrowserWindow, _ tab: Tab, _ from: Int, _ openerId: String) -> Int {
    var family: Set<String> = [openerId]
    let group = s.tabs[openerId]?.windowId == w.id && regular(s, openerId) ? groupOf(s, openerId)?.id : nil
    var index = from
    var i = max(from, 0)
    while i < w.tabIds.count {
      defer { i += 1 }
      guard let t = s.tabs[w.tabIds[i]], t.profileId == tab.profileId else { continue }
      guard let opener = t.openerId, !opener.isEmpty, family.contains(opener), groupOf(s, t.id)?.id == group else { break }
      family.insert(t.id)
      index = i + 1
    }
    return index
  }

  func outsideSplit(_ s: BrowserState, _ w: BrowserWindow, _ index: Int) -> Int {
    let before = w.tabIds.jsAt(index - 1).flatMap { index - 1 >= 0 ? $0 : nil }
    let after = index >= 0 && index < w.tabIds.count ? w.tabIds[index] : nil
    guard let before, let after, let split = Splits.splitOf(s, before), split.tabIds.contains(after) else { return index }
    return JS.max(split.tabIds.map { w.tabIds.jsIndexOf($0) }) + 1
  }

  public func forgetOpeners(_ s: BrowserState, _ windowId: String, keep: String? = nil) -> BrowserState {
    guard let w = s.windows[windowId] else { return s }
    let ids = w.tabIds.filter { $0 != keep && truthy(s.tabs[$0]?.openerId) }
    if ids.isEmpty { return s }
    var next = s
    for id in ids {
      var t = next.tabs[id]!
      t.openerId = nil
      next.tabs[id] = t
    }
    return next
  }

  func switchKeepsOpeners(_ s: BrowserState, _ from: String, _ to: String) -> Bool {
    let a = s.tabs[from]?.openerId ?? nil
    let b = s.tabs[to]?.openerId ?? nil
    return a == b || b == from || a == to
  }

  func hiddenInGroup(_ s: BrowserState, _ id: String) -> Bool {
    guard let g = groupOf(s, id) else { return false }
    return g.collapsed || Groups.ancestorIds(s.groups, g.id).contains { s.groups[$0]!.collapsed }
  }

  func openerSuccessor(_ s: BrowserState, _ closed: String, _ order: [String], _ left: [String]) -> String? {
    let at = order.jsIndexOf(closed)
    let candidates = (left.filter { order.jsIndexOf($0) > at } + left.filter { order.jsIndexOf($0) < at }.reversed()).filter {
      s.tabs[$0]!.unloaded != true && !hiddenInGroup(s, $0)
    }
    let opener = s.tabs[closed]?.openerId ?? nil
    if let hit = candidates.first(where: { s.tabs[$0]!.openerId == closed }) { return hit }
    guard let opener, !opener.isEmpty else { return nil }
    return candidates.first { s.tabs[$0]!.openerId == opener } ?? (candidates.contains(opener) ? opener : nil)
  }

  func groupOf(_ s: BrowserState, _ tabId: String?) -> TabGroup? {
    guard let tabId, !tabId.isEmpty else { return nil }
    return Groups.innermostGroupOf(s.groups, tabId)
  }

  func pinnedChildGroup(_ s: BrowserState, _ openerId: String, _ profileId: String) -> TabGroup? {
    s.groups.values.first { $0.pinnedOpenerId == openerId && $0.profileId == profileId && !$0.tabIds.isEmpty }
  }

  func isMainWindow(_ w: BrowserWindow?) -> Bool {
    guard let w else { return false }
    return !w.incognito && !w.isSmall && !memory.closingWindows.contains(w.id)
  }

  func mainWindowFor(_ s: BrowserState, _ profileId: String? = nil) -> String? {
    let order = OrderedSet(s.ui.focusOrder + s.windowOrder).elements.filter { isMainWindow(s.windows[$0]) }
    let profiled = profileId.flatMap { p in order.first { s.windows[$0]!.profileId == p } }
    return profiled ?? order.first
  }

  func originalProfile(_ s: BrowserState, _ w: BrowserWindow?) -> String? {
    let id = w?.incognito == true ? w?.originalProfileId : w?.profileId
    guard let id, s.profiles[id] != nil else { return nil }
    return id
  }

  func linkProfileOf(_ s: BrowserState, _ w: BrowserWindow?) -> String? {
    w?.isSmall == true ? nil : originalProfile(s, w)
  }

  func lastActiveProfile(_ s: BrowserState) -> String {
    if let last = s.ui.lastProfileId, s.profiles[last] != nil { return last }
    for id in s.ui.focusOrder + s.windowOrder.reversed() {
      if let profile = linkProfileOf(s, s.windows[id]) { return profile }
    }
    return s.settings.defaultProfileId
  }
}

let chromiumOnlyPrefixes = ["solara:", "chrome:", "chrome-extension:", "chrome-untrusted:", "devtools:", "view-source:"]
let protectedVideoSites = [
  "netflix.com", "disneyplus.com", "max.com", "hbomax.com", "primevideo.com", "hulu.com", "tv.apple.com", "music.apple.com", "open.spotify.com",
  "peacocktv.com", "paramountplus.com", "crunchyroll.com", "hotstar.com", "jiohotstar.com",
]

extension Session {
  func siteOf(_ url: String?) -> String? {
    guard let url, !url.isEmpty, let u = env.parseURL(url) else { return nil }
    return u.protocol == "http:" || u.protocol == "https:" ? "\(u.protocol)//\(u.host)".lowercased() : nil
  }

  func chromiumOnly(_ url: String?) -> Bool {
    guard let url, !url.isEmpty else { return false }
    let lower = url.lowercased()
    return chromiumOnlyPrefixes.contains { lower.hasPrefix($0) }
  }

  func defaultEngine(_ s: BrowserState) -> String { s.settings.string("pageEngine") == "webkit" ? "webkit" : "chromium" }

  func ruleFor(_ s: BrowserState, _ url: String?) -> String? {
    guard let site = siteOf(url) else { return nil }
    return s.settings["websiteEngines"]?.object?[site]?.string
  }

  func protectedVideoSite(_ url: String?) -> Bool {
    guard let site = siteOf(url), site.hasPrefix("https://"), let host = env.parseURL(site)?.hostname else { return false }
    return protectedVideoSites.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  func builtInEngine(_ s: BrowserState, _ url: String?) -> String? {
    s.settings["protectedVideoInWebKit"] == .bool(true) && protectedVideoSite(url) ? "webkit" : nil
  }

  func chosenEngine(_ s: BrowserState, _ url: String?) -> String? { ruleFor(s, url) ?? builtInEngine(s, url) }

  func engineForUrl(_ s: BrowserState, _ url: String?) -> String { chosenEngine(s, url) ?? defaultEngine(s) }

  func fromAdoption(_ s: BrowserState, _ t: Tab, _ depth: Int) -> String? {
    guard let id = t.adoptId, !id.isEmpty else { return nil }
    if id.hasPrefix("webkit:") { return "webkit" }
    if id.hasPrefix("solaracore:") || id.hasPrefix("tab:") { return "chromium" }
    if id.hasPrefix("clone:") {
      guard let source = s.tabs[String(id.dropFirst("clone:".count))], depth < 8 else { return nil }
      return engineOf(s, source, depth + 1)
    }
    return nil
  }

  func engineOf(_ s: BrowserState, _ t: Tab, _ depth: Int) -> String {
    if chromiumOnly(t.navigation?.url ?? t.url) { return "chromium" }
    if let engine = t.engine, !engine.isEmpty { return engine }
    if let adopted = fromAdoption(s, t, depth) { return adopted }
    if let openerId = t.openerId, let opener = s.tabs[openerId], let engine = opener.engine, !engine.isEmpty,
      !opener.url.isEmpty || opener.navigation != nil
    {
      return engine
    }
    return engineForUrl(s, t.navigation?.url ?? t.url)
  }

  func tabEngine(_ s: BrowserState, _ tabId: String) -> String {
    guard let t = s.tabs[tabId] else { return defaultEngine(s) }
    return engineOf(s, t, 0)
  }

  func typedNavigationEngine(_ s: BrowserState, _ tab: Tab, _ url: String) -> String {
    if chromiumOnly(url) { return "chromium" }
    if let chosen = chosenEngine(s, url) { return chosen }
    return !tab.url.isEmpty || tab.navigation != nil ? tabEngine(s, tab.id) : defaultEngine(s)
  }
}

public extension Store {
  func pageEngine(_ tabId: String, in s: BrowserState) -> String {
    Session(state: s, memory: StoreMemory(), env: env, config: config, now: 0).tabEngine(s, tabId)
  }
}
