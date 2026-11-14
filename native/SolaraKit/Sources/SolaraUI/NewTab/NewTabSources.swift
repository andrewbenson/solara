import Foundation
import Observation
import SolaraEngine
import SolaraOmnibox

@MainActor
@Observable
public final class NewTabSources {
  public static let shared = NewTabSources()

  private struct IdleTabContext: Hashable {
    let windowId: [UInt16]
    let profileId: [UInt16]
    let excluding: [UInt16]?
  }

  struct Profile {
    var tabs: [TabRow] = []
    var history: [HistoryRow] = []
    var bookmarks: [BookmarkRow] = []
    var bookmarkIcons: [String: String] = [:]
    var bookmarkIconsByEngine: [String: [String: String]] = [:]
    var historyHosts: [String] = []
    var hosts: [String]? {
      didSet { scope = nil }
    }
    var scope: (engines: [SearchEngine], sources: ScopeSources)?
    var engineProfile: String?
    var bookmarkEngineProfile: String?
  }

  public private(set) var revision = 0
  @ObservationIgnored private var workspaceProfileIds: Set<String> = []
  @ObservationIgnored private var idleTabs = OmniboxIdleTabSources(tabs: [], peeks: [:], shared: false)
  @ObservationIgnored private var idleTabRows: [IdleTabContext: [Suggestion]] = [:]
  #if SOLARA_PROBES
  @ObservationIgnored private(set) var idleProjectionCount = 0
  #endif
  @ObservationIgnored private var profiles: [String: Profile] = [:]
  @ObservationIgnored private var actions: [String: ActionIndex<CommandAction>] = [:]
  @ObservationIgnored private var extensions: [String: [ExtensionCandidate]] = [:]
  @ObservationIgnored private(set) var worker = SuggestionWorker()
  @ObservationIgnored public var asynchronous = false
  @ObservationIgnored private var historyVersions: [String: Int] = [:]
  @ObservationIgnored private var historyObservers: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var historyCatalog: LibraryCatalog?
  @ObservationIgnored private var bookmarkCatalog: LibraryCatalog?
  @ObservationIgnored private var bookmarkObservers: [String: Task<Void, Never>] = [:]

