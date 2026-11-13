import Foundation
import SolaraModel

extension TabViewWanted {
  public static func from(_ state: BrowserState, windows: Set<String>, isInternal: (Tab) -> Bool, frozen: (String) -> Bool,
    newTabShown: (String) -> Bool = { _ in false }) -> [TabViewWanted] {
    var out: [String: TabViewWanted] = [:]
    for windowId in windows.sorted() {
      guard let window = state.windows[windowId] else { continue }
      let active = window.activeTabIds[window.profileId]
      let split = active.flatMap { id in state.splits.values.first { $0.windowId == windowId && $0.tabIds.contains(id) } }
      let warm = Set(window.activeTabIds.keys.filter { $0 != window.profileId }.compactMap { window.activeTabIds[$0] })
      for id in window.tabIds {
        guard let tab = state.tabs[id], ((tab.navigation != nil || tab.adoptId != nil) && !isInternal(tab)) else { continue }
        let shown: Shown
        if newTabShown(id) { shown = .none } else if let split, split.tabIds.contains(id) { shown = .pane } else if id == active { shown = .card } else { shown = .none }
        out[id] = TabViewWanted(tabId: id, windowId: windowId, shown: shown, warm: warm.contains(id), frozen: frozen(id), profileId: tab.profileId)
      }
      if let peek = state.peeks[windowId], let tab = state.tabs[peek.tabId], ((tab.navigation != nil || tab.adoptId != nil) && !isInternal(tab)) {
        out[peek.tabId] = TabViewWanted(tabId: peek.tabId, windowId: windowId, shown: newTabShown(peek.tabId) ? .none : .peek, frozen: frozen(peek.tabId), profileId: tab.profileId)
      }
    }
    return out.keys.sorted().map { out[$0]! }
  }
}

public struct TabViewPark: Sendable {
  public static let limit: TimeInterval = 2
  public private(set) var since: [String: Date] = [:]

  public init() {}

  public mutating func park(_ moving: [TabViewWanted], now: Date, limit: TimeInterval = Self.limit) -> [TabViewWanted] {
    since = Dictionary(moving.map { ($0.tabId, since[$0.tabId] ?? now) }, uniquingKeysWith: { first, _ in first })
    return moving
      .filter { now.timeIntervalSince(since[$0.tabId] ?? now) < limit }
      .map { TabViewWanted(tabId: $0.tabId, windowId: $0.windowId, shown: .none, profileId: $0.profileId) }
  }

  public func nextExpiry(after now: Date, limit: TimeInterval = Self.limit) -> Date? {
    since.values.map { $0.addingTimeInterval(limit) }.filter { $0 > now }.min()
  }
}
