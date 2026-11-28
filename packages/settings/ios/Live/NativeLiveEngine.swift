import AppKit
import SolaraShell
import Foundation
import SolaraLive
import SolaraModel
import SolaraStore
import SolaraUI

private struct NativeLiveDocuments: LiveDocumentStore {
  func read(_ name: String) -> String? { DocumentStore.read(name) }
  func readStatus(_ name: String) -> LiveDocumentRead {
    let result = DocumentStore.readResult(name)
    if let text = result["contents"] { return .contents(text) }
    if let failure = result["failure"] { return .failure(failure) }
    return .missing
  }
  func write(_ name: String, _ text: String) throws { try DocumentStore.write(name, text) }
}

final class NativeLiveReplicaBox: @unchecked Sendable {
  private let lock = NSLock()
  private var revision: UInt64 = 0
  private var replicaJSON: String
  private var calendarJSON: String
  private var meetingAlertJSON: String
  private var error: String?
  private var persistedText: String?
  private var event: (@Sendable (UInt64, String, String, String) -> Void)?

  init(text: String?, failure: String?) {
    persistedText = text
    do {
      let initial = try LiveEngine.initialReplica(documentText: text)
      replicaJSON = initial.replicaJSON
      calendarJSON = initial.calendarJSON
      meetingAlertJSON = initial.meetingAlertJSON
    } catch {
      let fallback = try? LiveEngine.initialReplica(documentText: nil)
      replicaJSON = fallback?.replicaJSON ?? "{}"
      calendarJSON = fallback?.calendarJSON ?? "{}"
      meetingAlertJSON = fallback?.meetingAlertJSON ?? "null"
      self.error = "Cannot decode live.json: \(error)"
    }
    if let failure { error = "Cannot read live.json: \(failure)" }
  }

  func current() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    var value: [String: Any] = ["revision": revision, "replicaJSON": replicaJSON, "calendarJSON": calendarJSON, "meetingAlertJSON": meetingAlertJSON]
    if let error { value["error"] = error }
    return value
  }

  func publish(_ snapshot: (revision: UInt64, replicaJSON: String, calendarJSON: String, meetingAlertJSON: String)) {
    lock.lock()
    if snapshot.revision <= revision {
      lock.unlock()
      return
    }
    revision = snapshot.revision
    replicaJSON = snapshot.replicaJSON
    calendarJSON = snapshot.calendarJSON
    meetingAlertJSON = snapshot.meetingAlertJSON
    let event = self.event
    let revision = self.revision
    let replicaJSON = self.replicaJSON
    let calendarJSON = self.calendarJSON
    let meetingAlertJSON = self.meetingAlertJSON
    lock.unlock()
    event?(revision, replicaJSON, calendarJSON, meetingAlertJSON)
  }

  func setPersistedText(_ text: String) {
    lock.lock()
    persistedText = text
    lock.unlock()
  }

  func flushAtQuit() {
    guard !DocumentStore.safeMode else { return }
    lock.lock()
    let text = persistedText
    lock.unlock()
    if let text, DocumentStore.read("live.json") != text {
      try? DocumentStore.write("live.json", text)
    }
  }

  func setEvent(_ event: (@Sendable (UInt64, String, String, String) -> Void)?) {
    lock.lock()
    self.event = event
    lock.unlock()
  }
}

private struct NativeLiveAuth: LiveAuthPresenter {
  @MainActor func authorize(url: String, redirectPrefix: String) async throws -> String {
    let presenter = LiveBrowserAuth(store: { WorkspaceWrites.store }, focus: ShellDrag.focus)
    return try await presenter.authorize(url: url, redirectPrefix: redirectPrefix)
  }
}

final class NativeLiveEngine: @unchecked Sendable {
  static let shared = NativeLiveEngine()

  let engine: LiveEngine
  private let box: NativeLiveReplicaBox
  private let meetingBox = MeetingBrowserSnapshotBox()
  private let calendarProvider: NativeLiveCalendar
  @MainActor private var calendarObserver: NSObjectProtocol?
  @MainActor private var workspaceListener: Int?
  @MainActor private var storeListener: Int?
  @MainActor private weak var store: Store?
  @MainActor private var workspace: (rev: Int, state: BrowserState)?
  @MainActor private var folderIds: Set<String>?
  @MainActor private var appObservers: [NSObjectProtocol] = []

