import AppKit
import SolaraLive
import SolaraModel
import SolaraStore

public struct SidebarLive: Sendable, Equatable {
  public var state: LiveState
  public var openFooters: Set<String> = []
  public var foldedAway: Set<String> = []
  public var now: Double = Date().timeIntervalSince1970 * 1000

  public init(state: LiveState) {
    self.state = state
  }

  public static let prefix = "lf:"
  public static let completedWindow: Double = 24 * 3_600_000

  public static func decode(_ text: String) -> LiveState? {
    guard var state = try? LiveJSON.decode(LiveState.self, from: text) else { return nil }
    if let session = try? LiveJSON.decode(Session.self, from: text) {
      state.completing = session.completing ?? [:]
      state.status = session.status ?? [:]
      state.showAll = session.showAll ?? [:]
    }
    return state
  }

  struct Session: Decodable {
    var completing: [String: [String]]?
    var status: [String: FolderStatus]?
    var showAll: [String: Bool]?
  }

  func folders(profileId: String) -> [LiveFolder] {
    state.folderOrder.compactMap { state.folders[$0] }.filter { $0.profileId == profileId }
  }

  public func sequence(_ pinned: [String], state browser: BrowserState, windowId: String, profileId: String) -> [String] {
    if browser.windows[windowId]?.incognito == true { return pinned }
    let mine = folders(profileId: profileId)
    if mine.isEmpty { return pinned }
    let keys = pinned.map { Self.anchorKey(browser, $0) }
    let known = Set(keys)
    func at(_ after: String?) -> [String] {
      mine.filter { if case .some(let a) = $0.after { a == after } else { false } }.map { Self.prefix + $0.id }
    }
    var out = at(nil)
    for (i, entry) in pinned.enumerated() {
      out.append(entry)
      out.append(contentsOf: at(keys[i]))
    }
    for f in mine {
      switch f.after {
      case .none: out.append(Self.prefix + f.id)
      case .some(.some(let after)) where !known.contains(after): out.append(Self.prefix + f.id)
      default: break
      }
    }
    return out
  }

  static func anchorKey(_ s: BrowserState, _ entry: String) -> String {
    let id = String(entry.dropFirst(2))
    if entry.hasPrefix("s:") {
      let panes = s.splits[id]?.tabIds ?? []
      let windowTabs = s.windows[s.splits[id]?.windowId ?? ""]?.tabIds ?? []
      let last = windowTabs.last { panes.contains($0) }
      return "t:\(last.flatMap { s.tabs[$0]?.pinKeyOrId } ?? id)"
    }
    if entry.hasPrefix("g:") { return "g:\(s.groups[id]?.pinKeyOrId ?? id)" }
    return "\(entry.prefix(2))\(s.tabs[id]?.pinKeyOrId ?? id)"
  }

  static func liveRef(_ tab: Tab) -> (folderId: String, itemId: String)? {
    guard let ref = tab.liveItem, let folderId = ref["folderId"]?.string, let itemId = ref["itemId"]?.string else { return nil }
    return (folderId, itemId)
  }

