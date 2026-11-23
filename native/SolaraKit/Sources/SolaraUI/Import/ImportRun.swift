import Foundation
import SolaraEngine
import SolaraModel

public struct ImportCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let url: String
  public let username: String
  public let password: String
  public let realm: String?

  public init(url: String, username: String, password: String, realm: String?) {
    self.url = url
    self.username = username
    self.password = password
    self.realm = realm
  }

  public var description: String { "ImportCredential" }
  public var debugDescription: String { "ImportCredential" }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct ImportReadWarning: Sendable, Equatable {
  public let kind: ImportKind?
  public let code: String
  public let message: String

  public init(kind: ImportKind?, code: String, message: String) {
    self.kind = kind
    self.code = code
    self.message = message
  }
}

public struct ImportRead: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let vaultToken: String?
  public let profileName: String?
  public let profileColor: String?
  public let failed: [ImportKind]
  public let warnings: [ImportReadWarning]
  public var credentials: [ImportCredential]
  public let bookmarks: ImportBookmarkNode?
  public let tabs: [ImportTabRow]
  public let favorites: [ImportTabRow]
  public let hasSpaces: Bool
  public let history: [ImportHistoryRow]
  public let favicons: [ImportFaviconRow]

  public init(vaultToken: String?, profileName: String?, profileColor: String?, failed: [ImportKind], warnings: [ImportReadWarning], credentials: [ImportCredential],
              bookmarks: ImportBookmarkNode? = nil, tabs: [ImportTabRow] = [], favorites: [ImportTabRow] = [], hasSpaces: Bool = false,
              history: [ImportHistoryRow] = [], favicons: [ImportFaviconRow] = []) {
    self.vaultToken = vaultToken
    self.profileName = profileName
    self.profileColor = profileColor
    self.failed = failed
    self.warnings = warnings
    self.credentials = credentials
    self.bookmarks = bookmarks
    self.tabs = tabs
    self.favorites = favorites
    self.hasSpaces = hasSpaces
    self.history = history
    self.favicons = favicons
  }

  public var description: String { "ImportRead" }
  public var debugDescription: String { "ImportRead" }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct ImportNativeWritten: Sendable, Equatable {
  public let cookies: Int
  public let addresses: Int
  public let cards: Int
  public let cookiesFailed: Bool
  public let autofillFailed: Bool

  public init(cookies: Int, addresses: Int, cards: Int, cookiesFailed: Bool, autofillFailed: Bool) {
    self.cookies = cookies
    self.addresses = addresses
    self.cards = cards
    self.cookiesFailed = cookiesFailed
    self.autofillFailed = autofillFailed
  }
}

enum ImportDestination: Equatable {
  case profile(String)
  case halted
  case unavailable
}

public enum ImportReadFailure: Error, Sendable {
  case cancelled
  case failed
}

@MainActor
public protocol ImportEngine: AnyObject {
  var safeMode: Bool { get }
  func transientImportRefused()
  func isUnlocked(_ browserId: String) -> Bool
  func unlock(_ browserId: String) async -> Bool
  func read(jobId: String, browserId: String, profileId: String, kinds: [ImportKind], progress: @escaping @MainActor (ImportKind, Bool) -> Void) async throws -> ImportRead
  func cancelRead(jobId: String)
  func discard(token: String)
  func writeNative(token: String, engineProfile: String, kinds: [String]) async -> ImportNativeWritten?
  func savePassword(engineProfile: String, origin: String, username: String, password: String) async -> Bool
  func bookmarkParents(_ profile: String) -> ImportBookmarkParents?
  func submitBookmarks(profile: String, mutations: [BookmarkMutation]) async throws
  func reportBookmarkFailure()
  func chooseImportFile(_ kind: ImportFileKind) async -> String?
  func readBookmarksFile(path: String) async -> ImportBookmarkNode?
  func importWorkspace(profile: String, windows: [JSONValue]) -> Int?
  func adoptHistory(profile: String, rows: [ImportHistoryRow], deadline: TimeInterval) async -> Int?
  func importHistory(engineProfile: String, rows: [ImportHistoryRow]) async
  func adoptFavicons(profile: String, favicons: [ImportFaviconRow]) async
  func storeFavicons(engineProfile: String, favicons: [ImportFaviconRow]) async
  func extensions(browserId: String, profileId: String) async -> [ImportedExtension]
  func forget()
  func profiles() -> [ImportTarget]
  func profileExists(_ id: String) -> Bool
  func isPrivateProfile(_ id: String) -> Bool
  func engineProfile(_ id: String) -> String
  func askImportAsNewProfile() async -> Bool?
  func dismissImportAsNewProfile()
  func createProfile(name: String, color: String?) -> String?
  func publish(_ progress: ImportProgressUpdate)
  func log(_ line: String)
}

