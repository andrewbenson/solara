import Foundation

public struct FolderPatch: Sendable, Equatable {
  public var name: String?
  public var icon: String??
  public var collapsed: Bool?
  public var sources: [LiveSourceId]?
  public var filters: LiveFilters?
  public var groupStacks: Bool?
  public var showCompleted: Bool?
  public var createdAt: Double?
  public var after: String??

  public init(
    name: String? = nil, icon: String?? = .none, collapsed: Bool? = nil, sources: [LiveSourceId]? = nil, filters: LiveFilters? = nil,
    groupStacks: Bool? = nil, showCompleted: Bool? = nil, createdAt: Double? = nil, after: String?? = .none
  ) {
    self.name = name
    self.icon = icon
    self.collapsed = collapsed
    self.sources = sources
    self.filters = filters
    self.groupStacks = groupStacks
    self.showCompleted = showCompleted
    self.createdAt = createdAt
    self.after = after
  }

  func applied(to folder: LiveFolder) -> LiveFolder {
    var f = folder
    if let name { f.name = name }
    if case .some(let icon) = icon { f.icon = icon }
    if let collapsed { f.collapsed = collapsed }
    if let sources { f.sources = sources }
    if let filters { f.filters = filters }
    if let groupStacks { f.groupStacks = groupStacks }
    if let showCompleted { f.showCompleted = showCompleted }
    if let createdAt { f.createdAt = createdAt }
    if case .some(let after) = after { f.after = .some(after) }
    return f
  }
}

public struct ConfigPatch: Sendable, Equatable {
  public var githubClientId: String?
  public var googleClientId: String?

  public init(
    githubClientId: String? = nil, googleClientId: String? = nil
  ) {
    self.githubClientId = githubClientId
    self.googleClientId = googleClientId
  }
}

public struct CalendarSettingsPatch: Sendable, Equatable {
  public var alertLead: String?
  public var alertCondition: AlertCondition?
  public var showPreview: Bool?
  public var showTimeToNext: Bool?
  public var hiddenCalendarIds: [String]?
  public var prompted: Bool?

  public init(
    alertLead: String? = nil, alertCondition: AlertCondition? = nil, showPreview: Bool? = nil, showTimeToNext: Bool? = nil,
    hiddenCalendarIds: [String]? = nil, prompted: Bool? = nil
  ) {
    self.alertLead = alertLead
    self.alertCondition = alertCondition
    self.showPreview = showPreview
    self.showTimeToNext = showTimeToNext
    self.hiddenCalendarIds = hiddenCalendarIds
    self.prompted = prompted
  }
}

public struct FolderPlacement: Sendable, Equatable {
  public var id: String
  public var after: String?

  public init(id: String, after: String?) {
    self.id = id
    self.after = after
  }
}

public struct LiveState: Codable, Sendable, Equatable {
  public static let documentName = "live.json"
  public static let maxKnown = 600
  public static let maxCompleted = 20
  public static let maxDismissedAlerts = 200

  public var folders: [String: LiveFolder] = [:]
  public var folderOrder: [String] = []
  public var items: [String: [LiveItem]] = [:]
  public var known: [String: [String]] = [:]
  public var unread: [String: [String]] = [:]
  public var hidden: [String: [LiveItem]] = [:]
  public var completed: [String: [CompletedItem]] = [:]
  public var completing: [String: [String]] = [:]
  public var status: [String: FolderStatus] = [:]
  public var expandedStacks: [String: Bool] = [:]
  public var showAll: [String: Bool] = [:]
  public var accounts: [LiveSourceId: LiveAccount] = [:]
  public var config: LiveConfig = .defaults
  public var calendar: CalendarSettings = .defaults
  public var meetingGroups: [String: MeetingGroup] = [:]
  public var dismissedAlerts: [String] = []
  public var notifiedAlerts: [String] = []
  public var extra: [String: LiveAnyJSON] = [:]
  var retiredSources = Set<LiveRetiredSource>()
  var retiredCredentials = Set<LiveRetiredSource>()
  var originalKnown: [String: LiveAnyJSON]?
  var decodedKnown: [String: LiveAnyJSON]?

  public init() {}

  enum CodingKeys: String, CodingKey, CaseIterable {
    case folders, folderOrder, items, known, unread, hidden, completed, completing, status, expandedStacks, showAll, accounts, config,
      calendar, meetingGroups, dismissedAlerts, notifiedAlerts
  }

  static let persisted: [CodingKeys] = [
    .folders, .folderOrder, .items, .known, .unread, .hidden, .completed, .expandedStacks, .accounts, .config, .calendar, .meetingGroups,
    .dismissedAlerts, .notifiedAlerts,
  ]

