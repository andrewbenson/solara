import Foundation

public struct LiveSnapshot: Sendable, Equatable {
  public var revision: UInt64
  public var live: LiveState
  public var calendar: CalendarData
  public var meetingAlert: CalendarEvent?
}

public enum LiveJob: Sendable, Hashable, CaseIterable {
  case folders, calendar, meetings, alerts
}

public actor LiveEngine {
  public static let intervalMs: [LiveFolderKind: Double] = [.pullRequests: 3 * 60_000, .documents: 10 * 60_000]
  public static let staleOnFocusMs: Double = 60_000
  public static let completionMs: Double = 2600
  public static let firstRefreshDelayMs: Double = 2500
  public static let folderPollEvery: Double = 30_000
  public static let nudgeThrottleMs: Double = 20_000
  public static let nudgeDelayMs: Double = 3000
  public static let saveDebounceMs: Double = 800
  public static let gridSlackMs: Double = 50
  public static let calendarPollEvery: Double = 5 * 60_000
  public static let alertPollEvery: Double = 10_000

  static let sectionOrder: [PullRequestSection: Int] = [.authored: 0, .review: 1, .team: 2]

  public private(set) var revision: UInt64 = 0
  public internal(set) var state: LiveState
  public private(set) var documentError: String?
  public private(set) var documentDirty = false
  let loadError: String?
  var safeDocumentState: LiveState?
  public internal(set) var calendarData = CalendarData()
  public internal(set) var meetingAlert: CalendarEvent?

  public nonisolated let effects: LiveEffects
  public nonisolated let endpoints: LiveEndpoints
  nonisolated let requester: LiveRequester
  let launchedAt: Double

  var sources: [LiveSourceId: LiveSource] = LiveSource.standard
  var inflight: [String: Task<Void, Never>] = [:]
  var fetchedSources: [String: Set<LiveSourceId>] = [:]
  var lastNudge: [String: Double] = [:]
  var idCounter = 0
  var started = false
  var jobs: [Task<Void, Never>] = []
  var slowEntries: [SlowJob: SlowEntry] = [:]
  var slowTimer: Task<Void, Never>?
  var slowTimerAt = Double.infinity
  var slowFiring = false
  var saveTask: Task<Void, Never>?
  var observers: [UUID: AsyncStream<LiveSnapshot>.Continuation] = [:]
  var selectedJobs: Set<LiveJob> = []
  var deviceFlows: [String: GithubDeviceFlow] = [:]
  var persistedTextSink: (@Sendable (String) -> Void)?
  var calendarInflight: Task<Void, Never>?
  var appActive = true
  var postingAlerts = Set<String>()
  var googlePending: Task<Void, Error>?
  var googleCredentialsGeneration = 0
  var googleDisconnecting = false
  var meetingHost: (any LiveMeetingHost)?

  public init(effects: LiveEffects, state: LiveState? = nil) {
    self.effects = effects
    self.endpoints = LiveEndpoints(mock: effects.environment.mockBase)
    self.requester = LiveRequester(http: effects.http, environment: effects.environment)
    if let state {
      self.state = state
      self.documentError = nil
      self.loadError = nil
    } else {
      switch effects.documents.readStatus(LiveState.documentName) {
      case .missing:
        self.state = LiveState()
        self.documentError = nil
        self.loadError = nil
      case .contents(let text):
        do {
          self.state = try LiveJSON.decode(LiveState.self, from: text)
          self.documentError = nil
          self.loadError = nil
        } catch {
          self.state = LiveState()
          let message = "Cannot decode live.json: \(error)"
          self.documentError = message
          self.loadError = message
        }
      case .failure(let message):
        self.state = LiveState()
        let error = "Cannot read live.json: \(message)"
        self.documentError = error
        self.loadError = error
      }
    }
    self.safeDocumentState = effects.environment.safeMode ? self.state : nil
    self.launchedAt = effects.clock.now()
  }

  public var snapshot: LiveSnapshot { LiveSnapshot(revision: revision, live: state, calendar: calendarData, meetingAlert: meetingAlert) }

  public func currentReplica() throws -> (revision: UInt64, replicaJSON: String, calendarJSON: String, meetingAlertJSON: String) {
    (revision, try state.replicaJSON(), String(decoding: try LiveJSON.encode(CalendarDataWire(calendarData)), as: UTF8.self),
      String(decoding: try LiveJSON.encode(meetingAlert), as: UTF8.self))
  }

  public nonisolated static func initialReplica(documentText: String?) throws -> (revision: UInt64, replicaJSON: String, calendarJSON: String, meetingAlertJSON: String) {
    let state = try documentText.map { try LiveJSON.decode(LiveState.self, from: $0) } ?? LiveState()
    return (0, try state.replicaJSON(), String(decoding: try LiveJSON.encode(CalendarDataWire(CalendarData())), as: UTF8.self), "null")
  }

  public func setPersistedTextSink(_ sink: (@Sendable (String) -> Void)?) {
    persistedTextSink = sink
  }

  public func changes() -> AsyncStream<LiveSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<LiveSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    continuation.onTermination = { [weak self] _ in Task { await self?.dropObserver(id) } }
    observers[id] = continuation
    continuation.yield(snapshot)
    return stream
  }

  func dropObserver(_ id: UUID) { observers[id] = nil }

  func emit() {
    revision += 1
    let snap = snapshot
    for continuation in observers.values { continuation.yield(snap) }
    rescheduleSlowJobs()
  }

  public func update(_ body: @Sendable (inout LiveState) -> Void) {
    mutate(body)
  }

  func mutate(persist: Bool = true, _ body: (inout LiveState) -> Void) {
    let before = state
    body(&state)
    var documentChanged = false
    if persist, var document = safeDocumentState {
      let previous = document.persistedPart
      body(&document)
      documentChanged = document.persistedPart != previous
      safeDocumentState = document
    }
    if state == before, !documentChanged { return }
    if effects.environment.safeMode ? documentChanged : state.persistedPart != before.persistedPart { scheduleSave() }
    let hiddenChanged = state.calendar.hiddenCalendarIds != before.calendar.hiddenCalendarIds
    emit()
    if hiddenChanged, started, selectedJobs.contains(.calendar) { refreshCalendar() }
  }

  func setCalendarData(_ body: (inout CalendarData) -> Void) {
    let before = calendarData
    body(&calendarData)
    if calendarData == before { return }
    let eventsChanged = calendarData.events != before.events
    emit()
    if eventsChanged, started, selectedJobs.contains(.alerts) { Task { await self.checkAlerts() } }
  }

  func scheduleSave() {
    documentDirty = true
    if let persistedTextSink, loadError == nil, let text = try? persistedDocumentJSON() { persistedTextSink(text) }
    saveTask?.cancel()
    saveTask = Task {
      do {
        try await effects.clock.sleep(milliseconds: LiveEngine.saveDebounceMs)
      } catch {
        return
      }
      if Task.isCancelled { return }
      do { try self.save() } catch { NSLog("Live Folders save failed: %@", String(describing: error)) }
    }
  }

  public func acknowledgeDocumentSave(_ text: String) {
    if (try? persistedDocumentJSON()) == text { documentDirty = false }
  }

  public func persistedDocumentJSON() throws -> String {
    try (safeDocumentState ?? state).persistedJSON()
  }

  public func save() throws {
    if let loadError { throw LiveError(.other, loadError) }
    do {
      let text = try persistedDocumentJSON()
      try effects.documents.write(LiveState.documentName, text)
      documentError = nil
    } catch {
      documentError = "Cannot save live.json: \(error)"
      throw error
    }
  }

  public func flush() throws {
    saveTask?.cancel()
    saveTask = nil
    try save()
  }

  public func source(_ id: LiveSourceId) -> LiveSource { sources[id]! }

  public func setSource(_ source: LiveSource) { sources[source.id] = source }

  public func setResolveGone(_ id: LiveSourceId, _ resolve: LiveSource.ResolveGone?) { sources[id]?.resolveGone = resolve }

  func newId() -> String {
    idCounter += 1
    return "lf-\(JS.base36(Int(effects.clock.now())))-\(JS.base36(idCounter))"
  }

  @discardableResult
  public func createFolder(profileId: String, kind: LiveFolderKind, sources: [LiveSourceId]? = nil) -> String {
    let id = newId()
    let now = effects.clock.now()
    mutate { $0.createFolder(id: id, profileId: profileId, kind: kind, sources: sources, now: now) }
    return id
  }

  public func updateFolder(_ id: String, _ patch: FolderPatch) { mutate { $0.updateFolder(id, patch) } }
  public func removeFolder(_ id: String) { mutate { $0.removeFolder(id) } }
  public func deleteLiveFolder(_ id: String) { removeFolder(id) }
  public func arrangeFolders(_ placed: [FolderPlacement]) { mutate { $0.arrangeFolders(placed) } }

  public func applyFetch(_ folderId: String, _ fetched: [LiveItem], gone: [String: CompletionState], now: Double? = nil, quiet: Set<String> = []) {
    let at = now ?? effects.clock.now()
    mutate(persist: false) { $0.applyFetch(folderId, fetched: fetched, gone: gone, now: at, quiet: quiet) }
  }

  public func finishCompleting(_ folderId: String, _ ids: [String]) { mutate(persist: false) { $0.finishCompleting(folderId, ids) } }
  public func markRead(_ folderId: String, _ itemIds: [String]? = nil) {
    let read = itemIds ?? state.unread[folderId] ?? []
    mutate {
      $0.markRead(folderId, itemIds)
      if effects.environment.safeMode, !read.isEmpty {
        $0.known[folderId] = Array((($0.known[folderId] ?? []) + read).uniqued().suffix(LiveState.maxKnown))
      }
    }
  }

  public func markUnread(_ folderId: String, _ itemId: String) {
    mutate {
      $0.markUnread(folderId, itemId)
      if effects.environment.safeMode {
        $0.known[folderId] = Array((($0.known[folderId] ?? []) + [itemId]).uniqued().suffix(LiveState.maxKnown))
      }
    }
  }
  public func hideItems(_ folderId: String, _ items: [LiveItem]) { mutate { $0.hideItems(folderId, items) } }
  public func setExpandedStack(_ key: String, _ expanded: Bool) { mutate { $0.expandedStacks[key] = expanded } }
  public func setShowAll(_ key: String, _ all: Bool) { mutate { $0.showAll[key] = all } }
  public func setAccount(_ source: LiveSourceId, _ account: LiveAccount?) { mutate { $0.setAccount(source, account) } }
  public func updateConfig(_ patch: ConfigPatch) { mutate { $0.updateConfig(patch) } }
  public func updateCalendarSettings(_ patch: CalendarSettingsPatch) { mutate { $0.updateCalendarSettings(patch) } }
  public func setMeetingGroup(_ group: MeetingGroup?, groupId: String? = nil) { mutate { $0.setMeetingGroup(group, groupId: groupId) } }

  public func setCalendarHidden(_ id: String, hidden: Bool) {
    let ids = state.calendar.hiddenCalendarIds.filter { $0 != id }
    updateCalendarSettings(CalendarSettingsPatch(hiddenCalendarIds: hidden ? ids + [id] : ids))
  }

  @discardableResult
  public func newProfileLiveFolder(profileId: String, kind: LiveFolderKind, sources: [LiveSourceId]? = nil) -> String {
    let candidates: [LiveSourceId] = kind == .pullRequests ? [.github] : [.notion, .gdrive]
    let connected = candidates.filter { state.accounts[$0] != nil }
    let id = createFolder(profileId: profileId, kind: kind, sources: sources ?? (connected.isEmpty ? nil : connected))
    if !effects.environment.safeMode { refreshFolder(id) }
    return id
  }

  public func liveFolderIcon(_ folder: LiveFolder) -> (site: String, icon: String?) {
    let site = sources[folder.sources.first ?? .github]!.site
    return (site, folder.icon ?? (folder.sources.count > 1 && folder.kind == .documents ? "symbol:doc.text" : nil))
  }

  @discardableResult
  public func refreshFolder(_ folderId: String) -> Task<Void, Never> {
    if let running = inflight[folderId] { return running }
    let begun = beginRun(folderId)
    let task = Task {
      if let begun { await self.run(folderId, begun) }
      self.inflight[folderId] = nil
    }
    inflight[folderId] = task
    return task
  }

  @discardableResult
  public func manualRefresh(_ folderId: String) -> Task<Void, Never> {
    mutate { $0.unhide(folderId) }
    return refreshFolder(folderId)
  }

  struct Begun: Sendable {
    var folder: LiveFolder
    var hadFetched: Bool
  }

  func beginRun(_ folderId: String) -> Begun? {
    guard let folder = state.folders[folderId] else { return nil }
    let hadFetched = (state.status[folderId]?.lastFetch ?? 0) != 0
    mutate { $0.setStatus(folderId, state: hadFetched ? .updating : .initializing) }
    return Begun(folder: folder, hadFetched: hadFetched)
  }

  static func order(_ items: [LiveItem]) -> [LiveItem] {
    items.stableSorted { a, b in
      let sa = sectionOrder[a.section ?? .authored] ?? 0
      let sb = sectionOrder[b.section ?? .authored] ?? 0
      return sa != sb ? sa < sb : b.updatedAt < a.updatedAt
    }
  }

  func run(_ folderId: String, _ begun: Begun) async {
    let folder = begun.folder
    let fetchers = folder.sources.map { sources[$0]! }
    let results: [Result<[LiveItem], Error>] = await withTaskGroup(of: (Int, Result<[LiveItem], Error>).self) { group in
      for (i, source) in fetchers.enumerated() {
        group.addTask {
          do { return (i, .success(try await source.fetch(self, folder))) } catch { return (i, .failure(error)) }
        }
      }
      var out: [(Int, Result<[LiveItem], Error>)] = []
      for await r in group { out.append(r) }
      return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
    var fetched: [LiveItem] = []
    var failed: [(source: LiveSourceId, error: Error)] = []
    for (i, r) in results.enumerated() {
      switch r {
      case .success(let items): fetched += items
      case .failure(let error): failed.append((folder.sources[i], error))
      }
    }
    if state.folders[folderId] == nil { return }
    let failedSources = Set(failed.map(\.source))
    func fromFailedSource(_ it: LiveItem) -> Bool { failedSources.contains(it.source) }
    func listedByFilters(_ it: LiveItem) -> Bool {
      it.section == .review || it.section == .team ? folder.filters.reviewRequests : folder.filters.authored
    }
    func fetchWouldList(_ it: LiveItem) -> Bool { folder.sources.contains(it.source) && !fromFailedSource(it) && listedByFilters(it) }

    let ids = Set(fetched.map(\.id))
    let animatingAtLanding = Set(state.completing[folderId] ?? [])
    let missing = ((state.items[folderId] ?? []) + (state.hidden[folderId] ?? [])).filter {
      !ids.contains($0.id) && !animatingAtLanding.contains($0.id) && fetchWouldList($0)
    }
    var gone: [String: CompletionState] = [:]
    for source in missing.map(\.source).uniqued() {
      guard let resolve = sources[source]?.resolveGone else { continue }
      let found = (try? await resolve(self, missing.filter { $0.source == source })) ?? [:]
      gone.merge(found) { _, new in new }
    }

    let prev = state.items[folderId] ?? []
    let animating = Set(state.completing[folderId] ?? [])
    let next = fetched + prev.filter { fromFailedSource($0) && !animating.contains($0.id) }

    if let firstFailure = failed.first, failed.count == folder.sources.count, prev.isEmpty, !begun.hadFetched {
      let error = describe(firstFailure.source, firstFailure.error)
      mutate { $0.setStatus(folderId, state: .error, error: .some(error)) }
      return
    }
    let lastSources = fetchedSources[folderId]
    let quiet = Set(lastSources.map { last in next.filter { !last.contains($0.source) }.map(\.id) } ?? [])
    fetchedSources[folderId] = Set(folder.sources.filter { !failedSources.contains($0) })
    applyFetch(folderId, LiveEngine.order(next), gone: gone, now: effects.clock.now(), quiet: quiet)
    if let firstFailure = failed.first {
      let error = describe(firstFailure.source, firstFailure.error)
      mutate { $0.setStatus(folderId, state: .error, error: .some(error)) }
    }
    let leaving = Array(gone.keys)
    if !leaving.isEmpty {
      let clock = effects.clock
      Task {
        try? await clock.sleep(milliseconds: LiveEngine.completionMs)
        self.finishCompleting(folderId, leaving)
      }
    }
  }

  nonisolated func describe(_ source: LiveSourceId, _ error: Error) -> FolderError {
    if let live = error as? LiveError { return FolderError(kind: live.kind, message: live.message, source: source) }
    return FolderError(kind: .other, message: String(describing: error), source: source)
  }

  public func statusText(_ folderId: String, now: Double? = nil) -> String {
    let at = now ?? effects.clock.now()
    let hidden = state.hidden[folderId]?.count ?? 0
    return hidden > 0 ? "\(fetchText(folderId, now: at)) · \(hidden) hidden until you refresh" : fetchText(folderId, now: at)
  }

  func fetchText(_ folderId: String, now: Double) -> String {
    guard let st = state.status[folderId], st.state != .initializing else { return "Loading…" }
    if st.state == .updating { return "Updating…" }
    if let error = st.error { return LiveEngine.errorText(error.kind, source: error.source) }
    guard let last = st.lastFetch, last != 0 else { return "Not updated yet" }
    let min = Int(((now - last) / 60_000).rounded(.down))
    return min < 1 ? "Updated just now" : min < 60 ? "Updated \(min) min ago" : "Updated \(min / 60) hr ago"
  }

  public static func errorText(_ kind: LiveErrorKind, source: LiveSourceId) -> String {
    let name = LiveSource.names[source]!
    switch kind {
    case .notConfigured: return "Connect \(name) in Settings"
    case .signedOut: return "Sign back in to \(name)"
    case .sso: return "\(name) needs Single Sign-On for this organization"
    case .rateLimited: return "\(name) rate limit exceeded. Try again in a few minutes."
    case .network: return "Couldn't connect to \(name)"
    case .other: return "We're having trouble connecting to \(name)"
    }
  }

  func due(_ id: String, maxAge: Double) -> Bool {
    guard state.folders[id] != nil else { return false }
    guard let last = state.status[id]?.lastFetch, last != 0 else { return true }
    return effects.clock.now() - last >= maxAge
  }

  public func start(jobs selected: Set<LiveJob> = Set(LiveJob.allCases), meetingHost: (any LiveMeetingHost)? = nil) async {
    guard !effects.environment.safeMode else { return }
    if started { return }
    started = true
    let retiredCredentials = state.retiredCredentials
    let retiredDataFound = !state.retiredSources.isEmpty
    state.retiredSources = []
    state.retiredCredentials = []
    selectedJobs = selected
    self.meetingHost = meetingHost
    let clock = effects.clock
    if selected.contains(.folders) {
      jobs.append(Task {
        do { try await clock.sleep(milliseconds: LiveEngine.firstRefreshDelayMs) } catch { return }
        for id in self.state.folderOrder { self.refreshFolder(id) }
      })
    }
    if effects.environment.separateSlowTimers {
      for job in SlowJob.allCases where selected.contains(job.liveJob) { jobs.append(Task { await self.slowlySeparate(job) }) }
    } else {
      for job in SlowJob.allCases where selected.contains(job.liveJob) { slowEntries[job] = SlowEntry(next: slotAfter(effects.clock.now(), every(job)), armed: false) }
      rescheduleSlowJobs()
    }
    if selected.contains(.calendar) { refreshCalendar() }
    if selected.contains(.alerts) { Task { await self.checkAlerts() } }
    for source in retiredCredentials {
      _ = await effects.secrets.deleteSecret(account: endpoints.secretAccount(source.rawValue))
    }
    if retiredDataFound { scheduleSave() }
  }

  public func stop() {
    started = false
    for job in jobs { job.cancel() }
    jobs = []
    slowTimer?.cancel()
    slowTimer = nil
    slowTimerAt = .infinity
    slowEntries = [:]
  }

  public func windowFocused() {
    guard !effects.environment.safeMode else { return }
    appActive = true
    for id in state.folderOrder where due(id, maxAge: LiveEngine.staleOnFocusMs) { refreshFolder(id) }
  }

  public func appResignedActive() { appActive = false }

  public func liveTabDeactivated(folderId: String) {
    guard !effects.environment.safeMode, state.folders[folderId] != nil else { return }
    let now = effects.clock.now()
    if now - (lastNudge[folderId] ?? 0) < LiveEngine.nudgeThrottleMs { return }
    lastNudge[folderId] = now
    let clock = effects.clock
    Task {
      try? await clock.sleep(milliseconds: LiveEngine.nudgeDelayMs)
      self.refreshFolder(folderId)
    }
  }

  public func profilesChanged(existing: Set<String>) {
    guard !effects.environment.safeMode else { return }
    for f in state.folders.values where !existing.contains(f.profileId) { removeFolder(f.id) }
  }

  enum SlowJob: CaseIterable {
    case folders, calendar, meetings, alerts

    var liveJob: LiveJob {
      switch self {
      case .folders: .folders
      case .calendar: .calendar
      case .meetings: .meetings
      case .alerts: .alerts
      }
    }
  }

  struct SlowEntry { var next: Double; var armed: Bool }

  func slotAfter(_ time: Double, _ every: Double) -> Double { ((time / every).rounded(.down) + 1) * every }

  func every(_ job: SlowJob) -> Double {
    switch job {
    case .folders: LiveEngine.folderPollEvery
    case .calendar: LiveEngine.calendarPollEvery
    case .meetings: effects.environment.separateSlowTimers ? 20_000 : MeetingGroups.tickEvery
    case .alerts: LiveEngine.alertPollEvery
    }
  }

  func needed(_ job: SlowJob) -> Bool {
    switch job {
    case .folders: !state.folderOrder.isEmpty
    case .calendar: calendarData.connected
    case .meetings: !state.meetingGroups.isEmpty && meetingHost != nil
    case .alerts: !calendarData.events.isEmpty || meetingAlert != nil
    }
  }

  func runJob(_ job: SlowJob) async {
    guard started, selectedJobs.contains(job.liveJob) else { return }
    switch job {
    case .folders:
      for id in state.folderOrder {
        guard let folder = state.folders[id] else { continue }
        if due(id, maxAge: LiveEngine.intervalMs[folder.kind]!) { refreshFolder(id) }
      }
    case .calendar: refreshCalendar()
    case .meetings: await meetingTick()
    case .alerts: await checkAlerts()
    }
  }

  func slowlySeparate(_ job: SlowJob) async {
    let clock = effects.clock
    while !Task.isCancelled {
      do { try await clock.sleep(milliseconds: every(job)) } catch { return }
      if Task.isCancelled { return }
      if needed(job) { Task { await self.runJob(job) } }
    }
  }

  func rescheduleSlowJobs() {
    guard started, !effects.environment.separateSlowTimers, !slowFiring else { return }
    let now = effects.clock.now()
    var next = Double.infinity
    for job in SlowJob.allCases {
      guard var entry = slowEntries[job] else { continue }
      if !needed(job) {
        entry.armed = false
      } else {
        if !entry.armed, entry.next <= now { entry.next = slotAfter(now, every(job)) }
        entry.armed = true
        next = min(next, entry.next)
      }
      slowEntries[job] = entry
    }
    if next == slowTimerAt { return }
    slowTimer?.cancel()
    slowTimer = nil
    slowTimerAt = next
    guard next.isFinite else { return }
    let clock = effects.clock
    let deadline = next
    slowTimer = Task {
      do { try await clock.sleep(milliseconds: max(0, deadline - clock.now())) } catch { return }
      if Task.isCancelled { return }
      self.fireSlowJobs()
    }
  }

  func fireSlowJobs() {
    slowTimer = nil
    slowTimerAt = .infinity
    let now = effects.clock.now()
    var due: [SlowJob] = []
    for job in SlowJob.allCases {
      guard var entry = slowEntries[job], entry.armed, entry.next <= now + LiveEngine.gridSlackMs else { continue }
      entry.next = slotAfter(max(now, entry.next), every(job))
      slowEntries[job] = entry
      due.append(job)
    }
    slowFiring = true
    for job in due where needed(job) { Task { await self.runJob(job) } }
    slowFiring = false
    rescheduleSlowJobs()
  }

  public func meetingTick() async {
    guard !effects.environment.safeMode else { return }
    guard let host = meetingHost else { return }
    guard let browser = await host.meetingSnapshot() else { return }
    let result = MeetingGroups.tick(state.meetingGroups, browser: browser, now: effects.clock.now())
    mutate { $0.meetingGroups = result.state }
    for id in result.close { await host.closeGroup(id) }
  }
}