@MainActor
public protocol ImportScriptPath: AnyObject {
  func scriptRun(_ request: ImportRunRequest, session: Int) async -> ImportRunOutcome
  func scriptCancel()
  func scriptDispose()
  func scriptBookmarksHTML(target: String, session: Int) async -> ImportFileOutcome
}

public enum ImportRoute: String, Sendable {
  case swift
  case js

  static let swiftKinds: Set<ImportKind> = [.passwords, .cookies, .autofill, .bookmarks, .history, .tabs, .favorites]
  static let scriptRouteKey = "ImportRoute"

  public static func of(_ source: ImportBrowser?, kinds: [ImportKind]) -> ImportRoute {
    guard let source, [.chromium, .firefox, .arc].contains(source.family) else { return .js }
    guard !kinds.isEmpty, kinds.allSatisfy(swiftKinds.contains) else { return .js }
    if source.sidebar != nil, kinds.contains(.tabs) { return .js }
    return .swift
  }
}

public enum ImportOrigin {
  nonisolated(unsafe) static let pattern = try! NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9+.-]*://[^/?#]+)")

  public static func of(url: String, realm: String?) -> String? {
    let source: String
    if let realm, realm.utf16.starts(with: "http".utf16) { source = realm } else { source = url }
    let text = source as NSString
    guard let match = pattern.firstMatch(in: source, range: NSRange(location: 0, length: text.length)) else { return nil }
    let origin = text.substring(with: match.range(at: 1))
    return origin.isEmpty ? nil : origin
  }
}

public enum ImportProfileColor {
  static let hues: [(String, Double)] = [("red", 0), ("orange", 25), ("yellow", 45), ("green", 140), ("blue", 210), ("purple", 265), ("pink", 330), ("red", 360)]

  public static func of(_ hex: String?) -> String? {
    guard let hex else { return nil }
    let units = Array(hex.utf16)
    var start = 0
    if units.first == UInt16(UInt8(ascii: "#")) { start = 1 }
    guard units.count >= start + 6 else { return nil }
    let digits = units[start..<start + 6]
    guard digits.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
    guard let v = Int(String(decoding: Array(digits), as: UTF16.self), radix: 16) else { return nil }
    let r = Double((v >> 16) & 255) / 255
    let g = Double((v >> 8) & 255) / 255
    let b = Double(v & 255) / 255
    let high = max(r, g, b)
    let low = min(r, g, b)
    if high - low < 0.08 { return "neutral" }
    var h: Double
    if high == r { h = ((g - b) / (high - low) + 6).truncatingRemainder(dividingBy: 6) }
    else if high == g { h = (b - r) / (high - low) + 2 }
    else { h = (r - g) / (high - low) + 4 }
    h *= 60
    var best = hues[0]
    for c in hues where abs(c.1 - h) < abs(best.1 - h) { best = c }
    return best.0
  }
}

public enum ImportProfileName {
  public static func same(_ a: String, _ b: String) -> Bool {
    a.jsTrim().jsLowercased().jsEquals(b.jsTrim().jsLowercased())
  }
}

