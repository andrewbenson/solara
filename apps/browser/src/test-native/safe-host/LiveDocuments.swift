import Foundation

enum NSApplication {
  static let willTerminateNotification = Notification.Name("fixture.quit")
}

extension Bundle {
  var productName: String { "Fixture" }
}

enum ShellModule {
  static var directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("documents")
  static func documentURL(_ name: String) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent((name as NSString).lastPathComponent)
  }
}

__PRODUCTION__

final class LiveFakes: LiveHTTPClient, LiveSecretStore, LiveClock, LiveCalendarProvider, LiveAuthPresenter, LiveNotifier, LiveDocumentStore, LiveMeetingHost, @unchecked Sendable {
  var fileBacked = false
  var documents: [String: String] = [:]
  var writes = 0
  var fetched = 0
  var refuseWrites = false
  var calendarReads = 0
  var notifications = 0
  var meetingReads = 0
  var immediateNudge = false
  var deletions = 0
  var sleepers = 0
  func send(_ request: LiveHTTPRequest) async throws -> LiveHTTPResponse { LiveHTTPResponse(status: 404) }
  func secret(account: String) async -> String? { nil }
  func setSecret(_ secret: String, account: String) -> Bool { true }
  func deleteSecret(account: String) async -> Bool { deletions += 1; return true }
  func now() -> Double { 1_790_000_000_000 }
  func sleep(milliseconds: Double) async throws {
    if immediateNudge, milliseconds == LiveEngine.nudgeDelayMs { return }
    sleepers += 1
    try await Task.sleep(nanoseconds: 500_000_000_000)
  }
  func authorization() async -> CalendarAuthorization { calendarReads += 1; return .denied }
  func requestAccess() async -> Bool { false }
  func calendars() async throws -> [SystemCalendar] { [] }
  func events(start: Double, end: Double, calendarIds: [String]) async throws -> [CalendarEvent] { [] }
  func authorize(url: String, redirectPrefix: String) async throws -> String { throw LiveError(.other, "unused") }
  func post(_ notification: LiveNotification) async -> Bool { notifications += 1; return true }
  func meetingSnapshot() async -> MeetingBrowserSnapshot? { meetingReads += 1; return MeetingBrowserSnapshot(groups: [:], tabs: [:], activeTabByWindow: [:]) }
  func closeGroup(_ groupId: String) async {}
  func remove(ids: [String]) async {}
  func read(_ name: String) -> String? { fileBacked ? DocumentStore.read(name) : documents[name] }
  func write(_ name: String, _ text: String) throws {
    if refuseWrites { throw LiveError(.other, "Fixture disk refused the save") }
    if fileBacked { try DocumentStore.write(name, text) } else { documents[name] = text }
    writes += 1
  }
  func engine(safe: Bool) -> LiveEngine {
    let environment = LiveEnvironment(safeMode: safe)
    return LiveEngine(effects: LiveEffects(http: self, secrets: self, clock: self, calendar: self,
      auth: self, notifier: self, documents: self, environment: environment))
  }
}

extension LiveEngine {
  func fixtureAlertAndMeetingHost(_ host: LiveFakes) {
    appActive = false
    calendarData.events = [CalendarEvent(id: "alert", occurrence: "alert", calendarId: "fixture", title: "Alert", start: effects.clock.now() + 30_000, end: effects.clock.now() + 60_000)]
    meetingHost = host
  }
}

