import Foundation
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

  public init(vaultToken: String?, profileName: String?, profileColor: String?, failed: [ImportKind], warnings: [ImportReadWarning], credentials: [ImportCredential]) {
    self.vaultToken = vaultToken
    self.profileName = profileName
    self.profileColor = profileColor
    self.failed = failed
    self.warnings = warnings
    self.credentials = credentials
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
}

public enum ImportRoute: String, Sendable {
  case swift
  case js

  static let swiftKinds: Set<ImportKind> = [.passwords, .cookies, .autofill]

  public static func of(_ source: ImportBrowser?, kinds: [ImportKind]) -> ImportRoute {
    guard let source, source.sidebar == nil, source.family == .chromium || source.family == .firefox else { return .js }
    guard !kinds.isEmpty, kinds.allSatisfy(swiftKinds.contains) else { return .js }
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
  var jobId: String?
  let engine: ImportEngine

  init(engine: ImportEngine) { self.engine = engine }

  func stop() {
    stopped = true
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
  #if DEBUG
  public var forceScript = false
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
    var route = ImportRoute.of(source, kinds: request.kinds)
    #if DEBUG
    if forceScript { route = .js }
    #endif
    routes[request.runId] = route
    engine.log("[import] run \(request.runId) route=\(route.rawValue) family=\(source?.family.rawValue ?? "unknown")")
    guard route == .swift else { return await script.scriptRun(request, session: scriptSession) }
    guard admitted(id) else { return .cancelledRun }
    active += 1
    defer {
      active -= 1
      if active == 0 {
        let waiting = idle
        idle = []
        waiting.forEach { $0.resume() }
      }
    }
    return await ImportRunner(runs: self, engine: engine, session: id).run(request)
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
  }

  private func stop(_ engine: ImportEngine) {
    current?.stop()
    current = nil
    engine.dismissImportAsNewProfile()
    engine.forget()
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
    let selected = source.profiles.filter { request.profileIds.contains($0.id) }
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
    preparing = selected.count
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
      switch await self.destination(request.target, index, destinationName, read.profileColor ?? profile.color, stopped: { control.stopped }) {
      case .profile(let id) where !cancelled():
        destination = id
      case .unavailable where !cancelled() && !control.stopped:
        for kind in profileKinds { fail(kind, profile.name) }
        notes.append(Self.noDestinationNote(destinationName))
        continue
      default:
        return halted()
      }

      let native = ["cookies", "autofill"].filter { name in profileKinds.contains { $0.rawValue == name } }
      if control.stopped { return stoppedOutcome(total, order) }
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
      let credentials = read.credentials
      read.credentials = []
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