@MainActor
final class ImportRunControl {
  var stopped = false
  var onStop: (() -> Void)?
  var jobId: String?
  let engine: ImportEngine

  init(engine: ImportEngine) { self.engine = engine }

  func stop() {
    stopped = true
    onStop?()
    onStop = nil
    if let jobId { engine.cancelRead(jobId: jobId) }
  }
}

@MainActor
public final class ImportRuns {
  public static let shared = ImportRuns()

  public private(set) var generation = 0
  public private(set) var session = 0
  public private(set) var revoked = 0
  public private(set) var drains = 0
  public var browsers: [ImportBrowser] = []
  private var active = 0
  private var idle: [CheckedContinuation<Void, Never>] = []
  var current: ImportRunControl?
  private var routes: [String: ImportRoute] = [:]
  let bookmarkQueue = ImportBookmarkQueue()
  private var writes: [UUID: Task<Void, Never>] = [:]
  var scriptRouteDefault: () -> String? = { UserDefaults.standard.string(forKey: ImportRoute.scriptRouteKey) }
  var writeDeadline: Duration = .seconds(10)
  var drainDeadline: Duration = .seconds(10)
  #if DEBUG
  public var forceScript = false
  public var devTrace: [String] = []
  #endif

  func traceStep(_ step: String) {
    #if DEBUG
    devTrace.append(step)
    #endif
  }

  @discardableResult
  func track(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    let id = UUID()
    let write = Task { @MainActor [weak self] in
      await work()
      self?.writes[id] = nil
    }
    writes[id] = write
    return write
  }

  func settle(_ write: Task<Void, Never>, within deadline: Duration, until control: ImportRunControl? = nil) async -> Bool {
    if control?.stopped == true { return false }
    let first = FirstAnswer()
    defer { control?.onStop = nil }
    return await withCheckedContinuation { continuation in
      first.continuation = continuation
      control?.onStop = { first.answer(false) }
      let timer = Task { @MainActor in
        try? await Task.sleep(for: deadline)
        first.answer(false)
      }
      Task { @MainActor in
        await write.value
        timer.cancel()
        first.answer(true)
      }
    }
  }

  #if DEBUG
  public var pendingWrites: Int { writes.count }
  #endif

  public init() {}

  public func open() -> Int {
    session += 1
    return session
  }

  public func admitted(_ id: Int?) -> Bool {
    if drains > 0 { return false }
    guard let id else { return generation == 0 }
    return id > revoked && id <= session
  }

  public func route(of runId: String) -> ImportRoute? { routes[runId] }

  public func run(_ request: ImportRunRequest, session id: Int, engine: ImportEngine, script: ImportScriptPath, scriptSession: Int) async -> ImportRunOutcome {
    let source = browsers.first { $0.id == request.browserId }
    let route = preferred(ImportRoute.of(source, kinds: request.kinds), engine: engine)
    routes[request.runId] = route
    engine.log("[import] run \(request.runId) route=\(route.rawValue) family=\(source?.family.rawValue ?? "unknown")")
    guard route == .swift else { return await script.scriptRun(request, session: scriptSession) }
    guard admitted(id) else { return .cancelledRun }
    return await whileActive { await ImportRunner(runs: self, engine: engine, session: id).run(request) }
  }

  public func importBookmarksFile(target: String, session id: Int, engine: ImportEngine, script: ImportScriptPath, scriptSession: Int) async -> ImportFileOutcome {
    let route = preferred(.swift, engine: engine)
    engine.log("[import] file bookmarksHTML route=\(route.rawValue)")
    guard route == .swift else { return await script.scriptBookmarksHTML(target: target, session: scriptSession) }
    let runner = ImportRunner(runs: self, engine: engine, session: id)
    guard !runner.cancelled(), let path = await engine.chooseImportFile(.bookmarksHTML), !runner.cancelled() else { return .cancelled }
    return await whileActive { await runner.placeBookmarksFile(path: path, target: target) }
  }

