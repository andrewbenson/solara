import SolaraModel

extension Session {
  func run(_ listener: SettleListener, prev: BrowserState) {
    switch listener {
    case .forgetClosedPrivateWindows: runForgetClosedPrivateWindows(prev)
    case .settleNesting: runSettleNesting(prev)
    case .livePinTable: runLivePinTable(prev)
    case .settlePeeks: runSettlePeeks(prev)
    case .mirror: runMirror(prev)
    case .noteOrderChoices: runNoteOrderChoices(prev)
    case .forgetClosedIncognito: runForgetClosedIncognito(prev)
    }
  }

  @inline(never)
  func runForgetClosedPrivateWindows(_ prev: BrowserState) {
    if state.windows.changed(from: prev.windows), let next = forgetClosedPrivateWindows(state) { set(next) }
  }

  @inline(never)
  func runSettleNesting(_ prev: BrowserState) {
    let s = state
    if !s.groups.changed(from: prev.groups) && s.windows.values.allSatisfy({ $0.tabIds == prev.windows[$0.id]?.tabIds }) { return }
    guard let settled = Groups.settleNesting(s) else { return }
    update {
      $0.groups = settled.groups
      $0.windows = settled.windows
    }
  }

  @inline(never)
  func runLivePinTable(_ prev: BrowserState) {
    let s = state
    if !s.pinChoices.changed(from: prev.pinChoices) && !s.pinSync.changed(from: prev.pinSync) && !s.tabs.changed(from: prev.tabs)
      && !s.groups.changed(from: prev.groups) && !s.parkedPins.changed(from: prev.parkedPins) && !s.profiles.changed(from: prev.profiles)
    {
      return
    }
    let pinChoices = livePinTable(s.pinChoices, s)
    let pinSync = livePinTable(s.pinSync, s)
    if pinChoices.changed(from: s.pinChoices) || pinSync.changed(from: s.pinSync) {
      update {
        $0.pinChoices = pinChoices
        $0.pinSync = pinSync
      }
    }
  }

  @inline(never)
  func runSettlePeeks(_ prev: BrowserState) {
    if let next = settlePeeks(state, prev) { set(next) }
  }

  @inline(never)
  func runMirror(_ prev: BrowserState) {
    if mirroring > 3 { return }
    guard let next = settledMirrors(state, prev) else { return }
    mirroring += 1
    defer { mirroring -= 1 }
    set(next)
  }

  @inline(never)
  func settledMirrors(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    let homes = settlePinHomes(s, prev)
    var start = s
    if let homes { start.tabs = homes }
    let unshared = unshareTabs(start, prev) ?? pagesIntoSplits(start, prev) ?? (homes != nil ? start : nil)
    let base = unshared ?? start
    let shared = settleSharedPins(base, prev) ?? unshared
    let settled = settleTileFolders(shared ?? base, prev) ?? shared
    let pinned = mirrorPins(settled ?? base, prev) ?? settled
    return mirrorTabs(pinned ?? base, prev) ?? pinned
  }

  @inline(never)
  func runNoteOrderChoices(_ prev: BrowserState) {
    if let next = noteOrderChoices(state, prev) { set(next) }
  }

  @inline(never)
  func runForgetClosedIncognito(_ prev: BrowserState) {
    let s = state
    if !s.windows.changed(from: prev.windows) { return }
    for w in prev.windows.values {
      if !w.incognito || s.windows[w.id] != nil { continue }
      guard let session = prev.privateSession(w.profileId) else { continue }
      if s.windows.values.contains(where: { $0.incognito && s.privateSession($0.profileId)?.jsEquals(session) == true }) { continue }
      if !config.nativePrivateSessionEffects {
        for d in s.downloads where downloadSession(s, d) == session && d.isDownloading { emit(.cancelDownload(id: d.id)) }
        forgetDownloads(w.profileId)
      }
      emit(.endPrivateSession(session: session))
    }
  }
}
