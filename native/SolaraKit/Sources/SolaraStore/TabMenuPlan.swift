import Foundation
import SolaraModel
import SolaraOmnibox

public struct TabMenuItem: Equatable, Sendable {
  public var id: String?
  public var title: String
  public var symbol: String?
  public var enabled: Bool
  public var checked: Bool
  public var share: Bool
  public var children: [TabMenuItem]
  public var separator: Bool
  public var swatch: String?

  public init(id: String? = nil, title: String = "", symbol: String? = nil, enabled: Bool = true, checked: Bool = false, share: Bool = false, children: [TabMenuItem] = [], separator: Bool = false, swatch: String? = nil) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.enabled = enabled
    self.checked = checked
    self.share = share
    self.children = children
    self.separator = separator
    self.swatch = swatch
  }

  public init(json: JSONValue) {
    self.init(id: json["id"]?.string, title: json["title"]?.string ?? "", symbol: json["symbol"]?.string,
      enabled: json["enabled"]?.truthy ?? true, checked: json["checked"]?.truthy ?? false,
      share: json["share"]?.truthy ?? false, children: (json["children"]?.array ?? []).map(Self.init(json:)),
      separator: json["separator"]?.truthy ?? false, swatch: json["swatch"]?.string)
  }

  public var dictionary: [String: Any] {
    if separator { return ["separator": true] }
    var row: [String: Any] = ["title": title, "enabled": enabled, "checked": checked]
    if let id { row["id"] = id }
    if let symbol { row["symbol"] = symbol }
    if share { row["share"] = true }
    if let swatch { row["swatch"] = swatch }
    if !children.isEmpty { row["children"] = children.map(\.dictionary) }
    return row
  }

  public var json: JSONValue {
    if separator { return ["separator": true] }
    var row: JSONObject = ["title": .string(title), "enabled": .bool(enabled), "checked": .bool(checked)]
    if let id { row["id"] = .string(id) }
    if let symbol { row["symbol"] = .string(symbol) }
    if share { row["share"] = true }
    if let swatch { row["swatch"] = .string(swatch) }
    if !children.isEmpty { row["children"] = .array(children.map(\.json)) }
    return .object(row)
  }

  static var divider: Self { Self(separator: true) }
}

