import SolaraModel

func familyKey(_ t: Tab) -> String { "\(t.profileId)\u{1}\(t.pinKeyOrId)" }

func sharesTabs(_ s: BrowserState) -> Bool { s.settings.bool("shareTabsAcrossWindows") }

func listable(_ t: Tab) -> Bool { !t.pinned && !t.url.isEmpty && t.liveItem == nil }

func listGroupsOf(_ s: BrowserState) -> [TabGroup] { s.groups.values.filter { !$0.pinned } }

func swapIn(_ ids: [String], _ a: String, _ b: String) -> [String]? {
  guard ids.contains(a) || ids.contains(b) else { return nil }
  return ids.map { $0 == a ? b : $0 == b ? a : $0 }
}

extension Session {
  func sharedListTab(_ s: BrowserState, _ t: Tab) -> Bool {
    sharesTabs(s) && listable(t) && mirrored(s.windows[t.windowId]) && !s.inPinnedContainer(t.id) && s.peeks[t.windowId]?.tabId != t.id
  }

  func listMember(_ s: BrowserState) -> (Tab) -> Bool {
    let pinnedMembers = Set(s.groups.values.filter(\.pinned).flatMap(\.tabIds))
    let inSplit = Set(s.splits.values.flatMap(\.tabIds))
    return { t in listable(t) && !pinnedMembers.contains(t.id) && !inSplit.contains(t.id) && s.peeks[t.windowId]?.tabId != t.id }
  }

  func listSection(_ s: BrowserState, _ windowId: String, _ profileId: String, member: ((Tab) -> Bool)? = nil, groups: [TabGroup]? = nil) -> Section {
    sectionOf(s, s.windows[windowId]!, profileId, groups ?? listGroupsOf(s), member: member ?? listMember(s))
  }

  func listMayDiffer(_ s: BrowserState, _ prev: BrowserState) -> Bool {
    if s.windows.changed(from: prev.windows) || s.groups.changed(from: prev.groups) || s.splits.changed(from: prev.splits)
      || s.peeks.changed(from: prev.peeks)
    {
      return true
    }
    if !s.tabs.changed(from: prev.tabs) { return false }
    for id in s.tabs.changedIds(from: prev.tabs) {
      guard let a = s.tabs[id], let b = prev.tabs[id] else { return true }
      if a.pinned != b.pinned || a.profileId != b.profileId || a.windowId != b.windowId || a.pinKey != b.pinKey || a.customTitle != b.customTitle
        || a.customIcon != b.customIcon || a.liveItem != b.liveItem || a.pageIn != b.pageIn || hasPage(a) != hasPage(b)
        || a.url.isEmpty != b.url.isEmpty || a.absenceDiffers(from: b, in: ["customTitle", "customIcon"])
      {
        return true
      }
    }
    return false
  }

  func swapPlaces(_ s: BrowserState, _ a: String, _ b: String) -> BrowserState {
    let ta = s.tabs[a]!
    let tb = s.tabs[b]!
    let key = ta.pinKeyOrId
    let moved = ta.windowId != tb.windowId
    var next = s
    for id in OrderedSet([ta.windowId, tb.windowId]) {
      var w = next.windows[id]!
      if moved { w.activeTabIds = w.activeTabIds.mapValues { $0 == a ? b : $0 == b ? a : $0 } }
      if let swapped = swapIn(w.tabIds, a, b) { w.tabIds = swapped }
      next.windows[id] = w
    }
    next.windows.touch()
    func slot(_ t: inout Tab, from o: Tab) {
      t.windowId = o.windowId
      t.pinned = o.pinned
      t.pinnedUrl = o.pinnedUrl
      t.pinnedAsRow = o.pinnedAsRow
      t.tileFolder = o.tileFolder
    }
    var na = ta
    slot(&na, from: tb)
    keyField(&na, key)
    if moved, let navigation = ta.navigation {
      var nav = navigation
      nav.url = ta.url.isEmpty ? navigation.url : ta.url
      na.navigation = nav
    }
    var nb = tb
    slot(&nb, from: ta)
    keyField(&nb, key)
    next.tabs[a] = na
    next.tabs[b] = nb
    if moved {
      for id in OrderedSet([ta.windowId, tb.windowId]) {
        guard let before = s.windows[id], let after = next.windows[id], let shown = after.activeTabIds[after.profileId],
          shown == a || shown == b, before.activeTabIds[before.profileId] != shown, var t = next.tabs[shown] else { continue }
        t.shownAt = now
        next.tabs[shown] = t
      }
    }
    for (id, g) in s.groups {
      if let swapped = swapIn(g.tabIds, a, b) {
        var changed = g
        changed.tabIds = swapped
        next.groups[id] = changed
      }
    }
    for (id, v) in s.splits {
      if let swapped = swapIn(v.tabIds, a, b) {
        var changed = v
        changed.tabIds = swapped
        next.splits[id] = changed
      }
    }
    return next
  }