  public init() {
    worker = SuggestionWorker { [weak self] _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.revision += 1 }
      }
    }
  }

  public func useHistoryCatalog(_ catalog: LibraryCatalog) {
    if let historyCatalog, historyCatalog === catalog { return }
    historyCatalog = catalog
    for (profileId, profile) in profiles {
      if let engineProfile = profile.engineProfile { observeHistory(profileId: profileId, engineProfile: engineProfile) }
    }
  }

  public func useBookmarkCatalog(_ catalog: LibraryCatalog) {
    if let bookmarkCatalog, bookmarkCatalog === catalog { return }
    bookmarkCatalog = catalog
    for (profileId, profile) in profiles {
      if let engineProfile = profile.bookmarkEngineProfile { observeBookmarks(profileId: profileId, engineProfile: engineProfile) }
    }
  }

  public func setEngineProfile(_ engineProfile: String, bookmarkEngineProfile: String? = nil, profileId: String) {
    var profile = profiles[profileId] ?? Profile()
    let bookmarkProfile = bookmarkEngineProfile ?? engineProfile
    let historyChanged = !OmniboxWorkspaceSources.rawStringsEqual(profile.engineProfile, engineProfile)
    let bookmarksChanged = !OmniboxWorkspaceSources.rawStringsEqual(profile.bookmarkEngineProfile, bookmarkProfile)
    guard historyChanged || bookmarksChanged else { return }
    profile.engineProfile = engineProfile
    profile.bookmarkEngineProfile = bookmarkProfile
    if bookmarksChanged { profile.bookmarkIcons = profile.bookmarkIconsByEngine[bookmarkProfile] ?? [:] }
    profiles[profileId] = profile
    if historyChanged { observeHistory(profileId: profileId, engineProfile: engineProfile) }
    if bookmarksChanged { observeBookmarks(profileId: profileId, engineProfile: bookmarkProfile) }
  }

  private func observeHistory(profileId: String, engineProfile: String) {
    historyObservers[profileId]?.cancel()
    guard let historyCatalog else {
      setHistory([], profileId: profileId, sameSource: false)
      return
    }
    applyHistory(historyCatalog.history(engineProfile: engineProfile), profileId: profileId, sameSource: false)
    historyObservers[profileId] = Task { [weak self] in
      for await snapshot in historyCatalog.observe(engineProfile: engineProfile) {
        guard !Task.isCancelled, self?.profiles[profileId]?.engineProfile == engineProfile else { return }
        self?.applyHistory(snapshot, profileId: profileId)
      }
    }
  }

  private func applyHistory(_ snapshot: HistorySnapshot, profileId: String, sameSource: Bool = true) {
    let rows = snapshot.ready ? snapshot.entries.map { entry in
      HistoryRow(url: entry.url, title: entry.title, favicon: nil, visits: Double(entry.visits), lastVisit: entry.lastVisit)
    } : []
    if profiles[profileId]?.history != rows { setHistory(rows, profileId: profileId, sameSource: sameSource) }
  }

  private func observeBookmarks(profileId: String, engineProfile: String) {
    bookmarkObservers[profileId]?.cancel()
    guard let bookmarkCatalog else {
      setBookmarks([], profileId: profileId, sameSource: false)
      return
    }
    applyBookmarks(bookmarkCatalog.bookmarks(engineProfile: engineProfile), profileId: profileId, sameSource: false)
    bookmarkObservers[profileId] = Task { [weak self] in
      for await snapshot in bookmarkCatalog.observeBookmarks(engineProfile: engineProfile) {
        guard !Task.isCancelled, self?.profiles[profileId]?.bookmarkEngineProfile == engineProfile else { return }
        self?.applyBookmarks(snapshot, profileId: profileId)
      }
    }
  }

  private func applyBookmarks(_ snapshot: BookmarkSnapshot, profileId: String, sameSource: Bool = true) {
    guard snapshot.ready, let roots = snapshot.roots else {
      if profiles[profileId]?.bookmarks != [] { setBookmarks([], profileId: profileId, sameSource: sameSource) }
      return
    }
    var seen = Set<String>()
    var urls = Set<String>()
    var rows: [BookmarkRow] = []
    func walk(_ id: String) {
      guard seen.insert(id).inserted, let node = snapshot.nodes[id] else { return }
      if node.isFolder {
        for child in node.children ?? [] { walk(child) }
      } else if let url = node.url, urls.insert(url).inserted {
        rows.append(BookmarkRow(url: url, title: node.title, favicon: profiles[profileId]?.bookmarkIcons[url]))
      }
    }
    walk(roots.bar)
    walk(roots.other)
    if profiles[profileId]?.bookmarks != rows { setBookmarks(rows, profileId: profileId, sameSource: sameSource) }
  }

  func bookmarks(_ profileId: String) -> [BookmarkRow] { profiles[profileId]?.bookmarks ?? [] }

  public func omniboxBenchSnapshot(profileId: String) -> [String: Any] {
    guard let profile = profiles[profileId] else { return ["sourceMode": "unpublished"] }
    return [
      "sourceMode": workspaceProfileIds.contains(profileId) ? "native-store" : "js-feed",
      "engineProfile": profile.engineProfile.map { $0 as Any } ?? NSNull(),
      "bookmarkEngineProfile": profile.bookmarkEngineProfile.map { $0 as Any } ?? NSNull(),
      "tabs": profile.tabs.count,
      "history": profile.history.count,
      "bookmarks": profile.bookmarks.count,
      "revision": revision,
    ]
  }

  public func setIdleTabs(_ projection: OmniboxIdleTabSources) {
    if replaceIdleTabs(projection) { revision += 1 }
  }

  private func replaceIdleTabs(_ projection: OmniboxIdleTabSources) -> Bool {
    guard idleTabs != projection else { return false }
    idleTabs = projection
    idleTabRows.removeAll(keepingCapacity: true)
    return true
  }

  public func activeTabId(windowId: String, profileId: String) -> String? {
    idleTabs.activeTabId(windowId: windowId, profileId: profileId)
  }

  public func openTabs(windowId: String, profileId: String, excluding: String?) -> [Suggestion] {
    _ = revision
    let context = IdleTabContext(windowId: Array(windowId.utf16), profileId: Array(profileId.utf16), excluding: excluding.map { Array($0.utf16) })
    if let cached = idleTabRows[context] { return cached }
    #if SOLARA_PROBES
    idleProjectionCount += 1
    #endif
    let rows = idleTabs.openTabs(windowId: windowId, profileId: profileId, excluding: excluding)
    idleTabRows[context] = rows
    return rows
  }

  public func applyWorkspace(_ workspace: OmniboxWorkspaceSources) {
    _ = replaceIdleTabs(workspace.idleTabs)
    let ids = Set(workspace.profiles.map(\.profileId))
    for profileId in Array(profiles.keys) where !ids.contains(profileId) { removeProfile(profileId) }
    workspaceProfileIds = ids
    for profile in workspace.profiles {
      setEngineProfile(profile.engineProfile, bookmarkEngineProfile: profile.bookmarkEngineProfile, profileId: profile.profileId)
      if !OmniboxWorkspaceSources.tabsEqual(profiles[profile.profileId]?.tabs ?? [], profile.tabs) {
        setTabs(profile.tabs, profileId: profile.profileId)
      }
    }
    revision += 1
  }

  public func resetWorkspace() {
    _ = replaceIdleTabs(OmniboxIdleTabSources(tabs: [], peeks: [:], shared: false))
    workspaceProfileIds = []
    for profileId in Array(profiles.keys) {
      let icons = profiles[profileId]?.bookmarkIconsByEngine ?? [:]
      removeProfile(profileId)
      var profile = Profile()
      profile.bookmarkIconsByEngine = icons
      profiles[profileId] = profile
    }
    revision += 1
  }

  private func removeProfile(_ profileId: String) {
    historyObservers.removeValue(forKey: profileId)?.cancel()
    bookmarkObservers.removeValue(forKey: profileId)?.cancel()
    historyVersions[profileId, default: 0] += 1
    worker.remove(profileId)
    profiles[profileId] = nil
  }

  public func setBookmarkIcons(_ icons: [String: String], engineProfile: String, profileId: String) {
    var profile = profiles[profileId] ?? Profile()
    profile.bookmarkIconsByEngine[engineProfile] = icons
    guard profile.bookmarkEngineProfile == engineProfile else {
      profiles[profileId] = profile
      return
    }
    guard profile.bookmarkIcons != icons else {
      profiles[profileId] = profile
      return
    }
    profile.bookmarkIcons = icons
    profiles[profileId] = profile
    if let bookmarkCatalog {
      applyBookmarks(bookmarkCatalog.bookmarks(engineProfile: engineProfile), profileId: profileId)
    }
  }


  public func setTabs(_ tabs: [TabRow], profileId: String) {
    var p = profiles[profileId] ?? Profile()
    p.tabs = tabs
    p.hosts = nil
    profiles[profileId] = p
    revision += 1
  }

  func setHistory(_ history: [HistoryRow], profileId: String, sameSource: Bool = true) {
    var p = profiles[profileId] ?? Profile()
    let serveOld = servesOldIndex(p, history: history, bookmarks: p.bookmarks, sameSource: sameSource)
    p.history = history
    historyVersions[profileId, default: 0] += 1
    if asynchronous {
      let version = historyVersions[profileId]
      DispatchQueue.global(qos: .utility).async { [weak self] in
        let hosts = NewTabSources.hosts(of: history)
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.publishHosts(hosts, profileId: profileId, version: version) }
        }
      }
    } else {
      p.historyHosts = Self.hosts(of: history)
      p.hosts = nil
    }
    profiles[profileId] = p
    worker.replace(profileId: profileId, history: history, bookmarks: p.bookmarks, serveOldUntilReady: serveOld)
    revision += 1
  }

  private func servesOldIndex(_ old: Profile, history: [HistoryRow], bookmarks: [BookmarkRow], sameSource: Bool) -> Bool {
    asynchronous && sameSource
      && old.history.isEmpty == history.isEmpty
      && old.bookmarks.isEmpty == bookmarks.isEmpty
      && !(history.isEmpty && bookmarks.isEmpty)
      && Self.onlyAdds(old.history.map(\.url), history.map(\.url))
      && Self.onlyAdds(old.bookmarks.map(\.url), bookmarks.map(\.url))
  }

  static func onlyAdds(_ old: [String], _ new: [String]) -> Bool {
    guard old.count <= new.count else { return false }
    let kept = Set(new)
    return old.allSatisfy(kept.contains)
  }

  nonisolated static func hosts(of history: [HistoryRow]) -> [String] {
    var seen = Set<String>()
    var hosts: [String] = []
    for h in history {
      let host = hostOf(h.url)
      if !host.isEmpty && seen.insert(host).inserted { hosts.append(host) }
    }
    return hosts
  }

  private func publishHosts(_ hosts: [String], profileId: String, version: Int?) {
    guard historyVersions[profileId] == version, var p = profiles[profileId], p.historyHosts != hosts else { return }
    p.historyHosts = hosts
    p.hosts = nil
    profiles[profileId] = p
    revision += 1
  }

  func history(_ profileId: String) -> [HistoryRow] { profiles[profileId]?.history ?? [] }

  public func setBookmarks(_ bookmarks: [BookmarkRow], profileId: String) {
    setBookmarks(bookmarks, profileId: profileId, sameSource: true)
  }

  func setBookmarks(_ bookmarks: [BookmarkRow], profileId: String, sameSource: Bool) {
    var p = profiles[profileId] ?? Profile()
    let serveOld = servesOldIndex(p, history: p.history, bookmarks: bookmarks, sameSource: sameSource)
    p.bookmarks = bookmarks
    profiles[profileId] = p
    worker.replace(profileId: profileId, history: p.history, bookmarks: bookmarks, serveOldUntilReady: serveOld)
    revision += 1
  }

  public func setActions(_ list: [CommandAction], windowId: String) {
    actions[windowId] = ActionIndex(list)
    revision += 1
  }

  public func setExtensions(_ list: [ExtensionCandidate], windowId: String) {
    extensions[windowId] = list
    revision += 1
  }

  public func forget(windowId: String) {
    actions[windowId] = nil
    extensions[windowId] = nil
  }

  func preparedIndex(_ profileId: String) -> Bool { worker.prepared(profileId) }

  func suggestNow(_ request: SuggestRequest) -> SuggestionResult { worker.suggestNow(request) }

  func tabs(_ profileId: String) -> [TabRow] { profiles[profileId]?.tabs ?? [] }

  func actions(_ windowId: String) -> ActionIndex<CommandAction>? { actions[windowId] }

  func extensions(_ windowId: String) -> [ExtensionCandidate] { extensions[windowId] ?? [] }

  func scopeSources(_ profileId: String, engines: [SearchEngine]) -> ScopeSources {
    if let cached = profiles[profileId]?.scope, cached.engines == engines { return cached.sources }
    let made = ScopeSources(engines: engines, hosts: knownHosts(profileId))
    if var p = profiles[profileId] {
      p.scope = (engines, made)
      profiles[profileId] = p
    }
    return made
  }

  func knownHosts(_ profileId: String) -> [String] {
    guard var p = profiles[profileId] else { return [] }
    if let hosts = p.hosts { return hosts }
    var hosts: [String] = []
    for t in p.tabs where !t.url.isEmpty { hosts.append(hostOf(t.url)) }
    hosts += p.historyHosts
    p.hosts = hosts
    profiles[profileId] = p
    return hosts
  }

}