public enum TabMenuPlan {
  public static func items(_ state: BrowserState, windowId: String, tabId: String, calendarItem: TabMenuItem? = nil) -> [TabMenuItem]? {
    guard let tab = state.tabs[tabId], let window = state.windows[windowId], tab.windowId == windowId else { return nil }
    let selected = state.viewTabIds(windowId).filter { state.selection[windowId]?.ids.contains($0) == true }
    if selected.count > 1, selected.contains(tabId) { return nil }
    let calendar = !window.incognito && tab.pinned && isCalendarUrl(tab.pinnedUrl ?? tab.url)
    if calendar, calendarItem == nil { return nil }
    let session = Session(state: state, memory: StoreMemory(), env: PlainWebAddressing(), config: StoreConfig(), now: 0)
    let list = state.viewTabIds(windowId).filter { !state.inPinnedContainer($0) }
    let housed = state.inPinnedContainer(tabId)
    let memberPin = housed && !tab.pinned
    let index = list.firstIndex(of: tabId) ?? -1
    let above = housed ? [] : Array(Session.jsSlice(list, 0, index))
    let below = housed ? [] : Array(Session.jsSlice(list, index + 1))
    let others = list.filter { $0 != tabId }
    let group = Groups.innermostGroupOf(state.groups, tabId)
    let split = Splits.splitOf(state, tabId)
    let splitRow = Splits.splitRowPanes(state, split).contains(tabId)
    let incognito = window.incognito || Ids.isIncognitoProfile(tab.profileId)
    let across = (window.tabLayout ?? state.settings.string("tabLayout")) == "top"
    let away = !(tab.pinnedUrl ?? "").isEmpty && !tab.url.isEmpty && !samePage(tab.url, tab.pinnedUrl ?? "")
    let groups = state.groups.values.filter { $0.windowId == windowId && $0.profileId == window.profileId && $0.id != group?.id }.map { g in
      TabMenuItem(id: "group:\(g.id)", title: Groups.groupPath(state.groups, g.id).compactMap { state.groups[$0] }.map { session.groupLabel(state, $0) }.joined(separator: " › "), symbol: g.pinned ? "pin" : "square.on.square")
    }.sorted { $0.title.utf16.lexicographicallyPrecedes($1.title.utf16) }
    var rows: [TabMenuItem] = [
      .init(id: "copy", title: "Copy Link", symbol: "link", enabled: !tab.url.isEmpty),
      .init(id: "share", title: "Share", symbol: "square.and.arrow.up", enabled: matches(tab.url, "^https?:"), share: true),
      .divider,
      .init(id: "rename", title: "Rename…", symbol: "character.cursor.ibeam"),
    ]
    if !(tab.customTitle ?? "").isEmpty { rows.append(.init(id: "resetName", title: "Reset Name", symbol: "arrow.counterclockwise")) }
    rows.append(.init(id: "icon", title: "Change Icon…", symbol: "face.smiling"))
    if !(tab.customIcon ?? "").isEmpty { rows.append(.init(id: "resetIcon", title: "Reset Icon", symbol: "arrow.counterclockwise")) }
    rows.append(.init(id: "mute", title: tab.muted ? "Unmute Site" : "Mute Site", symbol: tab.muted ? "speaker.wave.2" : "speaker.slash", enabled: !tab.url.isEmpty))
    if housed {
      rows.append(.init(id: "pinnedPage", title: "Edit Pinned Page", symbol: "pin", children: [
        .init(id: "backToPin", title: "Back to Pinned URL", symbol: "arrow.uturn.backward", enabled: away),
        .init(id: "replacePin", title: "Replace Pin with Current Page", symbol: "pin", enabled: away),
        .divider,
        .init(id: "editPin", title: "Edit…", symbol: "pencil"),
      ]))
    }
    if calendar, let calendarItem { rows.append(calendarItem) }
    rows += [
      .divider,
      .init(id: "duplicate", title: "Duplicate", symbol: "plus.square.on.square"),
      .init(id: "bookmark", title: "Add to Bookmarks…", symbol: "bookmark", enabled: !tab.url.isEmpty),
    ]
    if matches(tab.url, "^(https?|file):") {
      let other = session.tabEngine(state, tabId) == "webkit" ? "Chromium" : "WebKit"
      rows.append(.init(id: "engine", title: "Open Page in \(other)", symbol: other == "Chromium" ? "globe" : "safari"))
    }
    if split != nil { rows.append(.init(id: "unsplit", title: "Remove from Split View", symbol: "rectangle.split.2x1.slash")) }
    var move: [TabMenuItem] = []
    if !splitRow, tab.pinSection != .tile { move.append(.init(id: "pinTile", title: "Top Apps", symbol: "app")) }
    if !splitRow, !tab.isPinnedRow { move.append(.init(id: "pinRow", title: "Pinned in \(state.profiles[tab.profileId]?.name ?? "Profile")", symbol: "list.bullet")) }
    if tab.pinSection == .tile {
      move.append(tab.tileFolder != nil
        ? .init(id: "leaveFolder", title: "Out of Folder", symbol: "folder.badge.minus")
        : .init(id: "newFolder", title: "New Folder…", symbol: "folder.badge.plus"))
    } else {
      move.append(.init(id: "newGroup", title: "New Group", symbol: "plus.rectangle.on.rectangle"))
      if !groups.isEmpty { move.append(.init(id: "moveToGroup", title: "Group", symbol: "rectangle.stack", children: groups)) }
      if group != nil, !memberPin { move.append(.init(id: "ungroupTab", title: "Out of Group", symbol: "folder.badge.minus")) }
    }
    move.append(.divider)
    if !incognito {
      move += state.profileOrder.map { .init(id: "profile:\($0)", title: state.profiles[$0]?.name ?? "", enabled: $0 != tab.profileId, checked: $0 == tab.profileId) }
      move += [.init(id: "profile:new", title: "New Profile…"), .divider]
    }
    let otherWindows = state.windowOrder.filter { $0 != windowId && state.windows[$0]?.incognito == false && state.windows[$0]?.isSmall == false }
    var windows = otherWindows.map { TabMenuItem(id: "window:\($0)", title: windowTitle(state, $0)) }
    if !windows.isEmpty { windows.append(.divider) }
    windows.append(.init(id: "window:new", title: "New Window"))
    move.append(.init(id: "moveToWindow", title: "Window", symbol: "macwindow", enabled: !incognito, children: windows))
    rows += [
      .init(id: "moveTo", title: "Move to", symbol: "arrow.right.square", children: move), .divider,
      memberPin ? .init(id: "unpinMember", title: "Unpin", symbol: "pin.slash")
        : .init(id: "pin", title: tab.isPinnedRow ? "Unpin" : tab.pinned ? "Unpin from Top Apps" : "Move to Top Apps", symbol: tab.pinned ? "pin.slash" : "pin"),
    ]
    if !housed {
      rows += [
        .init(id: "close", title: "Close Tab", symbol: "xmark"),
        .init(id: "closeMore", title: "Close Tabs", enabled: !others.isEmpty, children: [
          .init(id: "closeOthers", title: "Other Tabs", enabled: !others.isEmpty),
          .init(id: "closeAbove", title: across ? "Tabs to the Left" : "Tabs Above", enabled: !above.isEmpty),
          .init(id: "closeBelow", title: across ? "Tabs to the Right" : "Tabs Below", enabled: !below.isEmpty),
        ]),
      ]
    }
    return rows
  }