  func pagesIntoSplits(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    if !sharesTabs(s) || !s.splits.changed(from: prev.splits) { return nil }
    func inSplit(_ st: BrowserState, _ id: String) -> Bool { st.splits.values.contains { $0.tabIds.contains(id) } }
    var next = s
    var changed = false
    for v in s.splits.values {
      for id in v.tabIds {
        guard let t = next.tabs[id], let pageIn = t.pageIn, !pageIn.isEmpty, !hasPage(t) else { continue }
        let was = prev.tabs[id]
        if !(sharedListTab(next, t) || (was.map { sharedListTab(prev, $0) } ?? false)) { continue }
        guard let holder = next.tabs[pageIn], !holder.pinned, hasPage(holder), !truthy(holder.pageIn), holder.windowId != t.windowId,
          holder.profileId == t.profileId, holder.pinKeyOrId == t.pinKeyOrId, !inSplit(next, holder.id)
        else { continue }
        next = swapPlaces(next, holder.id, t.id)
        next = removeTabs(keepShownProfile(next, holder.windowId, [t.id]), [t.id], record: false)
        changed = true
      }
    }
    return changed ? next : nil
  }

  func keepLeavingPages(_ s: BrowserState, _ windowId: String, _ profileId: String, _ spec: Section, _ sourceId: String?) -> BrowserState {
    let wanted = Set(spec.items.map(\.tab.pinKeyOrId))
    let section = listSection(s, windowId, profileId)
    let inList = Set(section.items.map(\.tab.id))
    var next = s
    for item in section.items {
      let t = item.tab
      if !hasPage(t) || truthy(t.pageIn) || wanted.contains(t.pinKeyOrId) { continue }
      let key = t.pinKeyOrId
      func pageless(_ id: String?) -> Tab? {
        guard let id, let w = next.windows[id] else { return nil }
        return w.tabIds.compactMap { next.tabs[$0] }.first { u in
          u.id != t.id && !inList.contains(u.id) && u.profileId == t.profileId && u.pinKeyOrId == key && !hasPage(u)
        }
      }
      let place = pageless(windowId) ?? (sourceId != windowId ? pageless(sourceId) : nil)
      if let place { next = swapPlaces(next, t.id, place.id) }
    }
    return next
  }