  private func preferred(_ route: ImportRoute, engine: ImportEngine) -> ImportRoute {
    var route = route
    if route == .swift, scriptRouteDefault() == "script" {
      route = .js
      engine.log("[import] route=js reason=defaults")
    }
    #if DEBUG
    if forceScript { route = .js }
    #endif
    return route
  }

  private func whileActive<T>(_ work: () async -> T) async -> T {
    active += 1
    defer {
      active -= 1
      if active == 0 {
        let waiting = idle
        idle = []
        waiting.forEach { $0.resume() }
      }
    }
    return await work()
  }

  public func cancel(engine: ImportEngine, script: ImportScriptPath) {
    current?.stop()
    script.scriptCancel()
  }

  public func dispose(engine: ImportEngine, script: ImportScriptPath) {
    stop(engine)
    script.scriptDispose()
  }

  public func drain(engine: ImportEngine) async {
    generation += 1
    revoked = session
    stop(engine)
    drains += 1
    defer { drains -= 1 }
    if active > 0 { await withCheckedContinuation { idle.append($0) } }
    let clock = ContinuousClock()
    let end = clock.now + drainDeadline
    while let write = writes.values.first, clock.now < end {
      if !(await settle(write, within: end - clock.now)) { break }
    }
    if !writes.isEmpty { engine.log("[import] drain left \(writes.count) write\(writes.count == 1 ? "" : "s") running") }
  }

  private func stop(_ engine: ImportEngine) {
    current?.stop()
    current = nil
    engine.dismissImportAsNewProfile()
    engine.forget()
  }
}

@MainActor
private final class FirstAnswer {
  var continuation: CheckedContinuation<Bool, Never>?

  func answer(_ value: Bool) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

@MainActor
final class ImportRunner {
  static let kindOrder: [ImportKind] = [.bookmarks, .history, .passwords, .cookies, .autofill, .tabs, .spaces, .pinnedTabs, .favorites]
  static let stoppedNote = "Import was cancelled. Anything saved before that is kept."

  static func noDestinationNote(_ name: String) -> String {
    "Nothing from \(name) was imported, because Solara couldn't set up a profile for it."
  }

  let runs: ImportRuns
  let engine: ImportEngine
  let session: Int
  let generation: Int
  private var runId = ""
  private var preparing = 0
  private var status: [ImportKind: ImportStatus] = [:]
  private var finished = false

  init(runs: ImportRuns, engine: ImportEngine, session: Int) {
    self.runs = runs
    self.engine = engine
    self.session = session
    self.generation = runs.generation
  }

  func cancelled() -> Bool { generation != runs.generation || !runs.admitted(session) }

  private func publish() {
    engine.publish(ImportProgressUpdate(runId: runId, preparing: preparing, status: status))
  }

  private func progressed(_ kind: ImportKind, _ ended: Bool) {
    guard !cancelled(), !finished else { return }
    if ended {
      if status[kind] != .failed { status[kind] = .done }
    } else {
      status[kind] = .active
    }
    publish()
  }