  public static func multiItems(_ state: BrowserState, windowId: String, ids: [String], folders: [TabMenuItem]) -> [TabMenuItem] {
    let tabs = ids.compactMap { state.tabs[$0] }
    guard !tabs.isEmpty, tabs.count == ids.count, tabs.allSatisfy({ $0.windowId == windowId }), let window = state.windows[windowId] else { return [] }
    let n = ids.count
    let allPinned = tabs.allSatisfy(\.pinned)
    let allTiles = tabs.allSatisfy { $0.pinSection == .tile }
    let incognito = window.incognito || tabs.contains { Ids.isIncognitoProfile($0.profileId) }
    let session = Session(state: state, memory: StoreMemory(), env: PlainWebAddressing(), config: StoreConfig(), now: 0)
    let groups = state.groups.values.filter { $0.windowId == windowId && $0.profileId == window.profileId }.map { group in
      TabMenuItem(id: "group:\(group.id)", title: Groups.groupPath(state.groups, group.id).compactMap { state.groups[$0] }.map { session.groupLabel(state, $0) }.joined(separator: " › "), symbol: group.pinned ? "pin" : "square.on.square")
    }.sorted { $0.title.utf16.lexicographicallyPrecedes($1.title.utf16) }
    var rows: [TabMenuItem] = [.init(id: "pin", title: allPinned ? "Unpin \(n) Tabs" : "Move \(n) Tabs to Top Apps", symbol: allPinned ? "pin.slash" : "pin")]
    if !tabs.allSatisfy(\.isPinnedRow) {
      rows.append(.init(id: "pinRows", title: "Move \(n) Tabs to Pinned in \(state.profiles[tabs[0].profileId]?.name ?? "Profile")", symbol: "list.bullet"))
    }
    rows += [
      .init(id: "duplicate", title: "Duplicate \(n) Tabs", symbol: "plus.square.on.square"),
      .init(id: "newGroup", title: "New Group with \(n) Tabs", symbol: "plus.rectangle.on.rectangle", enabled: !allTiles),
    ]
    if !groups.isEmpty { rows.append(.init(id: "moveToGroup", title: "Move to Group", symbol: "rectangle.stack", children: groups)) }
    if ids.contains(where: { Groups.innermostGroupOf(state.groups, $0) != nil }) {
      rows.append(.init(id: "ungroup", title: "Remove from Group", symbol: "folder.badge.minus"))
    }
    let others = state.windowOrder.filter { $0 != windowId && state.windows[$0]?.incognito == false && state.windows[$0]?.isSmall == false }
    var windows = others.map { TabMenuItem(id: "window:\($0)", title: windowTitle(state, $0)) }
    if !windows.isEmpty { windows.append(.divider) }
    windows.append(.init(id: "window:new", title: "New Window"))
    rows += [
      .divider,
      .init(id: "copy", title: "Copy \(n) URLs", symbol: "link"),
      .init(id: "copyMd", title: "Copy \(n) URLs as Markdown", symbol: "text.badge.checkmark"),
      .init(id: "bar", title: "Add \(n) Tabs to Bookmarks Bar", symbol: "bookmark"),
      .init(id: "bookmarkTo", title: "Add \(n) Tabs to Bookmarks Folder", symbol: "folder", children: folders),
      .divider,
      .init(id: "moveToWindow", title: "Move to Window", symbol: "macwindow", enabled: !incognito, children: windows),
      .divider,
      .init(id: "close", title: "Close \(n) Tabs", symbol: "xmark"),
    ]
    return rows
  }