  public func block(_ folderId: String, browser: BrowserState, windowId: String, profileId: String) -> SidebarLiveBlock? {
    guard let folder = state.folders[folderId] else { return nil }
    let items = state.items[folderId] ?? []
    let shown = Set(items.map(\.id))
    let hidden = Set((state.hidden[folderId] ?? []).map(\.id))
    let profile = profileId
    let grouped = browser.groupedTabIds(windowId)
    let viewTabs = (browser.windows[windowId]?.tabIds ?? []).filter { browser.tabs[$0]?.profileId == profile && !grouped.contains($0) }
    var tabOfItem: [String: String] = [:]
    var strays: [String] = []
    for id in viewTabs {
      guard let tab = browser.tabs[id], let ref = Self.liveRef(tab), ref.folderId == folderId else { continue }
      if tabOfItem[ref.itemId] == nil { tabOfItem[ref.itemId] = id }
      if LiveRows.liveTabPlace(ref.itemId, shown: shown, hidden: hidden) == .stray { strays.append(id) }
    }
    var activeTab: String?
    var activeItem: String?
    if let window = browser.windows[windowId], let id = window.activeTabIds[profile], !grouped.contains(id), let tab = browser.tabs[id], tab.windowId == windowId,
      let ref = Self.liveRef(tab), ref.folderId == folderId, LiveRows.liveTabPlace(ref.itemId, shown: shown, hidden: hidden) != .hidden
    {
      activeTab = id
      activeItem = ref.itemId
    }
    let unread = Set(state.unread[folderId] ?? [])
    let completing = state.completing[folderId] ?? []
    let completed = completedShown(folder)
    let rows = LiveRows.folderRows(folder, items: items, showAll: state.showAll)
    let M = SidebarLiveMetrics.self
    let base = "li:\(folderId)|"

    func itemRow(_ item: LiveItem, inStack: Bool) -> SidebarLiveRow? {
      let completion = completing.contains(item.id) ? (state.completed[folderId]?.first { $0.item.id == item.id }?.state ?? .merged) : nil
      let tabId = tabOfItem[item.id]
      let folded = foldedAway.contains("\(folderId)|\(item.id)")
      return SidebarLiveRow(
        key: M.itemKey(folderId, item.id), height: folded ? 0 : M.itemHeight,
        kind: .item(SidebarLiveItemSpec(
          folderId: folderId, item: item, inStack: inStack, tabId: tabId, active: tabId != nil && tabId == activeTab, unread: unread.contains(item.id),
          completion: completion, folded: folded)))
    }

    var entries: [SidebarLiveEntry] = []
    for row in rows {
      switch row {
      case .header(let key, let title):
        entries.append(SidebarLiveEntry(rows: [SidebarLiveRow(key: base + key, height: M.sectionHeight, kind: .section(title))]))
      case .more(let key, let section, let count):
        entries.append(SidebarLiveEntry(rows: [SidebarLiveRow(key: base + key, height: M.moreHeight, kind: .more(folderId: folderId, section: section, count: count))]))
      case .item(_, let item):
        if let r = itemRow(item, inStack: false) { entries.append(SidebarLiveEntry(rows: [r])) }
      case .stack(_, let id, let repo, let members):
        let collapsed = state.expandedStacks[id] == false
        var list = [SidebarLiveRow(key: base + "k:\(id)", height: M.stackHeight, kind: .stack(folderId: folderId, id: id, repo: repo, count: members.count, collapsed: collapsed))]
        let holds = activeTab != nil && members.contains { $0.id == activeItem }
        if !collapsed {
          var first = true
          for item in members {
            guard var r = itemRow(item, inStack: true) else { continue }
            r.gapBefore = first ? M.stackPadTop : M.gap
            first = false
            list.append(r)
          }
        }
        entries.append(SidebarLiveEntry(rows: list, holds: holds))
      }
    }
    if entries.isEmpty {
      entries.append(SidebarLiveEntry(rows: [SidebarLiveRow(key: base + "note", height: M.noteHeight, kind: .note(note(folder)))]))
    }
    for id in strays {
      entries.append(SidebarLiveEntry(rows: [SidebarLiveRow(key: "t:\(id)", height: M.itemHeight, kind: .stray(id))], holds: id == activeTab))
    }
    if !completed.isEmpty {
      let open = openFooters.contains(folderId)
      var list = [SidebarLiveRow(key: base + "done", height: M.footerHeight, kind: .footer(folderId: folderId, count: completed.count, open: open))]
      if open {
        for c in completed.prefix(M.footerItems) {
          var r = SidebarLiveRow(key: base + "c:\(c.item.id)", height: M.completedHeight, kind: .completed(folderId: folderId, done: c))
          r.gapBefore = M.gap
          list.append(r)
        }
      }
      entries.append(SidebarLiveEntry(rows: list))
    }
    for i in entries.indices where !entries[i].holds {
      entries[i].holds = entries[i].rows.contains { if case .item(let spec) = $0.kind { spec.item.id == activeItem && activeTab != nil } else { false } }
    }
    let collapsed = folder.collapsed
    let kept = activeTab == nil ? nil : entries.firstIndex { $0.holds }
    let shownEntries = collapsed ? kept.map { [entries[$0]] } ?? [] : entries
    let header = SidebarLiveHeaderSpec(
      folder: folder, count: items.count, unread: !unread.isEmpty, status: state.status[folderId], hidden: state.hidden[folderId]?.count ?? 0,
      collapsed: collapsed, statusText: statusText(folderId))
    return SidebarLiveBlock(folderId: folderId, header: header, entries: shownEntries)
  }

  func completedShown(_ folder: LiveFolder) -> [CompletedItem] {
    guard folder.showCompleted else { return [] }
    let completing = state.completing[folder.id] ?? []
    return (state.completed[folder.id] ?? []).filter { now - $0.at < Self.completedWindow && !completing.contains($0.item.id) }
  }

