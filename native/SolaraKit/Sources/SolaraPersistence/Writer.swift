import Foundation
import SolaraModel
import SolaraStore
import Synchronization

public enum FlushResult: Sendable, Equatable, CustomStringConvertible {
  case saved
  case failed(String)
  case timedOut
  case skipped(String)

  public static let safeModeOpenedNoDatabase = FlushResult.skipped("safe mode opened no database")

  public static func flushing(_ writer: PersistenceWriter?, timeout: TimeInterval) -> FlushResult {
    writer?.flush(timeout: timeout) ?? safeModeOpenedNoDatabase
  }

  public var isProblem: Bool {
    switch self {
    case .saved, .skipped: false
    case .failed, .timedOut: true
    }
  }

  public var description: String {
    switch self {
    case .saved: "saved"
    case .failed(let message): "failed: \(message)"
    case .timedOut: "timedOut"
    case .skipped(let reason): "skipped: \(reason)"
    }
  }
}

public final class PersistenceWriter: Sendable {
  public static let rowDelay: TimeInterval = 0.25
  public static let shadowDelay: TimeInterval = 2
  public static let retryDelays: [TimeInterval] = [1, 5, 30]
  public static let keptErrors = 20
  public static let troubleAfter = 3

  struct Pending {
    var rows = false
    var rowsScheduled = false
    var shadow = false
    var shadowScheduled = false
    var flushes = 0
    var written: WorkspaceRows
    var settings: JSONObject?
    var downloads: [Download]
    var exportedSession: JSONValue?
    var exportedDownloads: JSONValue?
    var failedInARow = 0
    var durable = false
    var frozen = false
    var syncAnchor: String?
    var writtenSyncAnchor: String?
  }

  let store: Store
  let database: SolaraDatabase
  let folder: DataFolder
  let queue = DispatchQueue(label: "solara.persistence", qos: .utility)
  let pending: Mutex<Pending>
  let failures = Mutex<[String]>([])
  let subscription: Mutex<Int?> = Mutex(nil)
  let clock: @Sendable () -> Double
  let trouble: @Sendable (String) -> Void
  let scope: PersistenceScope
  let keepsDownloadsFile: Bool

  public init(
    store: Store, database: SolaraDatabase, folder: DataFolder, persisted: PersistedState, scope: PersistenceScope = .everything,
    clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
    trouble: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.store = store
    self.database = database
    self.folder = folder
    self.clock = clock
    self.trouble = trouble
    self.scope = store.config.safeMode ? .settingsAndDownloads : scope
    keepsDownloadsFile = persisted.keepsDownloadsFile
    pending = Mutex(
      Pending(
        rows: true, rowsScheduled: true, written: store.config.safeMode ? WorkspaceRows() : persisted.workspace ?? WorkspaceRows(),
        settings: store.config.safeMode ? store.state.settings.ownValues : persisted.settings,
        downloads: store.config.safeMode ? store.state.downloads.filter { !$0.isPrivate }.map { $0.persisted() } : persisted.downloads,
        exportedDownloads: store.config.safeMode ? ShadowExport.downloadsDocument(store.state) : nil,
        syncAnchor: persisted.syncAnchor, writtenSyncAnchor: persisted.syncAnchor))
    let id = store.subscribe { [weak self] commit in self?.note(commit) }
    subscription.withLock { $0 = id }
    queue.asyncAfter(deadline: .now() + Self.rowDelay) { self.flushRows() }
  }

  deinit {
    if let id = subscription.withLock({ $0 }) { store.unsubscribe(id) }
  }

  public var errors: [String] { failures.withLock { $0 } }

  public func freeze() {
    pending.withLock { $0.frozen = true }
  }
  public var flushCount: Int { pending.withLock { $0.flushes } }

  public var syncAnchor: String? { pending.withLock { $0.syncAnchor } }

  public func setSyncAnchor(_ anchor: String) {
    guard !store.config.safeMode else { return }
    let schedule = pending.withLock { p -> Bool in
      guard p.syncAnchor != anchor else { return false }
      p.syncAnchor = anchor
      p.rows = true
      let schedule = !p.rowsScheduled
      if schedule { p.rowsScheduled = true }
      return schedule
    }
    if schedule { queue.asyncAfter(deadline: .now() + Self.rowDelay) { self.flushRows() } }
  }

  func note(_ commit: Commit) {
    var persistent = commit.changes
    persistent.live = TableChange()
    guard !persistent.isEmpty else { return }
    let (scheduleRows, scheduleShadow) = pending.withLock { p -> (Bool, Bool) in
      p.rows = true
      if commit.durable { p.durable = true }
      p.shadow = true
      let rows = !p.rowsScheduled
      if rows { p.rowsScheduled = true }
      let shadow = !p.shadowScheduled
      if shadow { p.shadowScheduled = true }
      return (rows, shadow)
    }
    if commit.durable {
      queue.async {
        self.flushRows()
        self.writeShadow()
      }
    } else if scheduleRows {
      queue.asyncAfter(deadline: .now() + Self.rowDelay) { self.flushRows() }
    }
    if scheduleShadow { queue.asyncAfter(deadline: .now() + Self.shadowDelay) { self.writeShadow() } }
  }