  public static func multiCommand(_ choice: String, windowId: String, ids: [String], state: BrowserState) -> Command? {
    let tabs = ids.compactMap { state.tabs[$0] }
    guard !tabs.isEmpty, tabs.count == ids.count, tabs.allSatisfy({ $0.windowId == windowId }), let window = state.windows[windowId] else { return nil }
    var handled = ["pin", "pinRows", "duplicate", "ungroup", "close"].contains(choice)
    if choice == "newGroup" { handled = tabs.contains { $0.pinSection != .tile } }
    if choice.hasPrefix("group:") {
      let group = state.groups[String(choice.dropFirst(6))]
      handled = group?.windowId == windowId && group?.profileId == window.profileId
    }
    if choice.hasPrefix("window:") {
      let target = String(choice.dropFirst(7))
      handled = !window.incognito && !tabs.contains { Ids.isIncognitoProfile($0.profileId) } && canMoveToWindow(target, from: windowId, state: state)
    }
    return handled ? Command("tabMenuSelection", [.string(windowId), .array(ids.map(JSONValue.string)), .string(choice)]) : nil
  }

  public static func command(_ choice: String, windowId: String, tabId: String, state: BrowserState) -> Command? {
    guard let tab = state.tabs[tabId], tab.windowId == windowId, let window = state.windows[windowId] else { return nil }
    let id = JSONValue.string(tabId)
    let ids: JSONValue = [id]
    switch choice {
    case "pin": return Command("togglePin", [id])
    case "unpinMember": return Command("placeTabs", [ids, ["pinned": false, "groupId": .null]])
    case "pinTile": return Command("pinTabs", [ids, true, false])
    case "pinRow": return Command("pinTabs", [ids, true, true])
    case "newGroup": return tab.pinSection == .tile ? nil : Command("groupTabs", [ids])
    case "ungroupTab": return Command("removeTabsFromGroup", [ids])
    case "duplicate": return Command("duplicateTab", [id])
    case "mute": return Command("setSiteMuted", [id, .bool(!tab.muted)])
    case "resetName": return Command("updateTab", [id, ["customTitle": .null]])
    case "resetIcon": return Command("updateTab", [id, ["customIcon": .null]])
    case "backToPin": return Command("returnToPinnedUrl", [id])
    case "replacePin": return Command("setPinnedUrl", [id])
    case "unsplit": return Command("removeTabFromSplit", [id])
    case "closeOthers", "closeAbove", "closeBelow":
      let list = state.viewTabIds(windowId).filter { !state.inPinnedContainer($0) }
      let index = list.firstIndex(of: tabId) ?? -1
      let picked = choice == "closeOthers" ? list.filter { $0 != tabId } : state.inPinnedContainer(tabId) ? []
        : Array(choice == "closeAbove" ? Session.jsSlice(list, 0, index) : Session.jsSlice(list, index + 1))
      return Command("closeCommandTabs", [.array(picked.map(JSONValue.string))])
    default:
      if choice.hasPrefix("group:") {
        return Command("placeTabs", [ids, ["pinned": false, "groupId": .string(String(choice.dropFirst(6)))]])
      }
      if choice.hasPrefix("profile:") {
        let target = String(choice.dropFirst(8))
        guard target != "new", state.profiles[target] != nil, !window.incognito, !Ids.isIncognitoProfile(tab.profileId),
          !state.settings.bool("warnBeforeMovingTabsToProfile") || state.engineProfile(tab.profileId) == state.engineProfile(target) else { return nil }
        return Command("moveTabToProfile", [id, .string(target)])
      }
      if choice.hasPrefix("window:") {
        let target = String(choice.dropFirst(7))
        guard !window.incognito, !Ids.isIncognitoProfile(tab.profileId), canMoveToWindow(target, from: windowId, state: state) else { return nil }
        return Command("tabMenuMoveToWindow", [id, target == "new" ? .null : .string(target)])
      }
      return nil
    }
  }