  func note(_ folder: LiveFolder) -> SidebarLiveNote {
    let status = state.status[folder.id]
    let hidden = state.hidden[folder.id]?.count ?? 0
    guard let status, status.state != .initializing, !(status.state == .updating && (status.lastFetch ?? 0) == 0) else {
      return SidebarLiveNote(text: "Loading…", style: .loading, action: nil)
    }
    if let error = status.error {
      return SidebarLiveNote(text: LiveEngine.errorText(error.kind, source: error.source), style: .warning, action: "settings")
    }
    if hidden > 0 { return SidebarLiveNote(text: "\(hidden) hidden until you refresh", style: .plain, action: "refresh") }
    return SidebarLiveNote(text: folder.kind == .pullRequests ? "No open pull requests" : "No recent documents", style: .plain, action: nil)
  }

  func statusText(_ folderId: String) -> String {
    let hidden = state.hidden[folderId]?.count ?? 0
    let fetch: String
    if let st = state.status[folderId], st.state != .initializing {
      if st.state == .updating {
        fetch = "Updating…"
      } else if let error = st.error {
        fetch = LiveEngine.errorText(error.kind, source: error.source)
      } else if let last = st.lastFetch, last != 0 {
        let min = Int(((now - last) / 60_000).rounded(.down))
        fetch = min < 1 ? "Updated just now" : min < 60 ? "Updated \(min) min ago" : "Updated \(min / 60) hr ago"
      } else {
        fetch = "Not updated yet"
      }
    } else {
      fetch = "Loading…"
    }
    return hidden > 0 ? "\(fetch) · \(hidden) hidden until you refresh" : fetch
  }

  static func folderIcon(_ folder: LiveFolder) -> (site: String, icon: String?) {
    let site = LiveSource.sites[folder.sources.first ?? .github] ?? ""
    return (site, folder.icon ?? (folder.sources.count > 1 && folder.kind == .documents ? "symbol:doc.text" : nil))
  }
}

public enum SidebarLiveMetrics {
  public static let headerHeight: CGFloat = 34
  public static let itemHeight: CGFloat = 34
  public static let sectionHeight: CGFloat = 22
  public static let moreHeight: CGFloat = 26
  public static let stackHeight: CGFloat = 26
  public static let noteHeight: CGFloat = 28
  public static let footerHeight: CGFloat = 24
  public static let completedHeight: CGFloat = 28
  public static let footerItems = 8
  public static let gap: CGFloat = SidebarMetrics.rowGap
  public static let stackPadTop: CGFloat = SidebarMetrics.rowGap
  public static let pad: CGFloat = SidebarMetrics.groupPad
  public static let border: CGFloat = SidebarMetrics.groupBorder
  public static let stackIndent: CGFloat = 10
  public static let completionFoldDelay: TimeInterval = (LiveEngine.completionMs - 420) / 1000
  public static let completionFoldDuration: TimeInterval = 0.36
  public static let footerCloseDelay: TimeInterval = 0.25

  public static func itemKey(_ folderId: String, _ itemId: String) -> String { "live|\(folderId)|\(itemId)" }
  public static func headerKey(_ folderId: String) -> String { "livefolder|\(folderId)" }
  public static func boxKey(_ folderId: String) -> String { "lf:\(folderId)" }
}

public struct SidebarLiveItemSpec: Sendable, Equatable {
  public var folderId: String
  public var item: LiveItem
  public var inStack: Bool
  public var tabId: String?
  public var active: Bool
  public var unread: Bool
  public var completion: CompletionState?
  public var folded = false
}

public struct SidebarLiveNote: Sendable, Equatable {
  public enum Style: Sendable, Equatable { case loading, warning, plain }
  public var text: String
  public var style: Style
  public var action: String?
}

public struct SidebarLiveHeaderSpec: Sendable, Equatable {
  public var folder: LiveFolder
  public var count: Int
  public var unread: Bool
  public var status: FolderStatus?
  public var hidden: Int
  public var collapsed: Bool
  public var statusText: String

  var updating: Bool { status?.state == .updating || status?.state == .initializing }
}

public struct SidebarLiveRow: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case item(SidebarLiveItemSpec)
    case stack(folderId: String, id: String, repo: String, count: Int, collapsed: Bool)
    case section(String)
    case more(folderId: String, section: String, count: Int)
    case note(SidebarLiveNote)
    case footer(folderId: String, count: Int, open: Bool)
    case completed(folderId: String, done: CompletedItem)
    case stray(String)
  }

  public var key: String
  public var height: CGFloat
  public var kind: Kind
  public var gapBefore: CGFloat = 0
}

