import SolaraModel

public struct LocalExtension: Sendable, Equatable {
  public var id: String
  public var syncable: Bool
  public var version: String?
  public var approved: Bool?
  public var fingerprint: String?
  public var userDisabled: Bool?
  public var incognito: Bool?
  public var pinned: Bool?

  public init(
    id: String, syncable: Bool, version: String? = nil, approved: Bool? = nil, fingerprint: String? = nil, userDisabled: Bool? = nil,
    incognito: Bool? = nil, pinned: Bool? = nil
  ) {
    self.id = id
    self.syncable = syncable
    self.version = version
    self.approved = approved
    self.fingerprint = fingerprint
    self.userDisabled = userDisabled
    self.incognito = incognito
    self.pinned = pinned
  }
}

public struct LocalExtensions: Sendable, Equatable {
  public var ready: Bool
  public var extensions: [LocalExtension]
  public var pending: [String]
  public var settling: [String]?
  public var queued: [String]?

  public init(ready: Bool, extensions: [LocalExtension], pending: [String], settling: [String]? = nil, queued: [String]? = nil) {
    self.ready = ready
    self.extensions = extensions
    self.pending = pending
    self.settling = settling
    self.queued = queued
  }
}

public struct ExtensionState: Sendable, Equatable {
  public var on: Bool
  public var inc: Bool
  public var pin: Bool

  public init(on: Bool, inc: Bool, pin: Bool) {
    self.on = on
    self.inc = inc
    self.pin = pin
  }

  public init?(json: JSONValue) {
    guard isExtensionState(json), let object = json.object else { return nil }
    self.init(on: object["on"]!.bool!, inc: object["inc"]!.bool!, pin: object["pin"]!.bool!)
  }

  public var json: JSONValue { ["on": .bool(on), "inc": .bool(inc), "pin": .bool(pin)] }
}

public struct ExtensionApproval: Sendable, Equatable {
  public var v: String
  public var fps: [String]

  public init(v: String, fps: [String]) {
    self.v = v
    self.fps = fps
  }

  public init?(json: JSONValue?) {
    guard let object = json?.object, let v = object["v"]?.string, let items = object["fps"]?.array else { return nil }
    let fps = items.compactMap(\.string)
    guard fps.count == items.count else { return nil }
    self.init(v: v, fps: fps)
  }

  public var json: JSONValue { ["v": .string(v), "fps": .array(fps.map { .string($0) })] }
}

public struct ExtensionIntent: Sendable, Equatable {
  public enum Kind: String, Sendable { case installed, uninstalled }
  public var kind: Kind
  public var g: Double

  public init(kind: Kind, g: Double) {
    self.kind = kind
    self.g = g
  }
}

public enum ExtensionChange: Sendable, Equatable {
  case install(id: String, record: ExtensionState, approval: ExtensionApproval?)
  case reconcile(id: String, record: ExtensionState, approval: ExtensionApproval?)
  case cancel(id: String)

  public var id: String {
    switch self {
    case .install(let id, _, _), .reconcile(let id, _, _), .cancel(let id): id
    }
  }
}

public protocol ExtensionsHost: AnyObject {
  func read() async throws -> LocalExtensions?
  func change(_ change: ExtensionChange) async throws -> Bool
  func intents() -> JSMap<ExtensionIntent>
  func settleIntents(_ published: JSMap<Double>)
  func keepInstalled(_ id: String)
}

public let extensionPrefix = "ext:"
public let extensionApprovalPrefix = "ext:v:"
public let extensionRetryMs: Double = 3_600_000

public func extensionKey(_ id: String) -> String { extensionPrefix + id }
public func extensionApprovalKey(_ id: String) -> String { extensionApprovalPrefix + id }

public func extensionIdOf(_ key: String) -> String {
  key.jsStartsWith(extensionApprovalPrefix) ? key.jsSlice(extensionApprovalPrefix.utf16.count) : key.jsSlice(extensionPrefix.utf16.count)
}