  func conformList(_ input: BrowserState, _ windowId: String, _ profileId: String, _ spec: Section, _ leaving: String, _ sourceId: String? = nil)
    -> BrowserState
  {
    let s = leaving == "close" ? keepLeavingPages(input, windowId, profileId, spec, sourceId) : input
    let w = s.windows[windowId]!
    let cur = listSection(s, windowId, profileId)
    let mine = cur.items.map(\.tab)
    var used = Set<String>()
    var tabs = s.tabs
    tabs.touch()
    var groups = s.groups
    groups.touch()
    var byKey = OrderedDict<String, [Tab]>()
    for m in mine { byKey[m.pinKeyOrId, default: []].append(m) }
    func reuse(_ src: Tab) -> String {
      let key = src.pinKeyOrId
      let same = (byKey[key] ?? []).filter { !used.contains($0.id) }
      guard let t = same.first(where: hasPage) ?? same.first else {
        var copy = copyOf(src, windowId, false)
        copy.unloaded = nil
        copy.lastActiveAt = src.lastActiveAt
        tabs[copy.id] = copy
        used.insert(copy.id)
        return copy.id
      }
      used.insert(t.id)
      var u = t
      keyField(&u, key)
      u.takeCustomLook(from: src)
      if !hasOwnOrSharedPage(t) {
        u.url = src.url
        u.title = src.title
        u.takeFavicon(from: src)
      }
      if u.pinKey != t.pinKey || u.customTitle != t.customTitle || u.customIcon != t.customIcon || u.url != t.url || u.title != t.title
        || u.favicon != t.favicon || u.absenceDiffers(from: t, in: ["customTitle", "customIcon", "favicon"])
      {
        tabs[t.id] = u
      }
      return t.id
    }
    let order = treeOrder(spec)
    let placed = order.map { reuse($0.tab) }
    var within = OrderedDict<String, [String]>()
    for (n, i) in order.enumerated() { for key in chainOf(spec, i.group) { within[key, default: []].append(placed[n]) } }
    let out = mine.filter { !used.contains($0.id) }
    let demoted = Set(leaving == "keepPages" ? out.filter(hasPage).map(\.id) : [])
    let gone = out.filter { !demoted.contains($0.id) }.map(\.id)
    let goneSet = Set(gone)
    for id in out.map(\.id) where demoted.contains(id) {
      var t = tabs[id]!
      t.pinKey = nil
      tabs[id] = t
    }
    let section = Set(mine.filter { !demoted.contains($0.id) }.map(\.id))
    let kept = Set(placed)
    var followers = OrderedDict<String?, [String]>()
    var anchor: String? = nil
    for id in w.tabIds {
      if section.contains(id) && kept.contains(id) { anchor = id }
      if section.contains(id) && !goneSet.contains(id) { continue }
      followers[anchor, default: []].append(id)
    }
    var ids = followers[nil] ?? []
    for id in placed {
      ids.append(id)
      ids.append(contentsOf: followers[id] ?? [])
    }
    var usedGroups = Set<String>()
    var groupIdOf: [String: String] = [:]
    for (key, members) in within {
      let entry = spec.groups[key]!
      let src = entry.group
      let own = cur.own.first { !usedGroups.contains($0.id) && $0.pinKeyOrId == key }
      let id = own?.id ?? newId("g")
      usedGroups.insert(id)
      groupIdOf[key] = id
      let outside = own.map { o in o.tabIds.filter { !section.contains($0) && ids.contains($0) } } ?? []
      var base: TabGroup
      if let own {
        base = own
      } else {
        base = TabGroup(
          id: id, windowId: windowId, profileId: profileId, name: "", icon: nil, color: nil, collapsed: src.collapsed, pinned: false, tabIds: [],
          createdAt: now)
        if src.autoUngroup == true { base.autoUngroup = true }
      }
      keyField(&base, key)
      base.name = src.name
      base.setLook(icon: src.icon, color: src.color, absent: src.absent)
      base.pinned = false
      base.tabIds = members + outside
      groups[id] = Groups.withParent(base, entry.parent.flatMap { groupIdOf[$0] })
    }
    for g in cur.own where !usedGroups.contains(g.id) {
      let left = g.tabIds.filter { (!section.contains($0) || demoted.contains($0)) && ids.contains($0) }
      if !left.isEmpty {
        var changed = g
        changed.pinKey = nil
        changed.tabIds = left
        groups[g.id] = changed
      } else {
        groups.remove([g.id])
      }
    }
    for g in cur.own {
      if let current = groups[g.id], let parent = current.parentId, groups[parent] == nil { groups[g.id] = Groups.withParent(current, nil) }
    }
    var window = w
    window.tabIds = Groups.orderSections(pinnedFirst(ids, tabs, groups), tabs, groups)
    groups = Groups.syncGroupOrder(groups, window)
    var next = s
    next.tabs = tabs
    next.groups = groups
    next.windows[windowId] = window
    if gone.isEmpty { return next }
    return removeTabs(keepShownProfile(next, windowId, gone), gone, record: false)
  }