  @discardableResult
  func flushRows() -> String? {
    let (dirty, durable, anchor) = pending.withLock { p -> (Bool, Bool, String?) in
      if p.frozen { return (false, false, nil) }
      defer {
        p.rows = false
        p.rowsScheduled = false
        p.durable = false
      }
      return (p.rows, p.durable, p.syncAnchor)
    }
    guard dirty else { return nil }
    let (rev, state) = store.committedSnapshot
    let rows = scope == .everything ? WorkspaceRows(store.sessionDocument(of: state)) : WorkspaceRows()
    let settings = state.settings.ownValues
    let downloads = state.downloads.filter { !$0.isPrivate }.map { $0.persisted() }
    let (previous, previousSettings, previousDownloads, previousAnchor) = pending.withLock {
      ($0.written, $0.settings, $0.downloads, $0.writtenSyncAnchor)
    }
    let changed = rows != previous || settings != previousSettings || downloads != previousDownloads || anchor != previousAnchor
    if !changed && !durable { return nil }
    do {
      try database.write(durable: durable) { db in
        guard changed else { return }
        if scope == .everything { try Rows.writeWorkspace(db, rows, previous: previous) }
        if settings != previousSettings { try Rows.writeSettings(db, settings) }
        if downloads != previousDownloads { try Rows.writeDownloads(db, downloads) }
        if let anchor, anchor != previousAnchor { try Rows.setMeta(db, "sync_anchor", anchor) }
        if !store.config.safeMode { try Rows.setMeta(db, "rev", String(rev)) }
      }
      pending.withLock {
        $0.written = rows
        $0.settings = settings
        $0.downloads = downloads
        $0.writtenSyncAnchor = anchor
        if changed { $0.flushes += 1 }
      }
      succeeded()
      return nil
    } catch {
      pending.withLock {
        $0.rows = true
        $0.rowsScheduled = true
        $0.durable = $0.durable || durable
      }
      let message = "rows: \(error)"
      failed(message) { self.flushRows() }
      return message
    }
  }

  @discardableResult
  func writeShadow() -> String? {
    let dirty = pending.withLock { p -> Bool in
      if p.frozen { return false }
      defer {
        p.shadow = false
        p.shadowScheduled = false
      }
      return p.shadow
    }
    guard dirty else { return nil }
    let (rev, state) = store.committedSnapshot
    let marker: JSONValue = ["rev": JSONValue(rev), "at": JSONValue(clock().rounded()), "scope": .string(scope.markerName)]
    let document = scope == .everything ? store.sessionDocument(of: state) : nil
    let session = document?.json()
    let downloads = ShadowExport.downloadsDocument(state)
    let (lastSession, lastDownloads) = pending.withLock { ($0.exportedSession, $0.exportedDownloads) }
    do {
      if let document, let session, session != lastSession {
        try Importer.writeDurably(Data(document.json(marker: marker).text().utf8), to: folder.session)
        pending.withLock { $0.exportedSession = session }
      }
      if downloads != lastDownloads, !keepsDownloadsFile {
        try Importer.writeDurably(ShadowExport.downloadsJSON(state, marker: marker), to: folder.downloads)
        pending.withLock { $0.exportedDownloads = downloads }
      }
      succeeded()
      return nil
    } catch {
      pending.withLock {
        $0.shadow = true
        $0.shadowScheduled = true
      }
      let message = "shadow export: \(error)"
      failed(message) { self.writeShadow() }
      return message
    }
  }

  func succeeded() {
    pending.withLock { $0.failedInARow = 0 }
  }

  func failed(_ message: String, retry: @escaping @Sendable () -> Void) {
    failures.withLock {
      $0.append(message)
      if $0.count > Self.keptErrors { $0.removeFirst($0.count - Self.keptErrors) }
    }
    let attempt = pending.withLock { p -> Int in
      p.failedInARow += 1
      return p.failedInARow
    }
    if attempt >= Self.troubleAfter { trouble("persistence has failed \(attempt) times in a row; last: \(message)") }
    let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
    queue.asyncAfter(deadline: .now() + delay, execute: retry)
  }

  public func markShadowDirty() {
    pending.withLock { $0.shadow = true }
  }

  @discardableResult
  public func flush(timeout: TimeInterval = 0.5) -> FlushResult {
    let done = DispatchSemaphore(value: 0)
    let result = Mutex<FlushResult>(.timedOut)
    enqueueDurableFlush { saved in
      result.withLock { $0 = saved }
      done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return .timedOut }
    return result.withLock { $0 }
  }

  func enqueueDurableFlush(_ complete: @escaping @Sendable (FlushResult) -> Void) {
    queue.async { complete(self.writeEverythingDurably()) }
  }

  @discardableResult
  func writeEverythingDurably() -> FlushResult {
    dispatchPrecondition(condition: .onQueue(queue))
    let frozen = pending.withLock { p -> Bool in
      guard !p.frozen else { return true }
      p.rows = true
      p.durable = true
      return false
    }
    if frozen { return .failed("persistence is frozen") }
    let failures = [flushRows(), writeShadow()].compactMap { $0 }
    if !failures.isEmpty { return .failed(failures.joined(separator: "; ")) }
    if pending.withLock({ $0.rows || $0.shadow }) { return .failed("persistence still has pending writes") }
    return .saved
  }
}

public enum ShadowExport {
  public static func downloadsDocument(_ state: BrowserState) -> JSONValue {
    let downloads = state.downloads.filter { !$0.isPrivate }.map { JSONValue.object($0.persisted().json) }
    return ["version": 2, "downloads": .array(downloads)]
  }

  public static func downloadsJSON(_ state: BrowserState, marker: JSONValue) -> Data {
    var document = downloadsDocument(state).object ?? [:]
    document[Launcher.markerKey] = marker
    return Data(JSONValue.object(document).text().utf8)
  }
}
