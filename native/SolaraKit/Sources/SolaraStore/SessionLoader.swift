import SolaraModel

extension Session {
  public func loadSessionData(_ session: JSONValue?, downloads: JSONValue?) -> HydrateData? {
    guard let session, session["version"] == .number(2), var object = session.object else { return nil }
    for key in ["launchTab", "launchBackdrop", "linkProfile", "nativeExport", "version"] { object.removeValue(forKey: key) }
    guard var data = try? HydrateData(json: object) else { return nil }
    data.orphanedProfileData = data.orphanedProfileData ?? []
    data.lastProfileId = data.lastProfileId ?? nil
    data.tabs = data.tabs ?? []
    data.groups = data.groups ?? JSMap()
    data.splits = data.splits ?? JSMap()
    data.parkedPins = data.parkedPins ?? JSMap()
    data.pinChoices = data.pinChoices ?? JSMap()
    data.pinSync = data.pinSync ?? JSMap()
    data.closedGroups = data.closedGroups ?? []
    data.deletedGroups = data.deletedGroups ?? []
    data.cleanedTabs = data.cleanedTabs ?? []
    let saved = (downloads?["downloads"]?.array ?? []).compactMap { $0.object.map(Download.init) }.filter { !$0.isPrivate }
    data.downloads = saved.enumerated().map { $0.element.loaded(at: $0.offset) }
    if session["settings"]?["restoreSession"] == .bool(false) {
      var tabsById = JSMap<Tab>()
      for t in data.tabs ?? [] { tabsById[t.id] = t }
      var pinSource = BrowserState()
      pinSource.tabs = Table(tabsById)
      pinSource.groups = Table(data.groups ?? JSMap())
      pinSource.splits = Table(data.splits ?? JSMap())
      pinSource.windows = Table()
      let rawWindows = (session["windows"]?.array ?? []).compactMap { try? BrowserWindow(value: $0) }
      let keptIds = Set(rawWindows.filter { $0.keptOnClose == true && !$0.incognito && !$0.isSmall }.map(\.id))
      let closing = rawWindows.filter { !keptIds.contains($0.id) }
      pinSource.windows = Table((data.windows ?? JSMap()).filter { id, _ in keptIds.contains(id) })
      var parked = Table(data.parkedPins ?? JSMap())
      for w in closing { parked = parkWindowPins(parked, w, pinSource, history: false) }
      data.parkedPins = parked.map
      var closed = data.closedWindows ?? []
      for w in closing {
        let active = Set(w.activeTabIds.values)
        let tabs = w.tabIds.compactMap { tabsById[$0] }.filter { !pinSource.inPinnedContainer($0.id) }.map {
          ClosedWindowTab(snapshot: snapshotTab($0), active: active.contains($0.id), tabId: nil)
        }
        var entry = ClosedWindow(id: newId("cw"), profileId: w.profileId, sidebarOpen: w.sidebarOpen, frame: w.frame, tabs: tabs, groups: [], closedAt: now)
        entry.keepPresentation(of: w)
        entry.absent = w.absent.intersection(["frame"])
        if tabs.contains(where: { !$0.snapshot.url.isEmpty }) { closed.append(entry) }
      }
      data.closedWindows = Array(closed.suffix(10))
      data.windows = data.windows?.filter { id, _ in keptIds.contains(id) }
      data.windowOrder = data.windowOrder?.filter { keptIds.contains($0) }
      data.tabs = data.tabs?.filter { keptIds.contains($0.windowId) }
      data.groups = data.groups?.filter { _, group in keptIds.contains(group.windowId) }
      data.splits = data.splits?.filter { _, split in keptIds.contains(split.windowId) }
    }
    data.windows = data.windows?.mapValues { window in
      var shown = window
      shown.keptOnClose = nil
      return shown
    }
    return data
  }

  public func loadSession(_ session: JSONValue?, downloads: JSONValue?) -> BrowserState {
    hydrate(loadSessionData(session, downloads: downloads) ?? HydrateData())
    return state
  }
}
