import Foundation
import SolaraModel

public enum MediaStackKind: Sendable, Equatable {
  case normal, incognito
}

public struct MediaStackEntry: Equatable, Sendable {
  public var tabId: String
  public var windowId: String
  public var profileId: String
  public var report: NowPlayingReport
  public var touchedAt: Double
}

public enum MediaStack {
  public static let limit = 3
  public static let hidesWatchedTab = true

  public static func watched(state: BrowserState, windowId: String) -> Set<String> {
    guard let window = state.windows[windowId], let active = window.activeTabIds[window.profileId] else { return [] }
    var ids: Set<String> = [active]
    if let peek = state.peeks[windowId]?.tabId { ids.insert(peek) }
    for split in state.splits.values where split.tabIds.contains(active) { ids.formUnion(split.tabIds) }
    return ids
  }

  public static func visible(_ entries: [MediaStackEntry], state: BrowserState, windowId: String) -> [MediaStackEntry] {
    guard hidesWatchedTab else { return entries }
    let hidden = watched(state: state, windowId: windowId)
    return entries.filter { !hidden.contains($0.tabId) }
  }

  public static func kind(of state: BrowserState, tabId: String) -> MediaStackKind? {
    guard let tab = state.tabs[tabId], let window = state.windows[tab.windowId] else { return nil }
    return window.incognito ? .incognito : .normal
  }

  public static func entries(state: BrowserState, store: [String: NowPlayingStore.Entry], kind: MediaStackKind) -> [MediaStackEntry] {
    var out: [MediaStackEntry] = []
    for (tabId, entry) in store {
      guard !entry.removed, entry.touchedAt > 0, entry.report.controllable, entry.report.playbackState != "none",
        let tab = state.tabs[tabId], Self.kind(of: state, tabId: tabId) == kind else { continue }
      out.append(MediaStackEntry(tabId: tabId, windowId: tab.windowId, profileId: tab.profileId, report: entry.report, touchedAt: entry.touchedAt))
    }
    out.sort { $0.touchedAt != $1.touchedAt ? $0.touchedAt > $1.touchedAt : $0.tabId < $1.tabId }
    return Array(out.prefix(limit))
  }
}
