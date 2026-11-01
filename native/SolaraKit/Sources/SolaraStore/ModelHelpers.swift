import SolaraModel

public struct StoreMemory: Sendable, Equatable {
  public var ids: IdSource
  public var navSeq: Int = 0
  public var lastPinChoice: Double = 0
  public var remotePinDeletions: JSMap<Double> = JSMap()
  public var endedPrivateDownloads: Set<String> = []
  var privateSessionGenerations: [JSKey: String] = [:]
  public var closingWindows: Set<String> = []
  var closingWindowUndos: [String: ClosingWindowUndo] = [:]
  var hydrating = false
  public var lastTabKeepsWindow = false
  public var fromSyncDepth = 0
  var replicaProfilesAttached = false
  public var chromeTabs = ChromeTabsMemory()
  var pages: [String: PageReportMemory] = [:]
  var currentEpoch = 0
  var feedWatermark: [String: FeedWatermark] = [:]
  var pageProducerFence: [String: PageProducerFence] = [:]
  var nextPageModelSerial = 0

  public init(ids: IdSource = IdSource(launch: "x")) {
    self.ids = ids
  }
}

public let IDLE_PROFILE_COLORS = ["blue", "green", "orange", "purple", "red", "yellow", "pink"]

public extension BrowserState {
  func sharedDataId(_ profileId: String) -> String? {
    profiles[profileId]?.dataId
  }

  func engineProfile(_ profileId: String) -> String {
    if Ids.isIncognitoProfile(profileId) {
      let base = profileId.firstIndex(of: "@").map { String(profileId[..<$0]) } ?? profileId
      return "\(base)@\(engineProfile(Ids.incognitoOriginal(profileId)))"
    }
    let id = sharedDataId(profileId) ?? profileId
    return id == Settings.defaultProfileID ? "" : id
  }

  func privateSession(_ profileId: String) -> String? {
    Ids.isIncognitoProfile(profileId) ? engineProfile(Ids.incognitoOriginal(profileId)) : nil
  }

  func pinnedGroupMemberSet() -> Set<String> {
    var ids = Set<String>()
    for g in groups.values where g.pinned { ids.formUnion(g.tabIds) }
    return ids
  }

  func inPinnedContainer(_ id: String) -> Bool {
    guard let tab = tabs[id] else { return false }
    if tab.pinned { return true }
    for g in groups.values where g.pinned && g.tabIds.contains(id) { return true }
    return false
  }

  func viewTabIds(_ windowId: String, _ profileId: String? = nil) -> [String] {
    guard let w = windows[windowId] else { return [] }
    let profile = profileId ?? w.profileId
    return w.tabIds.filter { tabs[$0]?.profileId == profile }
  }

  func closesWindow(_ id: String) -> Bool {
    guard let tab = tabs[id], let w = windows[tab.windowId], tab.profileId == w.profileId, !inPinnedContainer(id) else { return false }
    return viewTabIds(w.id).allSatisfy { $0 == id || tabs[$0]!.unloaded == true }
  }

  func activeTabId(_ windowId: String, _ profileId: String? = nil) -> String? {
    guard let w = windows[windowId], let id = w.activeTabIds[profileId ?? w.profileId], tabs[id]?.windowId == windowId else { return nil }
    return id
  }

  func activeTab(_ windowId: String) -> Tab? {
    activeTabId(windowId).flatMap { tabs[$0] }
  }

  func resolveWindowId(_ id: String?) -> String? {
    if let id, windows[id] != nil { return id }
    let main = { (w: String) in windows[w].map { !$0.isSmall } ?? false }
    return ui.focusOrder.first(where: main) ?? windowOrder.first(where: main)
  }

  func bookmarkProfileId(_ window: BrowserWindow?) -> String {
    let id = window?.incognito == true ? window?.originalProfileId : window?.profileId
    if let id, profiles[id] != nil { return id }
    return settings.defaultProfileId
  }
}

public func pinnedFirst(_ ids: [String], _ tabs: Table<Tab>, _ groups: Table<TabGroup>? = nil) -> [String] {
  var pinnedGroup = Set<String>()
  if let groups { for g in groups.values where g.pinned { pinnedGroup.formUnion(g.tabIds) } }
  func section(_ id: String) -> PinSection { tabs[id]?.pinSection ?? .none }
  func pinnedArea(_ id: String) -> Bool { section(id) == .row || (!(tabs[id]?.pinned ?? false) && pinnedGroup.contains(id)) }
  return ids.filter { section($0) == .tile } + ids.filter(pinnedArea) + ids.filter { !(tabs[$0]?.pinned ?? false) && !pinnedArea($0) }
}

public func restoreId(_ tabId: String) -> String { "restore:\(tabId)" }

public func pendingRestore(_ t: Tab) -> String? {
  guard let wake = t.wakeAdoptId, wake.hasPrefix("restore:") else { return nil }
  return String(wake.dropFirst("restore:".count))
}

public func hasPage(_ t: Tab) -> Bool { t.navigation != nil || t.adoptId.map { !$0.isEmpty } == true }
public func hasLoadedPage(_ t: Tab) -> Bool { !t.url.isEmpty && hasPage(t) }
public func hasNavigatedPage(_ t: Tab) -> Bool { !t.url.isEmpty && t.navigation != nil }
public func hasOwnOrSharedPage(_ t: Tab) -> Bool { hasPage(t) || t.pageIn.map { !$0.isEmpty } == true }
public func isLazy(_ t: Tab) -> Bool { !t.url.isEmpty && !hasPage(t) }
public func needsPage(_ t: Tab) -> Bool { isLazy(t) && t.pageIn.map { !$0.isEmpty } != true }