  static let entryMaps: Set<String> = [
    "folders", "items", "known", "unread", "hidden", "completed", "expandedStacks", "accounts", "meetingGroups",
  ]

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
      (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
    func map<T: Decodable>(_ key: CodingKeys) -> [String: T] {
      (try? c.decodeIfPresent(LossyMap<T>.self, forKey: key))?.values ?? [:]
    }
    func lists<T: Decodable>(_ key: CodingKeys) -> [String: [T]] {
      ((try? c.decodeIfPresent(LossyMap<LossyList<T>>.self, forKey: key))?.values ?? [:]).mapValues(\.values)
    }
    folders = map(.folders)
    folderOrder = (try? c.decodeIfPresent(LossyList<String>.self, forKey: .folderOrder))?.values ?? []
    items = lists(.items)
    known = lists(.known)
    unread = lists(.unread)
    hidden = lists(.hidden)
    completed = lists(.completed)
    expandedStacks = map(.expandedStacks)
    let accountsByName: [String: LiveAccount] = map(.accounts)
    accounts = Dictionary(uniqueKeysWithValues: accountsByName.compactMap { key, value in LiveSourceId(rawValue: key).map { ($0, value) } })
    config = field(.config, .defaults)
    calendar = field(.calendar, .defaults)
    meetingGroups = map(.meetingGroups)
    dismissedAlerts = (try? c.decodeIfPresent(LossyList<String>.self, forKey: .dismissedAlerts))?.values ?? []
    notifiedAlerts = (try? c.decodeIfPresent(LossyList<String>.self, forKey: .notifiedAlerts))?.values ?? []
    extra = UnknownKeys.read(decoder, known: CodingKeys.allCases.map(\.rawValue))
    let raw = try decoder.container(keyedBy: LiveAnyKey.self)
    originalKnown = [:]
    let persistedKeys = Set(LiveState.persisted.map(\.rawValue))
    for key in raw.allKeys where persistedKeys.contains(key.stringValue) {
      originalKnown?[key.stringValue] = try raw.decode(LiveAnyJSON.self, forKey: key)
    }
    scrubRetiredSources()
    decodedKnown = nil
    var clean = self
    clean.originalKnown = nil
    let normalized = try LiveJSON.encode(clean)
    decodedKnown = try LiveJSON.decode([String: LiveAnyJSON].self, from: normalized)
  }