  func run(_ request: ImportRunRequest) async -> ImportRunOutcome {
    guard let source = runs.browsers.first(where: { $0.id == request.browserId }) else { return .cancelledRun }
    let bySpaces = source.sidebar != nil
    let selected = source.profiles.filter { p in request.profileIds.contains(p.id) || (bySpaces && p.spaces.contains { request.spaceIds.contains($0.id) }) }
    let transient: Set<ImportKind> = [.tabs, .spaces, .pinnedTabs, .favorites]
    let refused = engine.safeMode ? request.kinds.filter { selected.count > 1 || transient.contains($0) } : []
    if !refused.isEmpty { engine.transientImportRefused() }
    if engine.safeMode, selected.count > 1 {
      return ImportRunOutcome(
        status: Dictionary(refused.map { ($0, ImportStatus.failed) }, uniquingKeysWith: { a, _ in a }),
        failures: refused.map { ImportFailure(kind: $0, profiles: selected.map(\.name)) },
        notes: ["Import one source profile into an existing profile in safe mode."]
      )
    }
    let tabsLocked = { (p: ImportSourceProfile) in request.withoutKey && p.tabsNeedKey }
    let requested = request.kinds.filter { !refused.contains($0) }.filter { $0 != .tabs || !selected.allSatisfy(tabsLocked) }
    let order = Self.kindOrder.filter(requested.contains)
    runId = request.runId
    preparing = bySpaces ? max(1, request.spaceIds.count) : selected.count
    for kind in order { status[kind] = .pending }
    for kind in refused { status[kind] = .failed }
    publish()

    runs.current?.stop()
    let control = ImportRunControl(engine: engine)
    runs.current = control
    defer { if runs.current === control { runs.current = nil } }

    var total = ImportCounts()
    var failed: [(ImportKind, [String])] = refused.map { ($0, selected.map(\.name)) }
    func fail(_ kind: ImportKind, _ name: String) {
      if let i = failed.firstIndex(where: { $0.0 == kind }) {
        if !failed[i].1.contains(name) { failed[i].1.append(name) }
      } else {
        failed.append((kind, [name]))
      }
    }
    var destinationIndex = 0
    var notes: [String] = []
    var found: [ImportedExtension] = []
    var extensionsProfile = ""
    defer { finished = true }
    func halted() -> ImportRunOutcome { !cancelled() && control.stopped ? stoppedOutcome(total, order) : .cancelledRun }

    if source.family == .firefox, requested.contains(.passwords), !engine.isUnlocked(source.id) {
      _ = await engine.unlock(source.id)
      if cancelled() || control.stopped {
        engine.forget()
        return halted()
      }
    }
    defer { engine.forget() }

    for profile in selected {
      if cancelled() || control.stopped { return halted() }
      let profileKinds = tabsLocked(profile) ? order.filter { $0 != .tabs } : order
      let jobId = UUID().uuidString
      control.jobId = jobId
      var read: ImportRead
      do {
        read = try await engine.read(jobId: jobId, browserId: source.id, profileId: profile.id, kinds: profileKinds) { [weak self] kind, ended in
          self?.progressed(kind, ended)
        }
      } catch ImportReadFailure.cancelled {
        return halted()
      } catch {
        if cancelled() || control.stopped { return halted() }
        for kind in profileKinds { fail(kind, profile.name) }
        continue
      }
      control.jobId = nil
      var token = read.vaultToken
      defer {
        if let left = token { engine.discard(token: left) }
        token = nil
        read.credentials = []
      }
      if cancelled() || control.stopped { return halted() }
      for kind in read.failed { fail(kind, profile.name) }
      for w in read.warnings where ["undecryptable", "skipped", "locked"].contains(w.code) && !(w.kind.map(read.failed.contains) ?? false) {
        notes.append("\(w.message).")
      }
      let index = destinationIndex
      destinationIndex += 1
      let destinationName = read.profileName ?? profile.name
      let destination: String
      switch await self.destination(request.target, index, destinationName, bySpaces ? read.profileColor : read.profileColor ?? profile.color, stopped: { control.stopped }) {
      case .profile(let id) where !cancelled():
        destination = id
      case .unavailable where !cancelled() && !control.stopped:
        for kind in profileKinds { fail(kind, profile.name) }
        notes.append(Self.noDestinationNote(destinationName))
        continue
      default:
        return halted()
      }

      let browserName = source.name
      runs.traceStep("favicons")
      let chosen = ImportFavicons.chosen(read)
      if !chosen.isEmpty, !engine.isPrivateProfile(destination) {
        await engine.adoptFavicons(profile: destination, favicons: chosen)
        let faviconEngine = engine.engineProfile(destination)
        runs.track { [engine] in await engine.storeFavicons(engineProfile: faviconEngine, favicons: chosen) }
      }
      runs.traceStep("bookmarks")
      let placed = await runs.bookmarkQueue.run {
        await self.placeBookmarks(profile: destination, root: read.bookmarks, browserName: browserName, stopped: { control.stopped })
      }
      if let placed { total.bookmarks += placed } else { engine.reportBookmarkFailure(); fail(.bookmarks, profile.name) }
      if cancelled() || control.stopped { return halted() }

      if !read.history.isEmpty {
        runs.traceStep("history")
        if !engine.isPrivateProfile(destination) {
          let rows = ImportHistory.usable(read.history)
          if !rows.isEmpty {
            let historyEngine = engine.engineProfile(destination)
            let write = runs.track { [engine] in await engine.importHistory(engineProfile: historyEngine, rows: rows) }
            if !(await runs.settle(write, within: runs.writeDeadline, until: control)) { engine.log("[import] history write still running profile=\(destination)") }
            if cancelled() || control.stopped { return halted() }
          }
          #if DEBUG
          let adoptStarted = ContinuousClock.now
          #endif
          let added = await engine.adoptHistory(profile: destination, rows: rows, deadline: ImportHistory.adoptDeadline(rows: rows.count))
          #if DEBUG
          engine.log("[import] history adopt rows=\(rows.count) took=\(ContinuousClock.now - adoptStarted)")
          #endif
          if added == nil { engine.log("[import] history count fell back profile=\(destination)") }
          total.history += added ?? ImportHistory.fallbackCount(rows)
        }
        if cancelled() || control.stopped { return halted() }
      }

      runs.traceStep("native")
      let native = ["cookies", "autofill"].filter { name in profileKinds.contains { $0.rawValue == name } }
      if let taken = token {
        token = nil
        if native.isEmpty || engine.isPrivateProfile(destination) || !engine.profileExists(destination) {
          engine.discard(token: taken)
        } else if let written = await engine.writeNative(token: taken, engineProfile: engine.engineProfile(destination), kinds: native) {
          if written.cookiesFailed { fail(.cookies, profile.name) }
          if written.autofillFailed { fail(.autofill, profile.name) }
          total.cookies += written.cookies
          total.addresses += written.addresses
          total.cards += written.cards
        } else {
          for name in native { if let kind = ImportKind(rawValue: name) { fail(kind, profile.name) } }
        }
      }
      if cancelled() || control.stopped { return halted() }
      let tabs = !read.tabs.isEmpty && !read.hasSpaces
      let favorites = !read.favorites.isEmpty
      if (tabs || favorites) && engine.safeMode {
        engine.transientImportRefused()
        if tabs { fail(.tabs, profile.name) }
        if favorites { fail(.favorites, profile.name) }
      } else {
        var windows: [JSONValue] = []
        if tabs { windows.append(.object(["tabs": .array(read.tabs.map { $0.json() }), "group": "Imported"])) }
        if favorites { windows.append(.object(["tabs": .array(read.favorites.map { $0.json(pinned: true) }), "pinnedAgainst": "tiles"])) }
        if !windows.isEmpty {
          runs.traceStep("workspace")
          if let added = engine.importWorkspace(profile: destination, windows: windows) {
            total.tabs += added
          } else {
            if tabs { fail(.tabs, profile.name) }
            if favorites { fail(.favorites, profile.name) }
          }
        }
      }

      let credentials = read.credentials
      read.credentials = []
      if !credentials.isEmpty { runs.traceStep("passwords") }
      for credential in credentials {
        if control.stopped { return stoppedOutcome(total, order) }
        guard !credential.password.isEmpty, let origin = ImportOrigin.of(url: credential.url, realm: credential.realm) else { continue }
        if await engine.savePassword(engineProfile: engine.engineProfile(destination), origin: origin, username: credential.username, password: credential.password) {
          total.passwords += 1
        }
      }
      if control.stopped { return stoppedOutcome(total, order) }
      if cancelled() { return .cancelledRun }
      if extensionsProfile.isEmpty { extensionsProfile = destination }
      if source.family == .chromium || source.family == .arc {
        let listed = await engine.extensions(browserId: source.id, profileId: profile.id)
        if cancelled() { return .cancelledRun }
        for e in listed {
          if let i = found.firstIndex(where: { $0.id == e.id }) { found[i] = e } else { found.append(e) }
        }
      }
    }
    var final: [ImportKind: ImportStatus] = [:]
    for (kind, value) in status {
      final[kind] = failed.contains(where: { $0.0 == kind }) ? .failed : value == .failed ? .failed : .done
    }
    return ImportRunOutcome(
      status: final,
      failures: failed.map { ImportFailure(kind: $0.0, profiles: selected.count > 1 ? $0.1 : []) },
      counts: total,
      notes: notes,
      extensionsProfile: extensionsProfile,
      extensions: found
    )
  }