  func keepShownProfile(_ s: BrowserState, _ windowId: String, _ gone: [String]) -> BrowserState {
    guard let w = s.windows[windowId], w.tabIds.contains(where: { gone.contains($0) }) else { return s }
    let shownHere = w.tabIds.filter { s.tabs[$0]?.profileId == w.profileId && !gone.contains($0) }
    if w.tabIds.contains(where: { !gone.contains($0) }) && shownHere.contains(where: { s.tabs[$0]!.unloaded != true }) { return s }
    var o = NewTabOptions()
    o.profileId = w.profileId
    o.background = true
    return withNewTab(s, windowId, o).0
  }

  func linkCopies(_ s: BrowserState, _ byProfile: OrderedDict<String, [String]>) -> BrowserState? {
    let member = listMember(s)
    let groups = listGroupsOf(s)
    var holders = OrderedDict<String, Tab>()
    var copies: [Tab] = []
    var asleep: [Tab] = []
    for (profileId, ids) in byProfile {
      for id in ids {
        if s.windows[id] == nil { continue }
        for item in listSection(s, id, profileId, member: member, groups: groups).items {
          let tab = item.tab
          if tab.unloaded == true { asleep.append(tab) }
          if ids.count < 2 { continue }
          if hasPage(tab) && !truthy(tab.pageIn) {
            let was = holders[familyKey(tab)]
            if was == nil || tab.lastActiveAt > was!.lastActiveAt { holders[familyKey(tab)] = tab }
          } else if !hasOwnOrSharedPage(tab) {
            copies.append(tab)
          }
        }
      }
    }
    var tabs = s.tabs
    var changed = false
    for t in asleep {
      var rest = t
      rest.unloaded = nil
      tabs[t.id] = rest
      changed = true
    }
    for c in copies {
      guard let holder = holders[familyKey(c)], holder.windowId != c.windowId else { continue }
      var t = tabs[c.id]!
      t.url = holder.url
      t.title = holder.title
      t.takeFavicon(from: holder)
      t.muted = holder.muted
      t.pageIn = holder.id
      tabs[c.id] = t
      changed = true
    }
    guard changed else { return nil }
    var next = s
    next.tabs = tabs
    return next
  }

