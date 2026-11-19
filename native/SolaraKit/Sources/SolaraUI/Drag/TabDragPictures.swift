import AppKit
import SolaraModel
import SolaraStore

public enum TabDragPageFallback: Equatable, Sendable {
  case none
  case picture(tabId: String)
  case placeholder(title: String, favicon: String?)
}

public struct TabDragPagePlan: Equatable, Sendable {
  public let liveTabId: String?
  public let fallback: TabDragPageFallback

  public static func make(_ state: BrowserState, windowId: String, draggedTabId: String?, hasPicture: (String) -> Bool) -> Self {
    guard let window = state.windows[windowId] else { return Self(liveTabId: nil, fallback: .none) }
    let active = window.activeTabIds[window.profileId]
    guard let shown = draggedTabId ?? active else { return Self(liveTabId: nil, fallback: .none) }
    let onScreen = shown == active || (active.flatMap { Splits.splitOf(state, $0) }?.tabIds.contains(shown) ?? false)
    let tab = state.tabs[shown]
    let fallback: TabDragPageFallback
    if onScreen && (tab?.url ?? "").isEmpty {
      fallback = .none
    } else if hasPicture(shown) {
      fallback = .picture(tabId: shown)
    } else if let tab {
      let title = [tab.customTitle ?? "", tab.title, tab.url].first { !$0.isEmpty } ?? "New Tab"
      fallback = .placeholder(title: title, favicon: tab.favicon)
    } else {
      fallback = .none
    }
    return Self(liveTabId: onScreen ? shown : nil, fallback: fallback)
  }
}

@MainActor
public final class TabDragPictures {
  public static let settle: TimeInterval = 1.5
  public static let keep = 40

  public var capture: (_ tabId: String, _ done: @escaping @MainActor (PagePicture?) -> Void) -> Void = { _, done in done(nil) }
  public var after: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
  }
  public var current: () -> BrowserState? = { nil }

  private var pictures: [String: PagePicture] = [:]
  private var order: [String] = []
  private var pending: [String: Int] = [:]
  private var generation = 0

  public init() {}

  public func picture(_ tabId: String) -> PagePicture? { pictures[tabId] }

  public func reset() {
    pictures = [:]
    order = []
    pending = [:]
    generation += 1
  }

  #if DEBUG
  public var remembered: [String] { order }
  #endif

  public func changed(from previous: BrowserState, to state: BrowserState, windows windowsChanged: Bool, tabs tabsChanged: Bool) {
    guard windowsChanged || tabsChanged else { return }
    for id in pending.keys where state.windows[id] == nil { pending[id] = nil }
    for window in state.windows.values {
      guard let id = window.activeTabIds[window.profileId], !window.incognito else { continue }
      if let was = previous.windows[window.id], was.activeTabIds[was.profileId] == id, state.tabs[id]?.url == previous.tabs[id]?.url { continue }
      if Ids.isIncognitoProfile(state.tabs[id]?.profileId ?? "") { continue }
      schedule(windowId: window.id, tabId: id)
    }
    if tabsChanged {
      for id in order where state.tabs[id] == nil { forget(id) }
    }
  }

  private func schedule(windowId: String, tabId: String) {
    generation += 1
    let mine = generation
    pending[windowId] = mine
    after(Self.settle) { [weak self] in
      guard let self, self.pending[windowId] == mine else { return }
      self.pending[windowId] = nil
      guard let state = self.current(), let window = state.windows[windowId], window.activeTabIds[window.profileId] == tabId else { return }
      self.remember(tabId)
    }
  }

  private func remember(_ tabId: String) {
    capture(tabId) { [weak self] picture in
      guard let self, let picture, self.current()?.tabs[tabId] != nil else { return }
      self.forget(tabId)
      self.pictures[tabId] = picture
      self.order.append(tabId)
      while self.order.count > Self.keep { self.forget(self.order[0]) }
    }
  }

  private func forget(_ tabId: String) {
    pictures[tabId] = nil
    order.removeAll { $0 == tabId }
  }
}