func isStateKey(_ key: String) -> Bool { key.jsStartsWith(extensionPrefix) && !key.jsStartsWith(extensionApprovalPrefix) }

func jsParseInt10(_ text: Substring) -> Double {
  var units = text.utf16.drop { JS.isWhitespace($0) }
  var sign = 1.0
  if let first = units.first, first == 0x2D || first == 0x2B {
    if first == 0x2D { sign = -1 }
    units = units.dropFirst()
  }
  let digits = units.prefix { $0 >= 0x30 && $0 <= 0x39 }
  guard !digits.isEmpty, let value = Double(String(utf16Units: digits)) else { return .nan }
  return sign * value
}

public func compareVersions(_ a: String, _ b: String) -> Int {
  func parts(_ text: String) -> [Double] {
    text.jsSplit(".").map { part in
      let n = jsParseInt10(Substring(part))
      return n.isNaN || n == 0 ? 0 : n
    }
  }
  let pa = parts(a)
  let pb = parts(b)
  for i in 0..<max(pa.count, pb.count) {
    let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
    if d != 0 && !d.isNaN { return d < 0 ? -1 : 1 }
  }
  return 0
}

public func isRemoval(_ value: JSONValue?) -> Bool {
  value?.object?["removed"] == .bool(true)
}

public func isExtensionState(_ value: JSONValue?) -> Bool {
  guard let object = value?.object, !isRemoval(value) else { return false }
  return object["on"]?.bool != nil && object["inc"]?.bool != nil && object["pin"]?.bool != nil
}

let maxFingerprints = 8

func localState(_ e: LocalExtension) -> ExtensionState {
  ExtensionState(on: !(e.userDisabled ?? false), inc: e.incognito ?? false, pin: e.pinned ?? false)
}

func grantable(_ approval: ExtensionApproval?, _ e: LocalExtension) -> Bool {
  guard let approval, !(e.approved ?? false), approval.v == e.version, let fingerprint = e.fingerprint else { return false }
  return approval.fps.contains(fingerprint)
}

func approvalToPublish(_ e: LocalExtension, _ stored: JSONValue?) -> JSONValue? {
  let known = ExtensionApproval(json: stored)
  let storedApproval = known == nil ? nil : stored
  guard e.approved ?? false, let fingerprint = e.fingerprint, let version = e.version, !version.isEmpty else { return storedApproval }
  guard let known, compareVersions(version, known.v) <= 0 else { return ExtensionApproval(v: version, fps: [fingerprint]).json }
  if compareVersions(version, known.v) < 0 || known.fps.contains(fingerprint) { return storedApproval }
  return ExtensionApproval(v: known.v, fps: Array((known.fps + [fingerprint]).sorted(by: jsKeyPrecedes).suffix(maxFingerprints))).json
}

func newerApproval(_ approval: ExtensionApproval?, _ e: LocalExtension) -> Bool {
  guard let approval else { return false }
  return compareVersions(approval.v, e.version ?? "0") > 0
}

public final class ExtensionsAdapter: SyncAdapter {
  public let prefix = extensionPrefix
  public var adoptRemoteOnJoin: Bool { true }
  let host: ExtensionsHost
  var tried = JSMap<Double>()
  var unsettled = OrderedSet<String>()

  public init(host: ExtensionsHost) {
    self.host = host
  }

  func run(_ change: ExtensionChange) async throws -> Bool {
    let ok = try await host.change(change)
    if ok { unsettled.remove(change.id) } else { unsettled.insert(change.id) }
    return ok
  }