  func mirrorTabs(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    if !sharesTabs(s) { return nil }
    let turnedOn = !sharesTabs(prev)
    if !turnedOn && !listMayDiffer(s, prev) { return nil }
    let order = OrderedSet(s.ui.focusOrder + s.windowOrder).elements.filter { mirrored(s.windows[$0]) }
    var byProfile = OrderedDict<String, [String]>()
    for id in order { for p in profilesOf(s, s.windows[id]!) { byProfile[p, default: []].append(id) } }
    var next = s
    var changed = false
    for (profileId, ids) in byProfile {
      for id in ids where next.windows[id] != nil {
        let x = listSection(next, id, profileId)
        if hasDuplicates(x) {
          next = conformList(next, id, profileId, union([x], samePages: false), "keepPages")
          changed = true
        }
      }
    }
    for (profileId, ids) in byProfile {
      if ids.count < 2 { continue }
      let member = listMember(next)
      let groups = listGroupsOf(next)
      var sections: [String: Section] = [:]
      for id in ids where next.windows[id] != nil { sections[id] = listSection(next, id, profileId, member: member, groups: groups) }
      var sigs: [String: String] = [:]
      for (id, x) in sections { sigs[id] = signature(x) }
      if Set(ids.map { sigs[$0] ?? "" }).count == 1 { continue }
      let before = turnedOn ? [] : ids.filter { id in mirrored(prev.windows[id]) && profilesOf(prev, prev.windows[id]!).contains(profileId) }
      let prevMember = listMember(prev)
      let prevGroups = listGroupsOf(prev)
      let source = before.first { id in signature(listSection(prev, id, profileId, member: prevMember, groups: prevGroups)) != sigs[id] }
      let merged = turnedOn ? ids.stableSorted { s.windowOrder.jsIndexOf($0) < s.windowOrder.jsIndexOf($1) } : before + ids.filter { !before.contains($0) }
      let spec = source.map { sections[$0]! } ?? union(merged.compactMap { sections[$0] }, samePages: false)
      let want = source.map { sigs[$0]! }
      for id in ids {
        if id == source || (want != nil && sigs[id] == want) || next.windows[id] == nil { continue }
        next = conformList(next, id, profileId, spec, source != nil ? "close" : "keepPages", source)
        changed = true
      }
    }
    if let linked = linkCopies(next, byProfile) {
      next = linked
      changed = true
    }
    return changed ? next : nil
  }

  func unshareTabs(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    if sharesTabs(s) || !sharesTabs(prev) { return nil }
    let member = listMember(s)
    var rank: [String: Int] = [:]
    for (i, id) in OrderedSet(s.ui.focusOrder + s.windowOrder).elements.enumerated() { rank[id] = i }
    var families = OrderedDict<String, [Tab]>()
    for t in s.tabs.values where mirrored(s.windows[t.windowId]) && member(t) { families[familyKey(t), default: []].append(t) }
    var gone: [String] = []
    var tabs = s.tabs
    tabs.touch()
    for family in families.values {
      func at(_ t: Tab) -> Int { rank[t.windowId] ?? Int.max }
      let keeper = family.first { hasPage($0) && !truthy($0.pageIn) } ?? family.dropFirst().reduce(family[0]) { x, y in at(y) < at(x) ? y : x }
      for t in family {
        if t.id != keeper.id {
          gone.append(t.id)
        } else if truthy(t.pinKey) || truthy(t.pageIn) {
          var rest = t
          rest.pageIn = nil
          rest.pinKey = nil
          tabs[t.id] = rest
        }
      }
    }
    var groups = s.groups
    groups.touch()
    for g in listGroupsOf(s) where truthy(g.pinKey) {
      var changed = g
      changed.pinKey = nil
      groups[g.id] = changed
    }
    var next = s
    next.tabs = tabs
    next.groups = groups
    for w in s.windows.values { next = keepShownProfile(next, w.id, gone) }
    return gone.isEmpty ? next : removeTabs(next, gone, record: false)
  }

  func sharedElsewhere(_ s: BrowserState, _ t: Tab) -> Bool {
    if !sharedListTab(s, t) { return false }
    let key = t.pinKeyOrId
    return s.tabs.values.contains { x in
      x.id != t.id && x.windowId != t.windowId && x.profileId == t.profileId && x.pinKeyOrId == key && mirrored(s.windows[x.windowId])
    }
  }

  func sharedLastUsed(_ s: BrowserState) -> [String: Double]? {
    if !sharesTabs(s) { return nil }
    let member = listMember(s)
    var out: [String: Double] = [:]
    for t in s.tabs.values where mirrored(s.windows[t.windowId]) && member(t) {
      out[familyKey(t)] = max(out[familyKey(t)] ?? 0, t.lastActiveAt)
    }
    return out
  }

  func lastUsedOf(_ used: [String: Double]?, _ t: Tab) -> Double { used?[familyKey(t)] ?? t.lastActiveAt }
}
