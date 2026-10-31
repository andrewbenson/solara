import SolaraModel

func swapIds(_ ids: [String], _ a: String, _ b: String) -> [String]? {
  guard ids.contains(a) || ids.contains(b) else { return nil }
  return ids.map { $0 == a ? b : $0 == b ? a : $0 }
}

func swapWindow(_ w: BrowserWindow, _ a: String, _ b: String) -> BrowserWindow {
  var out = w
  if let swapped = swapIds(w.tabIds, a, b) { out.tabIds = swapped }
  if w.activeTabIds.values.contains(where: { $0 == a || $0 == b }) { out.activeTabIds = w.activeTabIds.mapValues { $0 == a ? b : $0 == b ? a : $0 } }
  return out
}

func showFields(of holder: Tab, on t: inout Tab) {
  t.url = holder.url
  t.title = holder.title
  t.takeFavicon(from: holder)
  t.muted = holder.muted
}

func frozenIds(_ s: BrowserState) -> [String] { s.tabs.values.filter { truthy($0.pageIn) }.map(\.id) }

extension Session {
  func shares(_ s: BrowserState, _ t: Tab?) -> Bool {
    guard let t else { return false }
    return !Ids.isIncognitoProfile(t.profileId) && mirrored(s.windows[t.windowId]) && (s.inPinnedContainer(t.id) || sharedListTab(s, t))
      && Splits.splitOf(s, t.id) == nil
  }

  func holds(_ s: BrowserState, _ holder: Tab?, _ copy: Tab) -> Bool {
    guard let holder, shares(s, holder) else { return false }
    return holder.id != copy.id && holder.windowId != copy.windowId && holder.profileId == copy.profileId && holder.pinKeyOrId == copy.pinKeyOrId
      && hasPage(holder) && !truthy(holder.pageIn)
  }

  func holderOf(_ s: BrowserState, _ id: String) -> Tab? {
    guard let t = s.tabs[id], shares(s, t), !hasPage(t) else { return nil }
    if let pageIn = t.pageIn, !pageIn.isEmpty, let named = s.tabs[pageIn], holds(s, named, t) { return named }
    let key = t.pinKeyOrId
    var best: Tab? = nil
    for x in s.tabs.values where x.pinKeyOrId == key && holds(s, x, t) {
      if best == nil || x.lastActiveAt > best!.lastActiveAt { best = x }
    }
    return best
  }

  func swapPinPage(_ s: BrowserState, _ id: String) -> (state: BrowserState, holderId: String)? {
    guard let copy = s.tabs[id], let holder = holderOf(s, id) else { return nil }
    let from = holder.windowId
    let to = copy.windowId
    let a = holder.id
    let b = copy.id
    var next = s
    next.windows[from] = swapWindow(s.windows[from]!, a, b)
    next.windows[to] = swapWindow(s.windows[to]!, a, b)
    var moving = holder
    moving.pageIn = nil
    moving.windowId = to
    if let navigation = holder.navigation {
      var nav = navigation
      nav.url = holder.url.isEmpty ? navigation.url : holder.url
      moving.navigation = nav
    }
    var staying = copy
    staying.unloaded = nil
    staying.adoptId = nil
    showFields(of: holder, on: &staying)
    staying.windowId = from
    staying.navigation = nil
    staying.pageIn = a
    next.tabs[a] = moving
    next.tabs[b] = staying
    for t in s.tabs.values {
      guard t.id != a, t.id != b, let opener = t.openerId, !opener.isEmpty else { continue }
      if t.windowId == from && opener == a {
        var changed = t
        changed.openerId = b
        next.tabs[t.id] = changed
      } else if t.windowId == to && opener == b {
        var changed = t
        changed.openerId = a
        next.tabs[t.id] = changed
      }
    }
    for g in s.groups.values {
      if g.windowId != from && g.windowId != to { continue }
      let tabIds = swapIds(g.tabIds, a, b)
      let mine = g.windowId == from ? a : b
      let theirs = g.windowId == from ? b : a
      let opener = g.pinnedOpenerId == mine ? theirs : g.pinnedOpenerId
      if tabIds == nil && opener == g.pinnedOpenerId { continue }
      var changed = g
      if let tabIds { changed.tabIds = tabIds }
      if opener != g.pinnedOpenerId { changed.pinnedOpenerId = opener }
      next.groups[g.id] = changed
    }
    next.swapSelection(a, b)
    next.live[b] = s.live[a]
    emitLiveSwap(a: a, b: b, from: s)
    return (next, a)
  }

  func frozenCopiesOf(_ s: BrowserState, _ holderId: String) -> [Tab] {
    frozenIds(s).map { s.tabs[$0]! }.filter { $0.pageIn == holderId }
  }

  func frozenAfter(_ s: BrowserState, _ prev: BrowserState) -> [String] {
    var out = OrderedSet(frozenIds(prev).filter { truthy(s.tabs[$0]?.pageIn) })
    for id in s.tabs.changedIds(from: prev.tabs) where truthy(s.tabs[id]?.pageIn) { out.insert(id) }
    return out.elements
  }

  func withSharedFamily(_ s: BrowserState, _ ids: [String]) -> [String] {
    var out = OrderedSet(ids)
    let frozen = frozenIds(s)
    if frozen.isEmpty { return ids }
    for id in ids { if let pageIn = s.tabs[id]?.pageIn, !pageIn.isEmpty { out.insert(pageIn) } }
    for f in frozen { if let pageIn = s.tabs[f]!.pageIn, out.contains(pageIn) { out.insert(f) } }
    return out.elements
  }