  private init() {
    let result = DocumentStore.readResult("live.json")
    box = NativeLiveReplicaBox(text: result["contents"], failure: result["failure"])
    #if DEBUG
    let mockBase = ProcessInfo.processInfo.environment["SOLARA_LIVE_MOCK"]
    let fixture = ProcessInfo.processInfo.environment["SOLARA_CALENDAR_FIXTURE"] == "1"
    let separate = ProcessInfo.processInfo.environment["SOLARA_SLOW_TIMERS"] == "separate"
    #else
    let mockBase: String? = nil
    let fixture = false
    let separate = false
    #endif
    let isolated = ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] != nil
    calendarProvider = NativeLiveCalendar(fixture: fixture, launchedAt: SystemLiveClock().now())
    engine = LiveEngine(effects: LiveEffects(
      http: NativeLiveHTTP(followsRedirects: !isolated), secrets: NativeLiveSecrets(), clock: SystemLiveClock(), calendar: calendarProvider,
      auth: NativeLiveAuth(), notifier: NativeLiveNotifier(), documents: NativeLiveDocuments(),
      environment: LiveEnvironment(mockBase: mockBase, calendarFixture: fixture, isolatedDataDirectory: isolated, separateSlowTimers: separate, safeMode: DocumentStore.safeMode),
      closeFolderTabs: { id in
        try await MainActor.run {
          guard let store = WorkspaceWrites.store else {
            throw LiveError(.other, "Live Folders are paused because this session saves nothing")
          }
          try LiveWorkspace.closeFolderTabs(id, in: store)
        }
      }))
    let box = self.box
    DocumentStore.registerBeforeQuitFlush { box.flushAtQuit() }
    Task {
      await engine.setPersistedTextSink { box.setPersistedText($0) }
      for await snapshot in await engine.changes() {
        await self.receive(snapshot)
        if let replica = try? await engine.currentReplica(), replica.revision == snapshot.revision { box.publish(replica) }
      }
    }
  }

  func initialReplica() -> [String: Any] { box.current() }

  func setEvent(_ event: (@Sendable (UInt64, String, String, String) -> Void)?) { box.setEvent(event) }

  func setCloseGroupEvent(_ event: (@Sendable (String) -> Void)?) { meetingBox.setCloseGroup(event) }

  func meetingBrowser(_ snapshotJSON: String) throws {
    meetingBox.replace(try LiveJSON.decode(MeetingBrowserSnapshot.self, from: snapshotJSON))
  }

  func command(name: String, payloadJSON: String) async throws -> String {
    let payload = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8), options: .fragmentsAllowed)
    let wire = try JSONSerialization.data(withJSONObject: ["name": name, "payload": payload], options: .fragmentsAllowed)
    let command = try LiveJSON.decode(LiveCommand.self, from: wire)
    return String(decoding: try LiveJSON.encode(await perform(command)), as: UTF8.self)
  }

  func perform(_ command: LiveCommand) async throws -> LiveCommandResult {
    let before = DocumentStore.safeMode ? try await engine.persistedDocumentJSON() : nil
    let result = try await engine.perform(command)
    let dirty = await engine.documentDirty
    if let before, before != (try await engine.persistedDocumentJSON()) || dirty {
      let saved = try await engine.persistedDocumentJSON()
      try await engine.flush()
      guard DocumentStore.flush() else { throw LiveError(.other, "Cannot save Live and calendar changes to disk") }
      await engine.acknowledgeDocumentSave(saved)
    }
    if let replica = try? await engine.currentReplica() { box.publish(replica) }
    return result
  }

  @MainActor func start() {
    guard workspaceListener == nil, !DocumentStore.safeMode, !NativeStoreHandle.frozen else { return }
    workspaceListener = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.bindWorkspace() }
    calendarObserver = calendarProvider.observeChanges { [engine] in Task { await engine.calendarChanged() } }
    let center = NotificationCenter.default
    appObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
      guard let window = note.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self, ShellDrag.windowId(of: window) != nil,
          !NativeStoreHandle.frozen else { return }
        Task { await self.engine.windowFocused() }
      }
    })
    appObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
      guard let self else { return }
      Task { await self.engine.appResignedActive() }
    })
    Task {
      if !NSApp.isActive { await engine.appResignedActive() }
      await engine.start(jobs: Set(LiveJob.allCases), meetingHost: meetingBox)
    }
  }

  @MainActor private func receive(_ snapshot: LiveSnapshot) {
    let ids = Set(snapshot.live.folders.keys)
    if folderIds != ids {
      folderIds = ids
      if let store = WorkspaceWrites.store, store === self.store {
        try? LiveWorkspace.detachItemLinks(in: store, knownFolders: ids)
      }
    }
    NativeSidebarLive.receive(snapshot.live, calendar: snapshot.calendar, revision: snapshot.revision)
  }

  @MainActor private func bindWorkspace() {
    let next = WorkspaceWrites.store
    guard next !== store else { return }
    if let storeListener { store?.unsubscribe(storeListener) }
    store = next
    storeListener = nil
    workspace = nil
    guard let next else { return }
    storeListener = next.subscribe { [weak self, weak next] commit in
      let changes = commit.changes
      guard !changes.tabs.upserted.isEmpty || !changes.windows.isEmpty || !changes.profiles.isEmpty else { return }
      DispatchQueue.main.async { [weak self, weak next] in
        guard let self, let next else { return }
        self.workspaceChanged(commit, in: next)
      }
    }
    workspace = next.snapshot
    try? LiveWorkspace.detachItemLinks(in: next, knownFolders: folderIds)
  }

  @MainActor private func workspaceChanged(_ commit: Commit, in store: Store) {
    guard WorkspaceWrites.store === store, self.store === store, let previous = workspace, commit.rev > previous.rev else { return }
    workspace = (commit.rev, commit.state)
    if !commit.changes.tabs.upserted.isEmpty {
      try? LiveWorkspace.detachItemLinks(in: store, knownFolders: nil, tabIds: commit.changes.tabs.upserted)
    }
    let deactivated = commit.changes.windows.isEmpty ? [] : LiveWorkspace.deactivatedFolders(from: previous.state, to: commit.state)
    let profilesChanged = !commit.changes.profiles.isEmpty
    guard profilesChanged || !deactivated.isEmpty else { return }
    Task { [weak store] in
      guard let store, WorkspaceWrites.store === store else { return }
      if profilesChanged { await engine.profilesChanged(existing: Set(store.state.profiles.keys)) }
      for id in deactivated.sorted() {
        guard WorkspaceWrites.store === store else { break }
        await engine.liveTabDeactivated(folderId: id)
      }
    }
  }
}