func command(_ name: String, _ payload: String = "{}") throws -> LiveCommand {
  try LiveJSON.decode(LiveCommand.self, from: #"{"name":"\#(name)","payload":\#(payload)}"#)
}

Task {
  do {
  var rows: [[String: Any]] = []
  for safe in [true, false] {
    DocumentStore.safeMode = safe
    ShellModule.directory = ShellModule.directory.deletingLastPathComponent().appendingPathComponent("documents-\(safe)")
    let fakes = LiveFakes()
    fakes.fileBacked = true
    let engine = fakes.engine(safe: safe)
    let host = FixtureHost(engine)
    let created = try LiveJSON.decode(LiveCommandResult.self, from: await host.command(name: "createFolder", payloadJSON: #"{"profileId":"p","kind":"documents","sources":[]}"#))
    _ = try await host.command(name: "updateCalendarSettings", payloadJSON: #"{"patch":{"alertLead":"10","hiddenCalendarIds":["private"]}}"#)
    if !safe { try await engine.flush(); _ = DocumentStore.flush() }
    DocumentStore.safeMode = false
    let normal = fakes.engine(safe: false)
    let loaded = await normal.snapshot
    rows.append(["path": "user", "safe": safe, "folder": loaded.live.folders[created.folderId!]?.profileId ?? "",
      "alertLead": loaded.live.calendar.alertLead, "hidden": loaded.live.calendar.hiddenCalendarIds, "writes": fakes.writes])
    await engine.stop()

    let jobs = LiveFakes()
    let automatic = jobs.engine(safe: safe)
    await automatic.start(jobs: [])
    let started = await automatic.started
    await automatic.stop()
    _ = try await automatic.perform(command("createFolder", #"{"profileId":"p","kind":"documents","sources":[]}"#))
    try await automatic.flush()
    let before = jobs.documents
    let writesBefore = jobs.writes
    await automatic.profilesChanged(existing: [])
    let remaining = await automatic.snapshot.live.folders.count
    let prompted = await automatic.offerAlertsForPinnedTab(url: "https://calendar.google.com")
    if !safe { try await automatic.flush() }
    rows.append(["path": "automatic", "safe": safe, "started": started, "remaining": remaining,
      "prompted": prompted, "writes": jobs.writes - writesBefore, "preserved": before == jobs.documents])
    await automatic.stop()

    DocumentStore.safeMode = safe
    let fetches = LiveFakes()
    let fetching = fetches.engine(safe: safe)
    await fetching.setSource(LiveSource(id: .notion, name: "Fixture", kind: .documents, site: "fixture.invalid", fetch: { _, _ in
      fetches.fetched += 1
      return [LiveItem(id: "derived", source: .notion, url: "https://fixture.invalid", title: "Derived", subtitle: "", updatedAt: 0)]
    }))
    let folder = await fetching.newProfileLiveFolder(profileId: "p", kind: .documents)
    await fetching.inflight[folder]?.value
    let automaticFetches = fetches.fetched
    try await fetching.flush()
    await fetching.acknowledgeDocumentSave(try await fetching.persistedDocumentJSON())
    let beforeRefresh = fetches.writes
    var refreshError = ""
    do { _ = try await FixtureHost(fetching).command(name: "manualRefresh", payloadJSON: #"{"folderId":"\#(folder)"}"#) }
    catch { refreshError = (error as? LiveError)?.message ?? String(describing: error) }
    let refreshWrites = fetches.writes - beforeRefresh
    _ = try await FixtureHost(fetching).command(name: "updateCalendarSettings", payloadJSON: #"{"patch":{"alertLead":"15"}}"#)
    try await fetching.flush()
    let rendered = await fetching.snapshot.live.items[folder]?.map(\.id) ?? []
    let savedState = LiveState.load(fetches.documents["live.json"])
    rows.append(["path": "fetch", "safe": safe, "automaticFetches": automaticFetches, "fetched": fetches.fetched,
      "refreshError": refreshError, "refreshWrites": refreshWrites, "rendered": rendered, "savedItems": savedState.items[folder]?.map(\.id) ?? [],
      "savedLead": savedState.calendar.alertLead])
    if safe {
      _ = try await FixtureHost(fetching).command(name: "markRead", payloadJSON: #"{"folderId":"\#(folder)","itemIds":["derived"]}"#)
      _ = try await FixtureHost(fetching).command(name: "markUnread", payloadJSON: #"{"folderId":"\#(folder)","itemId":"unread"}"#)
      let next = fetches.engine(safe: false)
      let items = [
        LiveItem(id: "derived", source: .notion, url: "https://fixture.invalid", title: "Read", subtitle: "", updatedAt: 0),
        LiveItem(id: "unread", source: .notion, url: "https://fixture.invalid", title: "Unread", subtitle: "", updatedAt: 0),
      ]
      await next.applyFetch(folder, items, gone: [:])
      let reloaded = await next.snapshot.live
      rows.append(["path": "read", "unread": reloaded.unread[folder] ?? [], "known": reloaded.known[folder] ?? []])
      await next.stop()
    }
    await fetching.stop()

    DocumentStore.safeMode = true
    let refused = LiveFakes()
    refused.refuseWrites = true
    let failing = refused.engine(safe: true)
    var saveError = ""
    do { _ = try await FixtureHost(failing).command(name: "updateCalendarSettings", payloadJSON: #"{"patch":{"alertLead":"15"}}"#) }
    catch { saveError = (error as? LiveError)?.message ?? String(describing: error) }
    var retryError = ""
    do { _ = try await FixtureHost(failing).command(name: "updateCalendarSettings", payloadJSON: #"{"patch":{"alertLead":"15"}}"#) }
    catch { retryError = (error as? LiveError)?.message ?? String(describing: error) }
    rows.append(["path": "failure", "safe": safe, "error": saveError, "retryError": retryError, "saved": refused.documents["live.json"] != nil])
    await failing.stop()

    let background = LiveFakes()
    background.immediateNudge = true
    let observed = background.engine(safe: safe)
    await observed.setSource(LiveSource(id: .notion, name: "Fixture", kind: .documents, site: "fixture.invalid", fetch: { _, _ in
      background.fetched += 1
      return []
    }))
    let observedFolder = await observed.createFolder(profileId: "p", kind: .documents)
    await observed.windowFocused()
    await observed.inflight[observedFolder]?.value
    let focusFetches = background.fetched
    await observed.liveTabDeactivated(folderId: observedFolder)
    for _ in 0..<20 { await Task.yield() }
    await observed.inflight[observedFolder]?.value
    let nudgeFetches = background.fetched - focusFetches
    await observed.calendarChanged()
    await observed.calendarInflight?.value
    await observed.fixtureAlertAndMeetingHost(background)
    await observed.checkAlerts()
    await observed.setMeetingGroup(MeetingGroup(groupId: "missing", callTabId: "missing", occurrence: nil, title: "Missing", start: nil, end: nil, endedAt: nil))
    await observed.meetingTick()
    let groups = await observed.snapshot.live.meetingGroups.count
    rows.append(["path": "observers", "safe": safe, "focusFetches": focusFetches, "nudgeFetches": nudgeFetches,
      "calendarReads": background.calendarReads, "notifications": background.notifications, "meetingReads": background.meetingReads, "groups": groups])
    await observed.stop()

    DocumentStore.safeMode = safe
    let quitBox = NativeLiveReplicaBox(text: nil, failure: nil)
    let quitText = "quit-\(safe)"
    quitBox.setPersistedText(quitText)
    quitBox.flushAtQuit()
    _ = DocumentStore.flush()
    rows.append(["path": "quit", "safe": safe, "saved": DocumentStore.read("live.json") == quitText])
  }
  let data = try JSONSerialization.data(withJSONObject: rows)
  print(String(data: data, encoding: .utf8)!)
  exit(0)
  } catch {
    FileHandle.standardError.write(Data(String(describing: error).utf8))
    exit(1)
  }
}
dispatchMain()
