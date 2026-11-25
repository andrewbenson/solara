import Foundation
import SolaraOmnibox
import SolaraModel
import SolaraStore
public struct TabFocusCommand: Equatable, Sendable {
  public static let commands: Set<String> = ["searchTabs", "tabSwitcher"]
  public let windowId: String
  public let profileId: String
  public let active: String?
  public let ids: [String]
  public private(set) var index: Int
  private var ended = false
  public var selected: String { ids[index] }
  public static func recent(_ state: BrowserState, windowId: String, now: Double) -> [String] {
    state.viewTabIds(windowId).enumerated().sorted {
      let a = state.tabs[$0.element]?.lastActiveAt ?? 0, b = state.tabs[$1.element]?.lastActiveAt ?? 0
      return a == b ? $0.offset < $1.offset : a > b
    }.enumerated().filter { $0.offset < 2 || now - (state.tabs[$0.element.element]?.lastActiveAt ?? 0) < 43_200_000 }.map { $0.element.element }
  }
  public static func begin(_ state: BrowserState, windowId: String, backward: Bool, now: Double) -> Self? {
    guard let window = state.windows[windowId] else { return nil }
    let ids = recent(state, windowId: windowId, now: now)
    guard ids.count > 1 else { return nil }
    return Self(windowId: windowId, profileId: window.profileId, active: state.activeTabId(windowId), ids: ids, index: backward ? ids.count - 1 : 1)
  }
  public func valid(_ state: BrowserState) -> Bool {
    !ended && state.windows[windowId]?.profileId == profileId && state.activeTabId(windowId) == active
  }
  public mutating func step(_ direction: Int, state: BrowserState) {
    guard valid(state) else { return }
    for _ in ids {
      index = (index + direction + ids.count) % ids.count
      if eligible(selected, state) { break }
    }
  }
  private func eligible(_ id: String, _ state: BrowserState) -> Bool {
    state.windows[windowId]?.tabIds.contains(id) == true && state.tabs[id]?.profileId == profileId
  }
  public mutating func cancel() { ended = true }
  public mutating func release(_ state: BrowserState) -> String? {
    let id = valid(state) && eligible(selected, state) ? selected : nil
    ended = true
    return id
  }
}
public extension TabFocusCommand {
  static func search(_ state: BrowserState, windowId: String, dark: Bool, theme: [String: String]) -> TabSearchState {
    guard let window = state.windows[windowId] else { return TabSearchState(open: [], closed: [], dark: dark, theme: theme) }
    let shared = state.settings.bool("shareTabsAcrossWindows")
    let tabs = state.tabs.values
    func family(_ t: Tab) -> String { "\(t.profileId):\(t.pinKeyOrId)" }
    let here = Set(tabs.filter { !$0.pinned && $0.windowId == windowId }.map(family))
    var used: [String: Double] = [:]
    for t in tabs where !t.pinned { used[family(t)] = max(used[family(t)] ?? 0, t.lastActiveAt) }
    func last(_ t: Tab) -> Double { shared && !t.pinned ? used[family(t)] ?? t.lastActiveAt : t.lastActiveAt }
    func row(_ t: TabSnapshot, kind: String, id: String, detail: String? = nil) -> TabSearchState.Row {
      TabSearchState.Row(kind: kind, id: id, title: t.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? (t.title.isEmpty ? (t.url.isEmpty ? "New Tab" : t.url) : t.title), url: t.url, display: displayUrl(t.url), host: URL(string: t.url)?.host ?? "", favicon: t.favicon, icon: t.customIcon, profileId: t.profileId, detail: detail)
    }
    let open = tabs.filter {
      $0.profileId == window.profileId && state.windows[$0.windowId] != nil && state.peeks[$0.windowId]?.tabId != $0.id
        && !(shared && !$0.pinned && $0.windowId != windowId && here.contains(family($0)))
    }.sorted { last($0) == last($1) ? $0.id < $1.id : last($0) > last($1) }.compactMap { t -> TabSearchState.Row? in
      guard let snapshot = try? TabSnapshot(json: t.json) else { return nil }
      return row(snapshot, kind: "tab", id: t.id, detail: t.windowId == windowId ? (state.activeTabId(windowId) == t.id ? "Current Tab" : nil) : "Window \((state.windowOrder.filter { state.windows[$0]?.incognito != true || $0 == windowId }.firstIndex(of: t.windowId) ?? 0) + 1)")
    }
    var closed = state.closedTabs.filter { $0.tab.profileId == window.profileId }.map { ($0.closedAt, row($0.tab, kind: "closed", id: $0.id)) }
    for c in state.closedGroups where !c.tabs.isEmpty && c.tabs.allSatisfy({ $0.profileId == window.profileId }) {
      guard let tab = c.tabs.first else { continue }
      var item = row(tab, kind: "closed", id: c.id, detail: "Group · \(c.tabs.count) \(c.tabs.count == 1 ? "tab" : "tabs")")
      item.title = c.group.name; item.icon = c.group.icon
      closed.append((c.closedAt, item))
    }
    return TabSearchState(open: open, closed: closed.sorted { $0.0 > $1.0 }.map(\.1), dark: dark, theme: theme)
  }
}
