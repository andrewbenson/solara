import Foundation

public enum TabSlotKey: Hashable, Sendable {
  case card(String)
  case pane(String, String)
  case peek(String)
  case popup(String)
  case sidePanel(String)

  public var windowId: String {
    switch self {
    case .card(let w), .pane(let w, _), .peek(let w), .popup(let w), .sidePanel(let w): return w
    }
  }
}

public enum TabViewPlace: Equatable, Sendable {
  case slot(TabSlotKey)
  case behind(TabSlotKey)
  case hidden(String)
}

public struct TabViewWanted: Equatable, Sendable {
  public enum Shown: Equatable, Sendable {
    case card
    case pane
    case peek
    case none
  }

  public var tabId: String
  public var windowId: String
  public var shown: Shown
  public var warm: Bool
  public var frozen: Bool
  public var identity: String
  public var profileId: String

  public init(tabId: String, windowId: String, shown: Shown, warm: Bool = false, frozen: Bool = false, identity: String = "", profileId: String = "") {
    self.tabId = tabId
    self.windowId = windowId
    self.shown = shown
    self.warm = warm
    self.frozen = frozen
    self.identity = identity
    self.profileId = profileId
  }
}

public enum TabViewOp: Equatable, Sendable {
  case drop(String)
  case create(String, String)
  case attach(String, TabSlotKey, adopt: Bool)
  case hide(String, String, adopt: Bool)
  case behind(String, TabSlotKey, adopt: Bool)
  case visible(String, Bool)
}

public enum TabViewPlan {
  static func slot(for w: TabViewWanted, in slots: Set<TabSlotKey>) -> TabSlotKey? {
    let candidates: [TabSlotKey]
    switch w.shown {
    case .peek: candidates = [.peek(w.windowId), .pane(w.windowId, w.tabId), .card(w.windowId)]
    case .pane: candidates = [.pane(w.windowId, w.tabId), .card(w.windowId)]
    case .card: candidates = [.card(w.windowId)]
    case .none: candidates = []
    }
    return candidates.first { slots.contains($0) }
  }

  static func windowOf(_ place: TabViewPlace) -> String {
    switch place {
    case .slot(let key), .behind(let key): return key.windowId
    case .hidden(let w): return w
    }
  }

  public static func plan(wanted: [TabViewWanted], slots: Set<TabSlotKey>, current: [String: TabViewPlace], visible: [String: Bool]) -> [TabViewOp] {
    var ops: [TabViewOp] = []
    let byId = Dictionary(wanted.map { ($0.tabId, $0) }, uniquingKeysWith: { first, _ in first })
    for tabId in current.keys.sorted() where byId[tabId] == nil { ops.append(.drop(tabId)) }
    var claimed: Set<TabSlotKey> = []
    var targets: [(TabViewWanted, TabViewPlace)] = []
    for w in byId.values.sorted(by: { $0.tabId < $1.tabId }) {
      if let key = slot(for: w, in: slots), !claimed.contains(key) {
        claimed.insert(key)
        targets.append((w, .slot(key)))
      } else if w.warm, slots.contains(.card(w.windowId)) {
        targets.append((w, .behind(.card(w.windowId))))
      } else {
        targets.append((w, .hidden(w.windowId)))
      }
    }
    for (w, place) in targets where current[w.tabId] == nil { ops.append(.create(w.tabId, w.windowId)) }
    for (w, place) in targets {
      guard case .hidden(let window) = place else { continue }
      let now = current[w.tabId] ?? .hidden(w.windowId)
      if now != place { ops.append(.hide(w.tabId, window, adopt: windowOf(now) != window)) }
    }
    for (w, place) in targets {
      guard case .behind(let key) = place else { continue }
      let now = current[w.tabId] ?? .hidden(w.windowId)
      if now != place { ops.append(.behind(w.tabId, key, adopt: windowOf(now) != key.windowId)) }
    }
    for (w, place) in targets {
      guard case .slot(let key) = place else { continue }
      let now = current[w.tabId] ?? .hidden(w.windowId)
      if now != place { ops.append(.attach(w.tabId, key, adopt: windowOf(now) != key.windowId)) }
    }
    for (w, place) in targets {
      let shown: Bool
      if case .slot = place { shown = !w.frozen } else { shown = false }
      if visible[w.tabId] != shown { ops.append(.visible(w.tabId, shown)) }
    }
    return ops
  }

  public static func apply(_ ops: [TabViewOp], to current: [String: TabViewPlace], visible: [String: Bool]) -> (current: [String: TabViewPlace], visible: [String: Bool]) {
    var places = current, shown = visible
    for op in ops {
      switch op {
      case .drop(let id):
        places[id] = nil
        shown[id] = nil
      case .create(let id, let w): places[id] = .hidden(w)
      case .attach(let id, let key, _): places[id] = .slot(key)
      case .hide(let id, let w, _): places[id] = .hidden(w)
      case .behind(let id, let key, _): places[id] = .behind(key)
      case .visible(let id, let on): shown[id] = on
      }
    }
    return (places, shown)
  }
}