  private static func canMoveToWindow(_ target: String, from source: String, state: BrowserState) -> Bool {
    if target == "new" { return true }
    guard target != source, let window = state.windows[target] else { return false }
    return !window.incognito && !window.isSmall
  }

  static func matches(_ text: String, _ expression: String) -> Bool {
    text.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
  }

  static func isCalendarUrl(_ text: String) -> Bool {
    guard let url = WhatwgURL(text) else { return false }
    let host = url.hostname.lowercased()
    let path = url.pathname
    if ["calendar.google.com", "calendar.notion.so", "calendar.proton.me", "app.fantastical.com"].contains(host) { return true }
    if matches(host, "^outlook\\.(live|office|office365)\\.com$") || host == "outlook.cloud.microsoft" { return path.hasPrefix("/calendar") }
    if ["teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com"].contains(host) {
      return !path.hasPrefix("/l/meetup-join/") && !path.hasPrefix("/meet/") && !(path.hasPrefix("/v2/") && text.contains("meetup-join"))
    }
    return ["www.icloud.com", "icloud.com"].contains(host) && path.hasPrefix("/calendar")
  }

  public static func tabLabel(_ tab: Tab) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    if tab.url.isEmpty { return "New Tab" }
    if let app = appUrlOrigin(tab.url) { return app }
    guard let url = WhatwgURL(tab.url) else { return tab.title.isEmpty ? tab.url : tab.title }
    if url.protocol == "file:" {
      if !tab.title.isEmpty { return tab.title }
      let last = url.pathname.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
      return last.removingPercentEncoding ?? tab.url
    }
    var host = displayHost(url.hostname)
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return !host.isEmpty ? host : tab.title.isEmpty ? tab.url : tab.title
  }

  static func windowTitle(_ state: BrowserState, _ windowId: String) -> String {
    guard let window = state.windows[windowId] else { return "" }
    let profile = Ids.isIncognitoProfile(window.profileId) ? "Incognito" : (state.profiles[window.profileId] ?? state.profiles[state.settings.defaultProfileId])?.name ?? "Incognito"
    let label = state.activeTab(windowId).map(tabLabel) ?? "New Tab"
    let others = state.viewTabIds(windowId).count - 1
    return "\(profile) — \(label)\(others > 0 ? " & \(others) Tab\(others == 1 ? "" : "s")" : "")"
  }
}

extension Session {
  public func tabMenuSelection(_ windowId: String, _ ids: [String], _ choice: String) -> String? {
    guard TabMenuPlan.multiCommand(choice, windowId: windowId, ids: ids, state: state) != nil else { return nil }
    var result: String?
    transaction {
      switch choice {
      case "pin": pinTabs(ids, pinned: !ids.allSatisfy { state.tabs[$0]?.pinned == true }, row: nil)
      case "pinRows": pinTabs(ids, pinned: true, row: true)
      case "duplicate": for id in ids { _ = duplicateTab(id) }
      case "newGroup": result = groupTabs(ids.filter { state.tabs[$0]?.pinSection != .tile }, pinned: true, name: nil)
      case "ungroup": removeTabsFromGroup(ids)
      case "close": closeCommandTabs(ids)
      default:
        if choice.hasPrefix("group:") {
          placeTabs(ids, TabPlacement(json: ["pinned": false, "groupId": .string(String(choice.dropFirst(6)))]))
        } else if choice.hasPrefix("window:"), let first = state.tabs[ids[0]] {
          let target = String(choice.dropFirst(7))
          if let window = moveTabsToWindow(ids, target == "new" ? nil : target) {
            hear()
            let active = state.windows[window]?.activeTabIds[first.profileId] ?? ids[0]
            activate(active)
            if let moved = state.tabs[active], moved.windowId != state.ui.focusedWindowId { setFocusedWindow(moved.windowId) }
            result = window
          }
        }
      }
      setSelection(windowId, [])
    }
    return result
  }

  public func tabMenuMoveToWindow(_ tabId: String, _ target: String?) -> String? {
    guard let window = moveTabsToWindow([tabId], target) else { return nil }
    hear()
    setFocusedWindow(window)
    return window
  }
}