  func reconcileOne(
    _ id: String, _ record: JSONValue?, _ approvalValue: JSONValue?, _ local: LocalExtensions, _ intents: JSMap<ExtensionIntent>, _ joined: Bool
  ) async throws -> Bool {
    let e = local.extensions.first { $0.id.jsEquals(id) }
    let pending = local.pending.contains { $0.jsEquals(id) }
    let queued = local.queued?.contains { $0.jsEquals(id) } ?? false
    let approval = ExtensionApproval(json: approvalValue)
    if isRemoval(record) {
      if intents[id]?.kind == .installed { return true }
      if !joined, e?.syncable == true {
        host.keepInstalled(id)
        return true
      }
      return e == nil && (pending || queued) ? try await run(.cancel(id: id)) : true
    }
    guard let record, let state = ExtensionState(json: record) else { return true }
    if let e {
      if !e.syncable { return true }
      if state != localState(e) || grantable(approval, e) || newerApproval(approval, e) {
        return try await run(.reconcile(id: id, record: state, approval: approval))
      }
      return true
    }
    if intents[id]?.kind == .uninstalled { return true }
    return try await run(.install(id: id, record: state, approval: approval))
  }

  public func extract(_ context: ExtractContext) async throws -> Extraction? {
    guard let local = try await host.read(), local.ready else { return nil }
    let intents = host.intents()
    var values = OrderedDict<String, JSONValue>()
    var captured = JSMap<Double>()
    var installed = OrderedSet<String>()
    let settling = OrderedSet(local.pending + (local.settling ?? []) + unsettled.elements)
    for e in local.extensions {
      guard e.syncable, let version = e.version, !version.isEmpty else { continue }
      installed.insert(e.id)
      if settling.contains(e.id) { continue }
      let key = extensionKey(e.id)
      let stored = context.base(key)
      let explicit = intents[e.id]?.kind == .installed
      if !explicit && ((context.known(key) && stored == nil) || isRemoval(stored)) { continue }
      values[key] = localState(e).json
      if explicit { captured[e.id] = intents[e.id]!.g }
      if let approval = approvalToPublish(e, context.base(extensionApprovalKey(e.id))) { values[extensionApprovalKey(e.id)] = approval }
    }
    for (id, intent) in intents where intent.kind == .uninstalled && !installed.contains(id) {
      values[extensionKey(id)] = ["removed": true]
      captured[id] = intent.g
    }
    let host = host
    let queued = context.queued
    return Extraction(
      values: values.map { ($0.key, $0.value) },
      ignore: { values[$0] == nil },
      republish: { key in isStateKey(key) && captured.contains(extensionIdOf(key)) && !queued(key) },
      published: { keys, _ in
        var settled = JSMap<Double>()
        for key in keys where isStateKey(key) {
          let id = extensionIdOf(key)
          if let g = captured[id] { settled[id] = g }
        }
        if !settled.isEmpty { host.settleIntents(settled) }
      })
  }

  public func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    guard let local = try await host.read(), local.ready else { return false }
    let intents = host.intents()
    let shown = JSMap(visible.map { ($0.key, $0.value) })
    var ok = true
    for id in OrderedSet(changed.map(extensionIdOf)) {
      ok = try await reconcileOne(id, shown[extensionKey(id)], shown[extensionApprovalKey(id)], local, intents, records.joined) && ok
    }
    return ok
  }

  public func reconcile(_ visible: [(key: String, value: JSONValue)], _ now: Double) async throws {
    guard let local = try await host.read(), local.ready else { return }
    let intents = host.intents()
    let shown = JSMap(visible.map { ($0.key, $0.value) })
    for (key, record) in visible {
      guard isStateKey(key), isExtensionState(record) else { continue }
      let id = extensionIdOf(key)
      let e = local.extensions.first { $0.id.jsEquals(id) }
      let approval = shown[extensionApprovalKey(id)]
      if let e {
        if e.syncable && grantable(ExtensionApproval(json: approval), e) { _ = try await reconcileOne(id, record, approval, local, intents, true) }
        continue
      }
      if local.pending.contains(where: { $0.jsEquals(id) }) || now - (tried[id] ?? -.infinity) < extensionRetryMs { continue }
      tried[id] = now
      _ = try await reconcileOne(id, record, approval, local, intents, true)
    }
  }
}