public struct SidebarLiveEntry: Sendable, Equatable {
  public var rows: [SidebarLiveRow]
  public var holds = false

  public var height: CGFloat { rows.reduce(0) { $0 + $1.gapBefore + $1.height } }
}

public struct SidebarLiveBlock: Sendable, Equatable {
  public var folderId: String
  public var header: SidebarLiveHeaderSpec
  public var entries: [SidebarLiveEntry]

  typealias M = SidebarLiveMetrics

  public var contentHeight: CGFloat {
    guard !entries.isEmpty else { return 0 }
    return entries.reduce(0) { $0 + $1.height } + M.gap * CGFloat(entries.count - 1) + M.pad
  }

  public var height: CGFloat { M.border * 2 + M.headerHeight + contentHeight }

  func row(_ key: String) -> SidebarLiveRow? {
    for entry in entries { if let row = entry.rows.first(where: { $0.key == key }) { return row } }
    return nil
  }
}

@MainActor
public struct SidebarMotion {
  public var slide: TimeInterval
  public var slideCurve: CAMediaTimingFunction
  public var fade: TimeInterval
  public var fadeCurve: CAMediaTimingFunction

  static let foldCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)

  public static var standard: SidebarMotion {
    SidebarMotion(slide: SidebarView.slideDuration, slideCurve: SidebarView.slideCurve, fade: SidebarView.fadeDuration, fadeCurve: SidebarView.fadeCurve)
  }

  public static var fold: SidebarMotion { SidebarMotion(slide: 0.15, slideCurve: foldCurve, fade: 0.15, fadeCurve: foldCurve) }

  public static var completionFold: SidebarMotion {
    SidebarMotion(slide: SidebarLiveMetrics.completionFoldDuration, slideCurve: foldCurve, fade: SidebarLiveMetrics.completionFoldDuration, fadeCurve: foldCurve)
  }
}

@MainActor
public final class SidebarLiveFeed {
  public static let shared = SidebarLiveFeed()
  public static let changed = Notification.Name("SolaraSidebarLiveChanged")

  public private(set) var live: SidebarLive?
  public private(set) var motion = SidebarMotion.standard
  private var completingSince: [String: Timer] = [:]
  private var footerClose: [String: Timer] = [:]

  public func apply(_ state: LiveState) {
    var next = live ?? SidebarLive(state: state)
    next.state = state
    next.now = Date().timeIntervalSince1970 * 1000
    var current = Set<String>()
    var startedAt: [String: Double] = [:]
    for (folderId, ids) in state.completing {
      for id in ids {
        let key = "\(folderId)|\(id)"
        current.insert(key)
        startedAt[key] = state.completed[folderId]?.first { $0.item.id == id }?.at
      }
    }
    for key in completingSince.keys where !current.contains(key) {
      completingSince[key]?.invalidate()
      completingSince[key] = nil
    }
    next.foldedAway.formIntersection(current)
    for key in current where completingSince[key] == nil {
      let started = startedAt[key].map { $0 / 1000 } ?? Date().timeIntervalSince1970
      let wait = max(0, started + SidebarLiveMetrics.completionFoldDelay - Date().timeIntervalSince1970)
      completingSince[key] = Self.after(wait) { [weak self] in self?.foldAway(key) }
    }
    next.openFooters = next.openFooters.filter { state.folders[$0] != nil }
    let was = live?.state
    let folds = was.map { was in
      was.expandedStacks != state.expandedStacks || state.folders.contains { id, f in was.folders[id].map { $0.collapsed != f.collapsed } ?? false }
    } ?? false
    publish(next, motion: folds ? .fold : .standard)
  }

  private func foldAway(_ key: String) {
    guard var next = live else { return }
    next.foldedAway.insert(key)
    publish(next, motion: .completionFold)
  }

  func setFooter(_ folderId: String, open: Bool) {
    footerClose[folderId]?.invalidate()
    footerClose[folderId] = Self.after(open ? 0 : SidebarLiveMetrics.footerCloseDelay) { [weak self] in
      guard let self, var next = self.live, next.openFooters.contains(folderId) != open else { return }
      self.footerClose[folderId] = nil
      if open { next.openFooters.insert(folderId) } else { next.openFooters.remove(folderId) }
      self.publish(next)
    }
  }

  private static func after(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { body() } }
    timer.tolerance = 0
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private func publish(_ next: SidebarLive, motion: SidebarMotion = .standard) {
    guard next != live else { return }
    live = next
    self.motion = motion
    NotificationCenter.default.post(name: Self.changed, object: self)
    self.motion = .standard
  }
}
