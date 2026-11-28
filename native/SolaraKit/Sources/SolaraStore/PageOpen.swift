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

public enum LittleSolaraEscape: Equatable, Sendable {
  case popup, popover, panel, find, window

  public static func resolve(_ source: PageOpenSource, state: BrowserState, memory: StoreMemory, popup: Bool, popover: Bool) -> Self? {
    guard state.windows[source.windowId]?.isSmall == true, state.activeTabId(source.windowId) == source.tabId,
      source == PageOpenSource(state: state, memory: memory, tabId: source.tabId) else { return nil }
    if popup { return .popup }
    if popover { return .popover }
    if state.windowUi[source.windowId]?.panelOpen == true { return .panel }
    if state.find[source.tabId]?.json["open"]?.truthy == true { return .find }
    return .window
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
    let opensLittle = disposition == "littleSolara" || (window.isSmall && disposition == "foreground" && adopt != nil
      && s.settings.bool("littleSolaraKeepsNewTabLinks"))
    if let adopt, window.isSmall || opensLittle {
      guard !memory.recentLittleAdoptions.contains(adopt), !s.tabs.values.contains(where: { $0.adoptId == adopt }) else { return }
      memory.recentLittleAdoptions = Array(memory.recentLittleAdoptions.suffix(255)) + [adopt]
    }
    if opensLittle {
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

extension Session {
  public func openExternalLinks(
    _ urls: [String], engineProfile: String?, adoptIds: [String?], dismissed: Set<Int>, pointer: [Double]?
  ) -> String? {
    let before = state
    let last = lastActiveProfile(before)
    let routedProfile = engineProfile.flatMap { engine in
      before.engineProfile(last) == engine ? last : before.profileOrder.first { before.engineProfile($0) == engine }
    }
    let profile = routedProfile ?? last
    var offers = Set<String>()
    let links = urls.enumerated().compactMap { index, url -> (url: String, adoptId: String?)? in
      guard !dismissed.contains(index) else { return nil }
      let adopt = routedProfile != nil && adoptIds.indices.contains(index) ? adoptIds[index] : nil
      if let adopt, !offers.insert(adopt).inserted { return nil }
      return (url, adopt)
    }
    guard let first = links.first else { return nil }
    let scheme = first.url.prefix { $0 != ":" }.lowercased()
    if links.count == 1, before.settings.bool("openLinksInLittleSolara"),
      first.url.contains(":"), ["http", "https", "file"].contains(scheme) {
      var options = CreateWindowOptions()
      options.profileId = profile
      options.url = first.url
      options.adoptId = first.adoptId
      options.small = true
      options.linkPointer = pointer
      _ = createWindow(options)
      return nil
    }
    var target = mainWindowFor(before, profile)
    for link in links {
      let s = state
      guard let id = target, let window = s.windows[id] else {
        var options = CreateWindowOptions()
        options.profileId = profile
        options.url = link.url
        options.adoptId = link.adoptId
        target = createWindow(options)
        continue
      }
      let blank = window.tabIds.count == 1 ? s.tabs[window.tabIds[0]] : nil
      let reusable = blank.flatMap { tab in
        tab.url.isEmpty && tab.navigation == nil && tab.profileId == profile && s.windowUi[id]?.panelOpen != true ? tab.id : nil
      }
      if let reusable, link.adoptId == nil {
        navigate(reusable, link.url)
      } else {
        var options = NewTabOptions()
        options.url = link.url
        options.profileId = profile
        options.adoptId = link.adoptId
        _ = newTab(id, options)
        if let reusable { closeTabs([reusable], lastClosesWindow: true) }
      }
    }
    if let target { setFocusedWindow(target) }
    return target
  }
}
