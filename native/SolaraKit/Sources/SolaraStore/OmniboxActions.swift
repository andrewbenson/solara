import SolaraModel

public enum OmniboxOpenDisposition: String, Sendable {
  case current, newTab, backgroundTab, newWindow
}

extension Session {
  func omniboxSource(_ windowId: String, _ tabId: String) -> (BrowserWindow, Tab)? {
    guard let window = state.windows[windowId], let tab = state.tabs[tabId], tab.windowId == windowId,
      tab.profileId == window.profileId, state.activeTabId(windowId) == tabId else { return nil }
    return (window, tab)
  }

  func omniboxDestination(_ tabId: String) -> JSONValue {
    guard let tab = state.tabs[tabId] else { return .null }
    return ["tabId": .string(tabId), "windowId": .string(tab.windowId)]
  }

  public func omniboxOpen(_ windowId: String, _ tabId: String, _ input: String, _ disposition: OmniboxOpenDisposition, _ opensTab: JSONValue? = nil) -> JSONValue {
    guard !input.jsTrim().isEmpty, let (window, tab) = omniboxSource(windowId, tabId) else { return .null }
    let target: JSONValue?
    if opensTab == .bool(true) { target = state.windowUi[windowId]?.json["panel"]?["newTab"] ?? ["kind": "list"] }
    else if let object = opensTab?.object { target = .object(object) }
    else { target = nil }
    var destination: JSONValue = .null
    transaction {
      if disposition == .newWindow {
        var options = CreateWindowOptions()
        options.url = input
        options.incognito = window.incognito
        options.profileId = window.incognito ? window.originalProfileId ?? Ids.incognitoOriginal(tab.profileId) : tab.profileId
        let created = createWindow(options)
        if let id = state.activeTabId(created) { destination = omniboxDestination(id) }
      } else if disposition != .current || target != nil {
        if disposition == .current, target?["kind"]?.string == "into", let into = target?["tabId"]?.string,
          let empty = state.tabs[into], empty.windowId == windowId, empty.profileId == window.profileId,
          isEmptyCardTab(state, empty) {
          navigate(into, input)
          activate(into)
          destination = omniboxDestination(into)
        } else if disposition == .current, target?["kind"]?.string == "group", let groupId = target?["groupId"]?.string,
          let group = state.groups[groupId], group.windowId == windowId, group.profileId == window.profileId {
          let id = newTabInGroup(groupId)
          if !id.isEmpty {
            navigate(id, input)
            activate(id)
            destination = omniboxDestination(id)
          }
        } else {
          var options = NewTabOptions()
          options.url = input
          options.background = disposition == .backgroundTab
          options.profileId = tab.profileId
          if target == nil { options.openerId = tab.url.isEmpty ? nil : tab.id }
          else { options.newTabCommand = true }
          destination = omniboxDestination(newTab(windowId, options))
        }
      } else {
        navigate(tabId, input)
        destination = omniboxDestination(tabId)
      }
      if !destination.isNull { closePanel(windowId) }
    }
    return destination
  }

  public func omniboxSwitch(_ windowId: String, _ tabId: String, _ targetId: String, _ url: String, _ disposition: OmniboxOpenDisposition) -> JSONValue {
    guard let (window, _) = omniboxSource(windowId, tabId), let target = state.tabs[targetId],
      let targetWindow = state.windows[target.windowId],
      window.incognito == targetWindow.incognito,
      !window.incognito || target.windowId == windowId else { return .null }
    if disposition != .current { return omniboxOpen(windowId, tabId, url, disposition) }
    transaction {
      closePanel(windowId)
      activate(targetId)
      setFocusedWindow(target.windowId)
    }
    return omniboxDestination(targetId)
  }

  func omniboxInternalPage(_ tab: Tab, _ page: String) -> Bool {
    guard let parsed = env.parseURL(tab.navigation?.url ?? tab.url) else { return false }
    return parsed.protocol == "solara:" && parsed.host == page
  }

  public func omniboxCommand(_ windowId: String, _ id: String) -> JSONValue {
    let supported: Set<String> = ["newTab", "newWindow", "newIncognitoWindow", "duplicateTab", "showHistory", "manageBookmarks", "downloads", "split:sideBySide", "split:stacked", "split:add", "split:cross"]
    let profileTarget = id.hasPrefix("switchProfile:") ? String(id.dropFirst("switchProfile:".count)) : nil
    guard supported.contains(id) || profileTarget != nil else { return false }
    guard let window = state.windows[windowId] else { return true }
    var destination: JSONValue = true
    transaction {
      closePanel(windowId)
      if let profileTarget {
        switchProfile(windowId, profileTarget)
        if let tabId = state.activeTabId(windowId) { destination = omniboxDestination(tabId) }
      } else {
        switch id {
        case "newTab":
          var options = NewTabOptions()
          options.newTabCommand = true
          destination = omniboxDestination(newTab(windowId, options))
        case "newWindow", "newIncognitoWindow":
          var options = CreateWindowOptions()
          options.profileId = window.incognito ? window.originalProfileId ?? Ids.incognitoOriginal(window.profileId) : window.profileId
          options.incognito = id == "newIncognitoWindow"
          let created = createWindow(options)
          if let tabId = state.activeTabId(created) { destination = omniboxDestination(tabId) }
        case "duplicateTab":
          if let active = state.activeTabId(windowId), let copy = duplicateTab(active) { destination = omniboxDestination(copy) }
        case "downloads":
          setDownloadsOpen(windowId, state.windowUi[windowId]?.downloadsOpen != true)
        case "split:sideBySide", "split:stacked", "split:add", "split:cross":
          if let active = state.activeTabId(windowId) {
            let split = Splits.splitOf(state, active)
            let horizontal = split?.orientation == "horizontal"
            var options = OpenPaneOptions()
            options.anchorTabId = active
            switch id {
            case "split:sideBySide": options.side = "right"
            case "split:stacked": options.side = "bottom"
            case "split:cross": options.side = horizontal ? "bottom" : "right"
            default: options.side = horizontal ? "right" : "bottom"
            }
            let opened = openSplitPane(windowId, options)
            if opened["ok"]?.truthy == true, let tabId = opened["tabId"]?.string { destination = omniboxDestination(tabId) }
          }
        case "showHistory", "manageBookmarks":
          let page = id == "showHistory" ? "history" : "bookmarks"
          let url = "solara://" + page
          if let existing = window.tabIds.first(where: { tabId in
            guard let tab = state.tabs[tabId], tab.profileId == window.profileId else { return false }
            return omniboxInternalPage(tab, page)
          }) {
            activate(existing)
            destination = omniboxDestination(existing)
          } else if let active = state.activeTabId(windowId), isEmptyCardTab(state, state.tabs[active]) {
            navigate(active, url)
            destination = omniboxDestination(active)
          } else {
            var options = NewTabOptions()
            options.url = url
            options.profileId = window.profileId
            destination = omniboxDestination(newTab(windowId, options))
          }
        default: break
        }
      }
    }
    return destination
  }
}