#if SOLARA_PROBES
@MainActor
public enum LiveFolderProbes {
  private struct Fixture: Decodable {
    struct Seed: Decodable {
      let profileId: String
      let kind: LiveFolderKind
      let sources: [LiveSourceId]
      let items: [LiveItem]
      let collapsed: Bool
    }

    struct Open: Decodable {
      let windowId: String
      let folderId: String
      let itemId: String
      let background: Bool
    }

    let seed: Seed?
    let open: Open?
  }

  public static func apply(_ data: Data) async throws -> [String: Any] {
    let fixture = try LiveJSON.decode(Fixture.self, from: data)
    let native = NativeLiveEngine.shared
    guard !DocumentStore.safeMode, let store = WorkspaceWrites.store else {
      throw LiveError(.other, "Live workspace unavailable")
    }
    try Task.checkCancellation()
    switch (fixture.seed, fixture.open) {
    case (let seed?, nil):
      guard store.state.profiles[seed.profileId] != nil else { throw LiveError(.other, "Unknown fixture profile") }
      let created = try await native.perform(.createFolder(.object([
        "profileId": .string(seed.profileId), "kind": .string(seed.kind.rawValue),
        "sources": .array(seed.sources.map { .string($0.rawValue) }),
      ])))
      guard let folderId = created.folderId else { throw LiveError(.other, "Fixture folder creation failed") }
      await native.engine.updateFolder(folderId, FolderPatch(collapsed: seed.collapsed))
      await native.engine.applyFetch(folderId, seed.items, gone: [:])
      return ["folderId": folderId]
    case (nil, let open?):
      let state = await native.engine.snapshot.live
      try Task.checkCancellation()
      guard let folder = state.folders[open.folderId],
        let item = state.items[folder.id]?.first(where: { $0.id == open.itemId }),
        let tabId = NativeSidebarLive.open(item, folder: folder, windowId: open.windowId, background: open.background, store: store)
      else { throw LiveError(.other, "Fixture item could not be opened") }
      return ["tabId": tabId]
    default:
      throw LiveError(.other, "Expected one Live Folder fixture action")
    }
  }

  public static func snapshot() async -> [String: Any] {
    let state = await NativeLiveEngine.shared.engine.snapshot.live
    let folders: [[String: Any]] = state.folderOrder.compactMap { id in
      guard let folder = state.folders[id] else { return nil }
      return [
        "id": id, "profileId": folder.profileId, "kind": folder.kind.rawValue,
        "sources": folder.sources.map(\.rawValue), "collapsed": folder.collapsed,
        "items": state.items[id]?.count ?? 0,
        "hidden": state.hidden[id]?.count ?? 0,
        "completed": state.completed[id]?.count ?? 0,
        "status": state.status[id]?.state.rawValue as Any? ?? NSNull(),
      ]
    }
    let calendar = state.calendar
    return [
      "folders": folders,
      "connectedSources": state.accounts.keys.map(\.rawValue).sorted(),
      "calendar": [
        "alertLead": calendar.alertLead,
        "alertCondition": calendar.alertCondition.rawValue,
        "showPreview": calendar.showPreview,
        "showTimeToNext": calendar.showTimeToNext,
        "hiddenCalendarIds": calendar.hiddenCalendarIds,
        "prompted": calendar.prompted,
      ],
    ]
  }
}

public enum PageCalendarRead {
  public static func snapshot() -> [String: Any] {
    let replica = NativeLiveEngine.shared.initialReplica()
    guard let text = replica["calendarJSON"] as? String, let data = text.data(using: .utf8),
      let calendar = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let events = calendar["events"] as? [[String: Any]] else { return ["count": 0, "eventIds": []] }
    var ids: [String] = []
    for event in events.prefix(128) {
      if let id = event["id"] as? String { ids.append(String(id.prefix(256))) }
    }
    return ["count": events.count, "eventIds": ids]
  }
}
#endif