  public func encode(to encoder: Encoder) throws {
    if let originalKnown, let decodedKnown {
      var clean = self
      clean.originalKnown = nil
      clean.decodedKnown = nil
      let current = try LiveJSON.decode([String: LiveAnyJSON].self, from: LiveJSON.encode(clean))
      var merged = current
      for (key, original) in originalKnown {
        if let baseline = decodedKnown[key], let value = current[key] {
          merged[key] = LiveAnyJSON.reconciled(original: original, baseline: baseline, current: value, keepsDroppedEntries: LiveState.entryMaps.contains(key))
        } else if decodedKnown[key] == nil {
          merged[key] = original
        }
      }
      var c = encoder.container(keyedBy: LiveAnyKey.self)
      for (key, value) in merged { try c.encode(value, forKey: LiveAnyKey(key)) }
      return
    }
    try UnknownKeys.write(extra, to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(folders, forKey: .folders)
    try c.encode(folderOrder, forKey: .folderOrder)
    try c.encode(items, forKey: .items)
    try c.encode(known, forKey: .known)
    try c.encode(unread, forKey: .unread)
    try c.encode(hidden, forKey: .hidden)
    try c.encode(completed, forKey: .completed)
    try c.encode(expandedStacks, forKey: .expandedStacks)
    try c.encode(accounts, forKey: .accounts)
    try c.encode(config, forKey: .config)
    try c.encode(calendar, forKey: .calendar)
    try c.encode(meetingGroups, forKey: .meetingGroups)
    try c.encode(dismissedAlerts, forKey: .dismissedAlerts)
    if !notifiedAlerts.isEmpty { try c.encode(notifiedAlerts, forKey: .notifiedAlerts) }
  }

  public static func load(_ text: String?) -> LiveState {
    guard let text, let state = try? LiveJSON.decode(LiveState.self, from: text) else { return LiveState() }
    return state
  }

  public func persistedJSON() throws -> String {
    try LiveJSON.text(self)
  }

  public func replicaJSON() throws -> String {
    try LiveJSON.text(MeetingReplica(calendar: .init(prompted: calendar.prompted), meetingGroups: meetingGroups))
  }

  private struct MeetingReplica: Encodable {
    struct Calendar: Encodable { var prompted: Bool }

    var calendar: Calendar
    var meetingGroups: [String: MeetingGroup]
  }

  var persistedPart: PersistedPart {
    PersistedPart(
      folders: folders, folderOrder: folderOrder, items: items, known: known, unread: unread, hidden: hidden, completed: completed,
      expandedStacks: expandedStacks, accounts: accounts, config: config, calendar: calendar, meetingGroups: meetingGroups,
      dismissedAlerts: dismissedAlerts, notifiedAlerts: notifiedAlerts)
  }

  struct PersistedPart: Equatable {
    var folders: [String: LiveFolder]
    var folderOrder: [String]
    var items: [String: [LiveItem]]
    var known: [String: [String]]
    var unread: [String: [String]]
    var hidden: [String: [LiveItem]]
    var completed: [String: [CompletedItem]]
    var expandedStacks: [String: Bool]
    var accounts: [LiveSourceId: LiveAccount]
    var config: LiveConfig
    var calendar: CalendarSettings
    var meetingGroups: [String: MeetingGroup]
    var dismissedAlerts: [String]
    var notifiedAlerts: [String]
  }

  public static func folderDefaults(_ kind: LiveFolderKind) -> (name: String, sources: [LiveSourceId]) {
    switch kind {
    case .pullRequests: ("Pull Requests", [.github])
    case .documents: ("Documents", [.notion])
    }
  }

  @discardableResult
  public mutating func createFolder(id: String, profileId: String, kind: LiveFolderKind, sources: [LiveSourceId]?, now: Double) -> String {
    let defaults = LiveState.folderDefaults(kind)
    folders[id] = LiveFolder(
      id: id, profileId: profileId, kind: kind, name: defaults.name, icon: nil, collapsed: false, sources: sources ?? defaults.sources,
      filters: LiveFilters(), groupStacks: true, showCompleted: true, createdAt: now)
    folderOrder.append(id)
    status[id] = FolderStatus(state: .initializing, lastFetch: nil, error: nil)
    return id
  }

  public mutating func updateFolder(_ id: String, _ patch: FolderPatch) {
    guard let folder = folders[id] else { return }
    folders[id] = patch.applied(to: folder)
  }

  public mutating func removeFolder(_ id: String) {
    folders[id] = nil
    folderOrder.removeAll { $0 == id }
    items[id] = nil
    known[id] = nil
    unread[id] = nil
    hidden[id] = nil
    completed[id] = nil
    completing[id] = nil
    status[id] = nil
  }

  public mutating func arrangeFolders(_ placed: [FolderPlacement]) {
    let ids = placed.map(\.id).filter { folders[$0] != nil }
    if ids.isEmpty { return }
    let moved = placed.filter { p in
      guard let f = folders[p.id] else { return false }
      return f.after != .some(p.after)
    }
    for p in moved { folders[p.id]?.after = .some(p.after) }
    let slots = folderOrder.indices.filter { ids.contains(folderOrder[$0]) }
    var order = folderOrder
    for (i, slot) in slots.enumerated() where i < ids.count { order[slot] = ids[i] }
    if order != folderOrder { folderOrder = order }
  }

  public mutating func applyFetch(
    _ folderId: String, fetched: [LiveItem], gone: [String: CompletionState], now: Double, quiet: Set<String> = []
  ) {
    guard folders[folderId] != nil else { return }
    func closed(_ id: String) -> Bool { gone[id] == .merged || gone[id] == .closed }
    let oldHidden = hidden[folderId] ?? []
    let stillHidden = oldHidden.filter { !closed($0.id) }
    let hiddenIds = Set(stillHidden.map(\.id))
    let next = fetched.filter { !hiddenIds.contains($0.id) }
    let knownList = (known[folderId] ?? []).uniqued()
    let knownSet = Set(knownList)
    let first = knownSet.isEmpty && (status[folderId]?.lastFetch ?? 0) == 0
    let fresh = next.filter { !knownSet.contains($0.id) }.map(\.id)
    let unreadFresh = fresh.filter { !quiet.contains($0) }
    let ids = Set(next.map(\.id))
    let prev = items[folderId] ?? []
    let animating = Set(completing[folderId] ?? [])
    let leaving = prev.filter { !ids.contains($0.id) && gone[$0.id] != nil && !animating.contains($0.id) }
    let leavingIds = Set(leaving.map(\.id))
    var merged = next
    for (index, it) in prev.enumerated() where !ids.contains(it.id) && (animating.contains(it.id) || leavingIds.contains(it.id)) {
      merged.insert(it, at: min(index, merged.count))
    }
    let oldCompleted = completed[folderId] ?? []
    let nextCompleted = Array(
      (leaving.map { CompletedItem(item: $0, state: gone[$0.id]!, at: now) }
        + oldCompleted.filter { !ids.contains($0.item.id) && !leavingIds.contains($0.item.id) })
        .prefix(LiveState.maxCompleted))
    let stillThere = Set(merged.map(\.id))
    items[folderId] = merged
    if stillHidden.count != oldHidden.count { hidden[folderId] = stillHidden }
    known[folderId] = Array((knownList + fresh).suffix(LiveState.maxKnown))
    unread[folderId] = first ? [] : ((unread[folderId] ?? []) + unreadFresh).uniqued().filter { stillThere.contains($0) }
    if !leaving.isEmpty || oldCompleted.count != nextCompleted.count { completed[folderId] = nextCompleted }
    if !leaving.isEmpty { completing[folderId] = (completing[folderId] ?? []) + leaving.map(\.id) }
    status[folderId] = FolderStatus(state: .idle, lastFetch: now, error: nil)
  }

  public mutating func finishCompleting(_ folderId: String, _ ids: [String]) {
    let gone = Set(ids)
    items[folderId] = (items[folderId] ?? []).filter { !gone.contains($0.id) }
    completing[folderId] = (completing[folderId] ?? []).filter { !gone.contains($0) }
    unread[folderId] = (unread[folderId] ?? []).filter { !gone.contains($0) }
  }

  public mutating func setStatus(_ folderId: String, state: FolderStatus.State? = nil, lastFetch: Double?? = .none, error: FolderError?? = .none) {
    var current = status[folderId] ?? FolderStatus(state: .idle, lastFetch: nil, error: nil)
    if let state { current.state = state }
    if case .some(let lastFetch) = lastFetch { current.lastFetch = lastFetch }
    if case .some(let error) = error { current.error = error }
    status[folderId] = current
  }

  public mutating func markRead(_ folderId: String, _ itemIds: [String]? = nil) {
    let current = unread[folderId] ?? []
    let next = itemIds.map { ids in current.filter { !ids.contains($0) } } ?? []
    if next.count != current.count { unread[folderId] = next }
  }

  public mutating func markUnread(_ folderId: String, _ itemId: String) {
    unread[folderId, default: []].append(itemId)
  }

  public mutating func hideItems(_ folderId: String, _ hiding: [LiveItem]) {
    let itemIds = Set(hiding.map(\.id))
    func shown(_ id: String) -> Bool { !itemIds.contains(id) }
    hidden[folderId] = (hidden[folderId] ?? []).filter { shown($0.id) } + hiding
    items[folderId] = (items[folderId] ?? []).filter { shown($0.id) }
    unread[folderId] = (unread[folderId] ?? []).filter(shown)
    completing[folderId] = (completing[folderId] ?? []).filter(shown)
    completed[folderId] = (completed[folderId] ?? []).filter { shown($0.item.id) }
  }

  public mutating func unhide(_ folderId: String) {
    let wasHidden = hidden[folderId] ?? []
    if wasHidden.isEmpty { return }
    hidden[folderId] = nil
    items[folderId] = (items[folderId] ?? []) + wasHidden
  }

  public mutating func setAccount(_ source: LiveSourceId, _ account: LiveAccount?) {
    accounts[source] = account
  }

  public mutating func updateConfig(_ patch: ConfigPatch) {
    if let v = patch.githubClientId { config.githubClientId = v }
    if let v = patch.googleClientId { config.googleClientId = v }
  }

  public mutating func updateCalendarSettings(_ patch: CalendarSettingsPatch) {
    if let v = patch.alertLead { calendar.alertLead = v }
    if let v = patch.alertCondition { calendar.alertCondition = v }
    if let v = patch.showPreview { calendar.showPreview = v }
    if let v = patch.showTimeToNext { calendar.showTimeToNext = v }
    if let v = patch.hiddenCalendarIds { calendar.hiddenCalendarIds = v }
    if let v = patch.prompted { calendar.prompted = v }
  }

  public mutating func dismissAlert(_ occurrence: String) {
    if dismissedAlerts.contains(occurrence) { return }
    dismissedAlerts = Array((dismissedAlerts + [occurrence]).suffix(LiveState.maxDismissedAlerts))
  }

  public mutating func markNotified(_ occurrence: String) {
    if notifiedAlerts.contains(occurrence) { return }
    notifiedAlerts = Array((notifiedAlerts + [occurrence]).suffix(LiveState.maxDismissedAlerts))
  }

  public mutating func setMeetingGroup(_ group: MeetingGroup?, groupId: String? = nil) {
    if let group {
      meetingGroups[group.groupId] = group
    } else if let groupId {
      meetingGroups[groupId] = nil
    }
  }
}

struct LossyMap<T: Decodable>: Decodable {
  var values: [String: T] = [:]

  struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    for key in c.allKeys {
      if let value = try? c.decode(T.self, forKey: key) { values[key.stringValue] = value }
    }
  }
}

struct LossyList<T: Decodable>: Decodable {
  var values: [T] = []

  struct Skip: Decodable { init(from decoder: Decoder) throws {} }

  init(from decoder: Decoder) throws {
    var c = try decoder.unkeyedContainer()
    while !c.isAtEnd {
      if let value = try? c.decode(T.self) {
        values.append(value)
      } else {
        _ = try? c.decode(Skip.self)
      }
    }
  }
}