public struct TabPatch: Sendable {
  public var url: String?
  public var title: String?
  public var favicon: String??
  public var pinned: Bool?
  public var muted: Bool?
  public var zoom: Double?
  public var customTitle: String??
  public var customIcon: String??
  public var profileId: String?
  public var pinnedUrl: String??
  public var pinnedAsRow: Bool??
  public var tileFolder: TileFolder??
  public var engine: String??
  public var extra: JSONObject = [:]
  public var undefined: Set<String> = []

  public init() {}

  public init(_ snap: TabSnapshot) {
    url = snap.url
    title = snap.title
    if !snap.absent.contains("favicon") || snap.undefined.contains("favicon") { favicon = .some(snap.favicon) }
    pinned = snap.pinned
    muted = snap.muted
    zoom = snap.zoom
    if !snap.absent.contains("customTitle") || snap.undefined.contains("customTitle") { customTitle = .some(snap.customTitle) }
    if !snap.absent.contains("customIcon") || snap.undefined.contains("customIcon") { customIcon = .some(snap.customIcon) }
    profileId = snap.profileId
    if snap.hasPinnedUrlKey || snap.undefined.contains("pinnedUrl") { pinnedUrl = .some(snap.pinnedUrl) }
    undefined = snap.undefined
    if let row = snap.pinnedAsRow { pinnedAsRow = .some(row) }
    if let folder = snap.tileFolder { tileFolder = .some(folder) }
    if let engine = snap.engine { self.engine = .some(engine) }
    extra = snap.extra
  }

  public func apply(to tab: inout Tab) {
    if let url { tab.url = url }
    if let title { tab.title = title }
    if let favicon { tab.favicon = favicon }
    if let pinned { tab.pinned = pinned }
    if let muted { tab.muted = muted }
    if let zoom { tab.zoom = zoom }
    if let customTitle { tab.customTitle = customTitle }
    if let customIcon { tab.customIcon = customIcon }
    if let profileId { tab.profileId = profileId }
    if let pinnedUrl { tab.pinnedUrl = pinnedUrl }
    if let pinnedAsRow { tab.pinnedAsRow = pinnedAsRow }
    if let tileFolder { tab.tileFolder = tileFolder }
    if let engine { tab.engine = engine }
    tab.overlay(extra)
    if !undefined.isEmpty { tab.markAbsent(undefined) }
  }
}

extension Session {
  public func makeTab(_ windowId: String, _ profileId: String, _ url: String = "", _ patch: TabPatch? = nil) -> Tab {
    var tab = Tab(id: newId("tab"), windowId: windowId, profileId: profileId, url: url, now: now)
    patch?.apply(to: &tab)
    tab.navigation = url.isEmpty ? nil : navigationTo(url)
    tab.createdAt = now
    tab.lastActiveAt = now
    return tab
  }

  public func wake(_ t: inout Tab) {
    if let adopt = t.wakeAdoptId, !adopt.isEmpty {
      t.adoptId = adopt
      t.wakeAdoptId = nil
      t.unloaded = nil
    } else {
      t.navigation = navigationTo(t.url)
      t.unloaded = nil
    }
  }
}

public func snapshotTab(_ t: Tab) -> TabSnapshot {
  var snap = TabSnapshot(
    url: t.url, title: t.title, favicon: t.favicon, pinned: t.pinned, muted: t.muted, zoom: t.zoom, customTitle: t.customTitle,
    customIcon: t.customIcon, profileId: t.profileId, pinnedUrl: t.pinnedUrl)
  snap.inheritAbsent(t.absent)
  if t.isPinnedRow { snap.pinnedAsRow = true }
  if let folder = t.tileFolder, t.pinSection == .tile { snap.tileFolder = folder }
  if let engine = t.engine, !engine.isEmpty { snap.engine = engine }
  return snap
}

public func samePage(_ a: String, _ b: String) -> Bool {
  func norm(_ u: String) -> String {
    var s = u.jsBeforeFirst("#")
    if s.hasSuffix("/") { s.removeLast() }
    return s
  }
  return norm(a) == norm(b)
}

public func awayFromPin(_ t: Tab) -> Bool {
  guard let pinned = t.pinnedUrl, !pinned.isEmpty, !t.url.isEmpty else { return false }
  return !samePage(t.url, pinned)
}

public func merge<T: Equatable>(_ value: T, _ change: (inout T) -> Void) -> T {
  var next = value
  change(&next)
  return next == value ? value : next
}

public func sameRef(_ a: BrowserState, _ b: BrowserState) -> Bool {
  a.profiles.version == b.profiles.version && a.windows.version == b.windows.version && a.tabs.version == b.tabs.version
    && a.groups.version == b.groups.version && a.splits.version == b.splits.version && a.peeks.version == b.peeks.version
    && a.parkedPins.version == b.parkedPins.version && a.pinChoices.version == b.pinChoices.version && a.pinSync.version == b.pinSync.version
    && a.profileOrder == b.profileOrder && a.windowOrder == b.windowOrder && a.ui == b.ui && a.closedTabs.count == b.closedTabs.count
    && a.closedTabs.last?.id == b.closedTabs.last?.id && a.closedWindows.count == b.closedWindows.count && a.closedGroups.count == b.closedGroups.count
    && a.deletedGroups.count == b.deletedGroups.count && a.cleanedTabs.count == b.cleanedTabs.count && a.settings == b.settings
}
