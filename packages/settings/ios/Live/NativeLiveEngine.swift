import AppKit
import SolaraShell
import Foundation
import SolaraLive

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

final class NativeLiveAuth: LiveAuthPresenter, @unchecked Sendable {
  static let shared = NativeLiveAuth()
  private let lock = NSLock()
  private var pending: [String: CheckedContinuation<String, Error>] = [:]
  private var event: (@Sendable ([String: String]) -> Void)?

  func setEvent(_ event: (@Sendable ([String: String]) -> Void)?) {
    lock.lock()
    self.event = event
    lock.unlock()
  }

  func authorize(url: String, redirectPrefix: String) async throws -> String {
    let requestId = UUID().uuidString
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        pending[requestId] = continuation
        let event = self.event
        lock.unlock()
        guard let event else {
          resolve(requestId: requestId, redirectURL: nil, error: "Live authorization presenter unavailable")
          return
        }
        event(["requestId": requestId, "url": url, "redirectPrefix": redirectPrefix])
        Task {
          try? await Task.sleep(nanoseconds: 600_000_000_000)
          self.abandon(requestId: requestId, error: "Live authorization timed out")
        }
      }
    } onCancel: {
      abandon(requestId: requestId, error: "Live authorization cancelled")
    }
  }

  private func abandon(requestId: String, error: String) {
    lock.lock()
    let waiting = pending[requestId] != nil
    let event = self.event
    lock.unlock()
    guard waiting else { return }
    resolve(requestId: requestId, redirectURL: nil, error: error)
    event?(["requestId": requestId, "cancelled": "1"])
  }

  func resolve(requestId: String, redirectURL: String?, error: String?) {
    lock.lock()
    let continuation = pending.removeValue(forKey: requestId)
    lock.unlock()
    guard let continuation else { return }
    if let error { continuation.resume(throwing: LiveError(.other, error)) }
    else if let redirectURL { continuation.resume(returning: redirectURL) }
    else { continuation.resume(throwing: LiveError(.other, "Live authorization cancelled")) }
  }
}

final class NativeLiveEngine: @unchecked Sendable {
  static let shared = NativeLiveEngine()

  let engine: LiveEngine
  private let box: NativeLiveReplicaBox
  private let meetingBox = MeetingBrowserSnapshotBox()
  private let calendarProvider: NativeLiveCalendar
  private var calendarObserver: NSObjectProtocol?

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
      auth: NativeLiveAuth.shared, notifier: NativeLiveNotifier(), documents: NativeLiveDocuments(),
      environment: LiveEnvironment(mockBase: mockBase, calendarFixture: fixture, isolatedDataDirectory: isolated, separateSlowTimers: separate, safeMode: DocumentStore.safeMode)))
    let box = self.box
    DocumentStore.registerBeforeQuitFlush { box.flushAtQuit() }
    Task {
      await engine.setPersistedTextSink { box.setPersistedText($0) }
      for await snapshot in await engine.changes() {
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
    return String(decoding: try LiveJSON.encode(result), as: UTF8.self)
  }

  @MainActor func start() async {
    if calendarObserver == nil {
      calendarObserver = calendarProvider.observeChanges { [engine] in Task { await engine.calendarChanged() } }
    }
    if !NSApp.isActive { await engine.appResignedActive() }
    await engine.start(jobs: Set(LiveJob.allCases), meetingHost: meetingBox)
  }

  #if DEBUG
  func devSnapshot() async -> [String: Any] {
    let state = await engine.snapshot.live
    let folders: [[String: Any]] = state.folders.keys.sorted().map { id in
      [
        "id": id,
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
  #endif
}

#if SOLARA_PROBES
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