  func shownIn(_ s: BrowserState, _ t: Tab) -> Bool {
    s.windows[t.windowId]?.activeTabIds[t.profileId] == t.id
  }

  func splitLeavers(_ s: BrowserState, _ prev: BrowserState) -> [String] {
    if !s.splits.changed(from: prev.splits) { return [] }
    let now = Set(s.splits.values.flatMap(\.tabIds))
    return prev.splits.values.flatMap(\.tabIds).filter { !now.contains($0) }
  }

  func oneOwnerPerPin(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    let gained =
      !s.tabs.changed(from: prev.tabs)
      ? []
      : s.tabs.changedIds(from: prev.tabs).filter { id in
        guard let t = s.tabs[id], hasPage(t) else { return false }
        let was = prev.tabs[id]
        return !(was.map { hasPage($0) && Splits.splitOf(prev, id) == nil } ?? false)
      }
    let candidates = OrderedSet(gained + splitLeavers(s, prev)).elements
    if candidates.isEmpty { return nil }
    var tabs = s.tabs
    var changed = false
    func freeze(_ loser: Tab, _ keeper: Tab) {
      var rest = loser
      rest.navigation = nil
      rest.adoptId = nil
      rest.unloaded = nil
      showFields(of: keeper, on: &rest)
      rest.pageIn = keeper.id
      tabs[loser.id] = rest
      for t in tabs.values where t.pageIn == loser.id {
        var moved = t
        moved.pageIn = keeper.id
        tabs[t.id] = moved
      }
      changed = true
    }
    for id in candidates {
      var view = s
      if changed { view.tabs = tabs }
      guard let c = tabs[id], shares(view, c), hasPage(c), !truthy(c.pageIn) else { continue }
      let family = tabs.values.filter { $0.id != c.id && $0.windowId != c.windowId && holds(view, $0, c) }
      if family.isEmpty { continue }
      let newcomer = gained.contains(c.id) && Splits.splitOf(prev, c.id) == nil
      let all = newcomer ? family : [c] + family
      let keeper = all.dropFirst().reduce(all[0]) { x, y in y.lastActiveAt > x.lastActiveAt ? y : x }
      for loser in [c] + family where loser.id != keeper.id { freeze(loser, keeper) }
    }
    guard changed else { return nil }
    var next = s
    next.tabs = tabs
    return next
  }

  func settleSharedPins(_ next: BrowserState, _ prev: BrowserState) -> BrowserState? {
    if !next.tabs.changed(from: prev.tabs) && !next.windows.changed(from: prev.windows) && !next.groups.changed(from: prev.groups)
      && !next.splits.changed(from: prev.splits)
    {
      return nil
    }
    let owned = oneOwnerPerPin(next, prev)
    let s = owned ?? next
    let frozen = frozenAfter(s, prev)
    if frozen.isEmpty { return owned }
    var tabs = s.tabs
    var windows = s.windows
    var edited = false
    for id in frozen {
      let t = s.tabs[id]!
      let holder = s.tabs[t.pageIn ?? ""]
      if let holder, !hasPage(t), shares(s, holder), holder.windowId == t.windowId, holder.profileId == t.profileId,
        holder.pinKeyOrId == t.pinKeyOrId, hasPage(holder)
      {
        let w = windows[t.windowId]!
        if w.activeTabIds.values.contains(t.id) {
          var changed = w
          changed.activeTabIds = w.activeTabIds.mapValues { $0 == t.id ? holder.id : $0 }
          windows[w.id] = changed
        }
        var u = tabs[id]!
        u.pageIn = nil
        u.unloaded = true
        tabs[id] = u
        edited = true
        continue
      }
      if hasPage(t) || !holds(s, holder, t) || !shares(s, t) {
        let shown = shownIn(s, t) && !hasPage(t) && !t.url.isEmpty
        var u = tabs[id]!
        u.pageIn = nil
        if !hasPage(t) {
          if shown {
            var woken = t
            wake(&woken)
            u.adoptId = woken.adoptId
            u.wakeAdoptId = woken.wakeAdoptId
            u.navigation = woken.navigation
            u.unloaded = nil
          } else {
            u.unloaded = true
          }
        }
        tabs[id] = u
        edited = true
        continue
      }
      if t.url != holder!.url || t.title != holder!.title || t.favicon != holder!.favicon || t.muted != holder!.muted {
        var u = tabs[id]!
        showFields(of: holder!, on: &u)
        tabs[id] = u
        edited = true
      }
    }
    if !edited { return owned }
    var out = s
    out.tabs = tabs
    out.windows = windows
    return out
  }

  func returnSharedPages(_ s: BrowserState, _ windowId: String) -> BrowserState {
    guard let w = s.windows[windowId], mirrored(w), !frozenIds(s).isEmpty else { return s }
    var next = s
    for id in w.tabIds {
      guard let t = next.tabs[id], hasPage(t) else { continue }
      let order = next.ui.focusOrder
      let copies = frozenCopiesOf(next, id).filter { $0.windowId != windowId && next.windows[$0.windowId] != nil }
      if copies.isEmpty { continue }
      func rank(_ c: Tab) -> Int { order.firstIndex(of: c.windowId) ?? Int.max }
      let target = copies.dropFirst().reduce(copies[0]) { x, y in rank(y) < rank(x) ? y : x }
      if let swapped = swapPinPage(next, target.id) { next = swapped.state }
    }
    return next
  }
}