  func placeBookmarks(profile: String, root: ImportBookmarkNode?, browserName: String, stopped: () -> Bool) async -> Int? {
    guard let root, !(root.children ?? []).isEmpty, !cancelled(), !stopped() else { return 0 }
    do {
      if engine.bookmarkParents(profile) == nil {
        try await engine.submitBookmarks(profile: profile, mutations: [BookmarkMutation(method: "addBookmarkTree", args: [.string(profile), .array([])])])
      }
      if cancelled() || stopped() { return 0 }
      let (toolbar, other) = ImportBookmarks.split(root)
      for attempt in 1... {
        guard let parents = engine.bookmarkParents(profile) else { throw ImportBookmarkWriteFailure.noRoots }
        let edits = ImportBookmarks.edits(profile: profile, toolbar: toolbar, other: other, parents: parents, browserName: browserName)
        if edits.isEmpty { break }
        do {
          try await engine.submitBookmarks(profile: profile, mutations: edits)
          break
        } catch ImportBookmarkWriteFailure.conditionFailed where attempt < 3 {
          if cancelled() || stopped() { return 0 }
        }
      }
      return ImportBookmarks.linkCount(toolbar + other)
    } catch {
      return nil
    }
  }

  func placeBookmarksFile(path: String, target: String) async -> ImportFileOutcome {
    let root = await engine.readBookmarksFile(path: path)
    if cancelled() { return .cancelled }
    guard let root else { return .failed(code: "invalid") }
    runs.traceStep("bookmarks")
    let placed = await runs.bookmarkQueue.run {
      await self.placeBookmarks(profile: target, root: root, browserName: "HTML File", stopped: { false })
    }
    guard let placed else {
      engine.reportBookmarkFailure()
      return cancelled() ? .cancelled : .imported(ImportCounts(), failed: [.bookmarks])
    }
    return cancelled() ? .cancelled : .imported(ImportCounts(bookmarks: placed), failed: [])
  }

  func stoppedOutcome(_ total: ImportCounts, _ order: [ImportKind]) -> ImportRunOutcome {
    ImportRunOutcome(
      status: Dictionary(uniqueKeysWithValues: order.map { ($0, ImportStatus.failed) }),
      failures: [],
      counts: total,
      notes: [Self.stoppedNote]
    )
  }

  func destination(_ target: String, _ index: Int, _ name: String, _ color: String?, stopped: () -> Bool) async -> ImportDestination {
    if cancelled() || stopped() { return .halted }
    if index == 0 { return .profile(target) }
    if let clash = engine.profiles().first(where: { ImportProfileName.same($0.name, name) }) {
      guard let asNew = await engine.askImportAsNewProfile() else { return cancelled() || stopped() ? .halted : .unavailable }
      if cancelled() || stopped() { return .halted }
      if !asNew { return .profile(clash.id) }
    }
    if cancelled() || stopped() { return .halted }
    return engine.createProfile(name: name, color: ImportProfileColor.of(color)).map(ImportDestination.profile) ?? .unavailable
  }
}
