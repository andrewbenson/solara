import Foundation
import CryptoKit
import CoreFoundation
import Darwin

final class PairingInstallationHost: PairingInstallationHosting {
  enum Failure: Error { case unavailable, invalid, stopped }
  private struct Record: Codable, Equatable {
    var version = 1
    let installation: PairingInstallation
    let folder: String
    let route: String
    let priorState: String
    let stopGeneration: UInt64
    let handle: String
    var keySaved = false
    var initialized = false
    var ready = false
  }
  private let dataDirectory: URL
  private let directory: URL
  private let canonicalizationFailed: Bool
  private let folder: URL
  private let folderIdentity: Data
  private let keys: PairingInstallationKeyStoring
  private let accounting: PairingAccountingStoring
  private let route: String
  private let io: PairingDurableIO
  private let lock = NSRecursiveLock()
  private var initializedCallbacks: [(Bool) -> Void] = []
  private var readyCallbacks: [(Bool) -> Void] = []
  var onState: ((PairingJoinState) -> Void)?
  var onRequest: (() -> Void)?
  var onKeyAvailable: ((String, Data) -> Void)?
  var revision: (() -> Int?)?
  var projection: (([String: Any], [String: Any]) throws -> Any)?

  init(dataDirectory: URL, folder: URL, folderIdentity: Data, keys: PairingInstallationKeyStoring, accounting: PairingAccountingStoring, route: String = "onboarding", io: PairingDurableIO = PairingPOSIXDurableIO()) {
    let canonical = try? Self.canonicalDataDirectory(dataDirectory)
    let root = canonical ?? dataDirectory
    self.dataDirectory = root
    directory = root.appendingPathComponent("Application Support/sync-pairing")
    canonicalizationFailed = canonical == nil
    self.folder = folder
    self.folderIdentity = folderIdentity
    self.keys = keys
    self.accounting = accounting
    self.route = route
    self.io = io
  }

  private static func canonicalDataDirectory(_ url: URL) throws -> URL {
    guard url.isFileURL else { throw Failure.invalid }
    var ancestor = url.standardized
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: ancestor.path) && ancestor.path != "/" {
      suffix.insert(ancestor.lastPathComponent, at: 0)
      ancestor.deleteLastPathComponent()
    }
    guard let pointer = realpath(ancestor.path, nil) else { throw Failure.unavailable }
    defer { free(pointer) }
    var result = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    for component in suffix { result.appendPathComponent(component, isDirectory: true) }
    return result
  }

  static func priorState(_ value: String) -> String {
    let hash = value.utf16.reduce(UInt32(0x811c9dc5)) { ($0 ^ UInt32($1)) &* 0x01000193 }
    return "\(value.utf16.count):\(String(hash, radix: 36))"
  }

  private static let stopLock = NSRecursiveLock()
  private static let maximum = UInt64(9007199254740991)
  private static func integer(_ value: Any?) -> UInt64? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
      value.doubleValue >= 0, value.doubleValue <= Double(maximum), value.doubleValue.rounded(.down) == value.doubleValue else { return nil }
    return value.uint64Value
  }
  private static func json(_ value: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(value) else { throw Failure.invalid }
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
  }
  private static func equal(_ a: Any, _ b: Any) -> Bool {
    guard JSONSerialization.isValidJSONObject([a]), JSONSerialization.isValidJSONObject([b]),
      let left = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .fragmentsAllowed]),
      let right = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys, .fragmentsAllowed]) else { return false }
    return left == right
  }
  private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
  private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
    guard !canonicalizationFailed else { throw Failure.unavailable }
    return try Self.read(type, name: name, directory: directory, io: io)
  }
  private static func read<T: Decodable>(_ type: T.Type, name: String, directory: URL, io: PairingDurableIO) throws -> T? {
    try io.prepare(directory)
    guard try io.contents(directory).contains(name) else { return nil }
    return try JSONDecoder().decode(type, from: io.read(directory.appendingPathComponent(name), limit: 32768))
  }
  private func write<T: Codable & Equatable>(_ value: T, name: String) throws {
    guard !canonicalizationFailed else { throw Failure.unavailable }
    try Self.write(value, name: name, directory: directory, io: io)
  }
  private static func write<T: Codable & Equatable>(_ value: T, name: String, directory: URL, io: PairingDurableIO) throws {
    try io.prepare(directory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(value)
    try io.replace(bytes, at: directory.appendingPathComponent(name))
    let actual = try io.read(directory.appendingPathComponent(name), limit: 32768)
    guard bytes == actual, try JSONDecoder().decode(T.self, from: actual) == value else { throw Failure.unavailable }
  }
  private func record(bound: Bool = true) throws -> Record? {
    guard !canonicalizationFailed else { throw Failure.unavailable }
    try io.prepare(directory)
    guard try io.contents(directory).contains("host-installation.json") else { return nil }
    let value = try Self.decodeRecord(io.read(url("host-installation.json"), limit: 32768))
    guard !bound || (value.folder == folder.path && value.installation.folderIdentity == folderIdentity) else { throw Failure.invalid }
    return value
  }
  private static func decodeRecord(_ bytes: Data) throws -> Record {
    let value = try JSONDecoder().decode(Record.self, from: bytes)
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(object.keys) == Set(["version", "installation", "folder", "route", "priorState", "stopGeneration", "handle", "keySaved", "initialized", "ready"]),
      let tuple = object["installation"] as? [String: Any],
      Set(tuple.keys) == Set(["transaction", "cid", "device", "folderIdentity", "generation"]) else { throw Failure.invalid }
    guard value.version == 1,
      value.folder.hasPrefix("/"), value.folder.utf8.count <= 4096, !value.installation.folderIdentity.isEmpty, value.installation.folderIdentity.count <= 4096,
      ["onboarding", "settings"].contains(value.route), value.stopGeneration <= Self.maximum,
      value.installation.transaction.count == 32, value.installation.generation > 0, value.installation.generation <= Self.maximum,
      (try? PairingFormat.cid(value.installation.cid)) != nil, (try? PairingFormat.cid(value.installation.device)) != nil,
      !value.priorState.isEmpty, !value.handle.isEmpty, value.handle.utf8.count <= 128 else { throw Failure.invalid }
    return value
  }
  private func stop() throws -> UInt64 {
    let value = try read(UInt64.self, name: "host-stop.json") ?? 0
    guard value <= Self.maximum else { throw Failure.invalid }
    return value
  }
  static func committedTarget(dataDirectory: URL, keys: PairingInstallationKeyStoring, io: PairingDurableIO = PairingPOSIXDurableIO()) throws -> (folder: URL, installation: PairingInstallation, onboardingToken: String?)? {
    let dataDirectory = try canonicalDataDirectory(dataDirectory)
    let directory = dataDirectory.appendingPathComponent("Application Support/sync-pairing")
    try io.prepare(directory)
    guard try io.contents(directory).contains("host-installation.json") else { return nil }
    let value = try decodeRecord(io.read(directory.appendingPathComponent("host-installation.json"), limit: 32768))
    let folder = URL(fileURLWithPath: value.folder, isDirectory: true)
    guard folder.standardized.path == value.folder, !value.folder.contains("//") else { throw Failure.invalid }
    let accounting = try PairingDurableStore(dataDirectory: dataDirectory, syncFolder: folder, firstInstallation: .init(noPriorSyncState: false, noJoinOrStopMarker: false, keychainAccountAffirmativelyAbsent: false), io: io)
    let stopped = try read(UInt64.self, name: "host-stop.json", directory: directory, io: io) ?? 0
    guard stopped <= maximum else { throw Failure.invalid }
    guard stopped <= value.stopGeneration, try accounting.installationDecision(for: value.installation)?.disposition == .admitted else { return nil }
    if case .found(let root) = keys.pairingLookup(account: value.installation.device) {
      guard root.count == 32, SyncKeys(entropy: root).chainTag == value.installation.cid else { throw Failure.invalid }
    } else { throw Failure.unavailable }
    return (folder, value.installation, value.route == "onboarding" ? PairingMailbox.hex(value.installation.transaction) : nil)
  }
  func committedOnboardingToken() -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = try? record(), value.route == "onboarding", (try? root(value)) != nil else { return nil }
    return PairingMailbox.hex(value.installation.transaction)
  }
  var minimumGeneration: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    do { return max(try stop(), try record(bound: false)?.installation.generation ?? 0) }
    catch { return Self.maximum }
  }
  private static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }
  private static func descriptorValid(_ value: [String: Any]) -> Bool {
    let fields = Set(["transaction", "folder", "folderIdentity", "cid", "deviceId", "account", "generation", "stopGeneration", "phase", "route", "priorState"])
    guard Set(value.keys) == fields, let transaction = value["transaction"] as? String, transaction.utf8.count == 64,
      transaction.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let cid = value["cid"] as? String, cid.utf8.count == 32, cid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let folder = value["folder"] as? String, folder.hasPrefix("/"), folder.utf8.count <= 4096,
      let identity = value["folderIdentity"] as? String, let identityBytes = Data(base64Encoded: identity), !identityBytes.isEmpty, identityBytes.count <= 4096,
      identityBytes.base64EncodedString() == identity, let device = value["deviceId"] as? String, (try? PairingFormat.cid(device)) != nil,
      value["account"] as? String == device, let generation = integer(value["generation"]), generation > 0, integer(value["stopGeneration"]) != nil,
      let phase = value["phase"] as? String, ["prepared", "key-saved"].contains(phase),
      let route = value["route"] as? String, ["settings", "onboarding"].contains(route),
      let prior = value["priorState"] as? String, !prior.isEmpty, prior.utf8.count <= 128 else { return false }
    return true
  }
  private static func supported(_ doc: [String: Any]) -> Bool {
    guard let version = integer(doc["v"]), version == 1 || version == 2, let enabled = boolean(doc["enabled"]) else { return false }
    if let stopped = doc["stopGeneration"], integer(stopped) == nil { return false }
    if version == 1 { return true }
    guard let stop = integer(doc["stopGeneration"]), let joining = boolean(doc["joining"]), let bootstrap = doc["bootstrap"] as? [String: Any],
      let generation = integer(bootstrap["generation"]), let phase = bootstrap["phase"] as? String else { return false }
    if !enabled {
      guard !joining, stop > 0, phase == "stopped" else { return false }
      if let installation = doc["installation"] as? [String: Any] {
        return descriptorValid(installation) && doc["joinTransaction"] as? String == installation["transaction"] as? String && bootstrap["transaction"] as? String == installation["transaction"] as? String && generation == integer(installation["generation"]) && stop > (integer(installation["stopGeneration"]) ?? maximum) && doc["folder"] as? String == installation["folder"] as? String && doc["deviceId"] as? String == installation["deviceId"] as? String
      }
      return doc["installation"] == nil && doc["joinTransaction"] == nil && bootstrap["transaction"] is NSNull
    }
    guard ["awaiting-profile", "binding-persisted", "applying", "ready", "onboarding-completed"].contains(phase),
      let installation = doc["installation"] as? [String: Any], descriptorValid(installation),
      doc["joinTransaction"] as? String == installation["transaction"] as? String, bootstrap["transaction"] as? String == installation["transaction"] as? String,
      generation == integer(installation["generation"]), stop == integer(installation["stopGeneration"]),
      doc["folder"] as? String == installation["folder"] as? String, doc["deviceId"] as? String == installation["deviceId"] as? String,
      joining == !(phase == "ready" || phase == "onboarding-completed") else { return false }
    if bootstrap["checkpoint"] == nil { return phase == "awaiting-profile" }
    guard let checkpoint = bootstrap["checkpoint"] as? [String: Any], let name = checkpoint["name"] as? String, let digest = checkpoint["digest"] as? String else { return false }
    return !name.isEmpty && !digest.isEmpty && !name.contains("/")
  }
  private func document() throws -> (String, [String: Any]?) {
    guard !canonicalizationFailed else { throw Failure.unavailable }
    let file = dataDirectory.appendingPathComponent("sync.json")
    var info = stat()
    if lstat(file.path, &info) != 0 {
      guard errno == ENOENT else { throw Failure.unavailable }
      return ("", nil)
    }
    let bytes = try io.read(file, limit: 4 * 1024 * 1024)
    guard let text = String(data: bytes, encoding: .utf8), let doc = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Self.supported(doc) else { throw Failure.invalid }
    return (text, doc)
  }
  private func validateFolder(_ installation: PairingInstallation) throws {
    guard !canonicalizationFailed else { throw Failure.unavailable }
    guard installation.folderIdentity == folderIdentity, folder.isFileURL, folder.standardized.path == folder.path, !folder.path.contains("//") else { throw Failure.invalid }
    let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.unavailable }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, Data("\(info.st_dev):\(info.st_ino)".utf8) == folderIdentity else { throw Failure.invalid }
    let cid = openat(fd, installation.cid, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard cid >= 0 else { throw Failure.unavailable }
    close(cid)
    try accounting.validatePlacement(pairingFolder: folder)
  }
  private func root(_ record: Record) throws -> Data {
    guard try stop() <= record.stopGeneration else { throw Failure.stopped }
    try validateFolder(record.installation)
    guard try accounting.installationDecision(for: record.installation)?.disposition == .admitted,
      case .found(let root) = keys.pairingLookup(account: record.installation.device), root.count == 32,
      SyncKeys(entropy: root).chainTag == record.installation.cid else { throw Failure.unavailable }
    return root
  }
  private static func dto(_ record: Record) -> [String: Any] {
    ["transaction": PairingMailbox.hex(record.installation.transaction), "folder": record.folder,
     "folderIdentity": record.installation.folderIdentity.base64EncodedString(), "cid": PairingMailbox.hex((try? PairingFormat.cid(record.installation.cid)) ?? Data()),
     "deviceId": record.installation.device, "account": record.installation.device, "generation": record.installation.generation,
     "stopGeneration": record.stopGeneration, "phase": record.keySaved ? "key-saved" : "prepared", "route": record.route, "priorState": record.priorState]
  }
  private static func matching(_ dto: [String: Any], _ record: Record) throws {
    var expected = Self.dto(record)
    guard Self.integer(dto["generation"]) == record.installation.generation, Self.integer(dto["stopGeneration"]) == record.stopGeneration,
      let phase = dto["phase"] as? String, phase == "prepared" || phase == "key-saved" else { throw Failure.invalid }
    expected["phase"] = phase
    guard Self.equal(dto, expected) else { throw Failure.invalid }
  }

  func prepare(_ installation: PairingInstallation, completion: @escaping (Bool) -> Void) {
    lock.lock()
    let result: Bool
    do {
      try validateFolder(installation)
      guard installation.generation > 0, installation.generation <= Self.maximum, installation.transaction.count == 32,
        (try? PairingFormat.cid(installation.device)) != nil, ["onboarding", "settings"].contains(route) else { throw Failure.invalid }
      let prior = try record(bound: false)
      if let prior, prior.installation == installation {
        guard prior.folder == folder.path else { throw Failure.invalid }
        guard try stop() <= prior.stopGeneration, try accounting.installationDecision(for: installation)?.disposition != .cancelled else { throw Failure.invalid }
        result = true
      } else {
        if let prior {
          guard installation.generation > prior.installation.generation,
            try stop() > prior.stopGeneration || accounting.installationDecision(for: prior.installation)?.disposition == .cancelled else { throw Failure.invalid }
          guard try io.contents(directory).filter({ $0.hasPrefix("host-history-") }).count < 512 else { throw Failure.unavailable }
          try write(prior, name: "host-history-" + PairingMailbox.hex(prior.installation.transaction) + "-" + String(prior.installation.generation) + ".json")
        }
        let (text, doc) = try document()
        guard doc?["enabled"] as? Bool != true else { throw Failure.invalid }
        let stopped = max(try stop(), Self.integer(doc?["stopGeneration"]) ?? 0)
        guard installation.generation > stopped, keys.pairingLookup(account: installation.device) == .absent else { throw Failure.invalid }
        let value = Record(installation: installation, folder: folder.path, route: route, priorState: Self.priorState(text), stopGeneration: stopped, handle: UUID().uuidString.lowercased())
        try write(value, name: "host-installation.json")
        result = true
      }
    } catch { result = false }
    lock.unlock()
    completion(result)
  }

  func keySaved(_ installation: PairingInstallation, initialized: @escaping (Bool) -> Void, ready: @escaping (Bool) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    do {
      guard var value = try record(), value.installation == installation else { throw Failure.invalid }
      let key = try root(value)
      value.keySaved = true
      try write(value, name: "host-installation.json")
      initializedCallbacks.append(initialized)
      readyCallbacks.append(ready)
      onKeyAvailable?(value.installation.device, key)
      onRequest?()
      if value.initialized { initialized(true) }
      if value.ready { ready(true) }
    } catch {}
  }

  func installationRequest() -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = try? record(), value.keySaved, (try? root(value)) != nil else { return nil }
    return ["handle": value.handle, "folder": value.folder, "folderIdentity": value.installation.folderIdentity.base64EncodedString(),
      "cid": PairingMailbox.hex((try? PairingFormat.cid(value.installation.cid)) ?? Data()), "generation": value.installation.generation, "stopGeneration": value.stopGeneration]
  }

  func consumeInstallation(handle: String, priorState: String) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    guard let value = try record(), value.keySaved, handle == value.handle, priorState == value.priorState else { throw Failure.invalid }
    _ = try root(value)
    let (text, doc) = try document()
    guard Self.priorState(text) == value.priorState && doc?["enabled"] as? Bool != true else { throw Failure.invalid }
    var result = Self.dto(value)
    result["phase"] = "prepared"
    return result
  }
  func saveInstallation(_ dto: [String: Any]) throws { _ = try readInstallation(dto) }
  func readInstallation(_ dto: [String: Any]) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    guard var value = try record() else { throw Failure.unavailable }
    try Self.matching(dto, value)
    let key = try root(value)
    let (text, doc) = try document()
    if let doc, doc["enabled"] as? Bool == true { try validateDocument(doc, record: value, ready: false) }
    else { guard Self.priorState(text) == value.priorState else { throw Failure.invalid } }
    value.keySaved = true
    try write(value, name: "host-installation.json")
    onKeyAvailable?(value.installation.device, key)
    return Self.dto(value)
  }
  func recoverInstallation() throws -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    guard var value = try record() else { return nil }
    guard try stop() <= value.stopGeneration else { return nil }
    guard try accounting.installationDecision(for: value.installation)?.disposition == .admitted else { return nil }
    let key = try root(value)
    let (text, doc) = try document()
    if let doc, doc["enabled"] as? Bool == true { try validateDocument(doc, record: value, ready: false) }
    else { guard Self.priorState(text) == value.priorState else { throw Failure.invalid } }
    value.keySaved = true
    try write(value, name: "host-installation.json")
    onKeyAvailable?(value.installation.device, key)
    return Self.dto(value)
  }
  func stopCurrentInstallation() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !canonicalizationFailed else { throw Failure.unavailable }
    try Self.stopInstallation(directory: directory, nil, stopGeneration: nil, io: io)
    finishStop()
  }
  func committedState() -> PairingJoinState? {
    lock.lock()
    defer { lock.unlock() }
    do {
      guard try recoverInstallation() != nil, let value = try record() else { return nil }
      if value.ready {
        guard value.initialized, let doc = try document().1 else { return .approved }
        return (try? validateDocument(doc, record: value, ready: true)) != nil ? .installed : .approved
      }
      if let doc = try document().1, doc["enabled"] as? Bool == true {
        do {
          try acknowledgeInitialization(transaction: PairingMailbox.hex(value.installation.transaction), generation: value.installation.generation)
          if let bootstrap = doc["bootstrap"] as? [String: Any], let phase = bootstrap["phase"] as? String, phase == "ready" || phase == "onboarding-completed" {
            try acknowledgeReady(transaction: PairingMailbox.hex(value.installation.transaction), generation: value.installation.generation)
            return .installed
          }
        } catch { return .approved }
      }
      return .approved
    } catch { return nil }
  }
  func stopInstallation(_ dto: [String: Any]?, stopGeneration: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    guard stopGeneration > 0, stopGeneration <= Self.maximum else { throw Failure.invalid }
    if let dto {
      guard let value = try record() else { throw Failure.invalid }
      try Self.matching(dto, value)
    }
    guard !canonicalizationFailed else { throw Failure.unavailable }
    try Self.stopInstallation(directory: directory, dto, stopGeneration: stopGeneration, io: io)
    finishStop()
  }
  func finishStop() {
    lock.lock()
    defer { lock.unlock() }
    initializedCallbacks.removeAll()
    readyCallbacks.removeAll()
  }
  static func stopInstallation(dataDirectory: URL, _ dto: [String: Any]?, stopGeneration: UInt64?, io: PairingDurableIO = PairingPOSIXDurableIO()) throws {
    let root = try canonicalDataDirectory(dataDirectory)
    try stopInstallation(directory: root.appendingPathComponent("Application Support/sync-pairing"), dto, stopGeneration: stopGeneration, io: io)
  }
  private static func stopInstallation(directory: URL, _ dto: [String: Any]?, stopGeneration: UInt64?, io: PairingDurableIO) throws {
    stopLock.lock()
    defer { stopLock.unlock() }
    if let stopGeneration { guard stopGeneration > 0, stopGeneration <= maximum else { throw Failure.invalid } }
    try io.prepare(directory)
    let value: Record?
    if try io.contents(directory).contains("host-installation.json") {
      value = try decodeRecord(io.read(directory.appendingPathComponent("host-installation.json"), limit: 32768))
    } else { value = nil }
    if let dto {
      guard let value else { throw Failure.invalid }
      try matching(dto, value)
    }
    let current = try read(UInt64.self, name: "host-stop.json", directory: directory, io: io) ?? 0
    let high = max(current, value?.installation.generation ?? 0)
    guard current <= maximum, (value?.installation.generation ?? 0) < maximum,
      stopGeneration != nil || high < maximum else { throw Failure.unavailable }
    let generation = max(current, stopGeneration ?? (high + 1), (value?.installation.generation ?? 0) + 1)
    try write(generation, name: "host-stop.json", directory: directory, io: io)
  }

  private func validateDocument(_ doc: [String: Any], record: Record, ready: Bool) throws {
    guard Self.integer(doc["v"]) == 2, doc["enabled"] as? Bool == true,
      doc["folder"] as? String == record.folder, doc["deviceId"] as? String == record.installation.device,
      doc["joinTransaction"] as? String == PairingMailbox.hex(record.installation.transaction),
      Self.integer(doc["stopGeneration"]) == record.stopGeneration,
      let installation = doc["installation"] as? [String: Any], let bootstrap = doc["bootstrap"] as? [String: Any],
      bootstrap["transaction"] as? String == PairingMailbox.hex(record.installation.transaction),
      Self.integer(bootstrap["generation"]) == record.installation.generation,
      let phase = bootstrap["phase"] as? String,
      ["awaiting-profile", "binding-persisted", "applying", "ready", "onboarding-completed"].contains(phase),
      doc["joining"] as? Bool == !(phase == "ready" || phase == "onboarding-completed"),
      !ready || phase == "ready" || phase == "onboarding-completed" else { throw Failure.invalid }
    try Self.matching(installation, record)
    guard installation["phase"] as? String == "key-saved" else { throw Failure.invalid }
  }
  func acknowledgeInitialization(transaction: String, generation: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    guard var value = try record(), value.keySaved, transaction == PairingMailbox.hex(value.installation.transaction), generation == value.installation.generation,
      let doc = try document().1 else { throw Failure.invalid }
    _ = try root(value)
    try validateDocument(doc, record: value, ready: false)
    value.initialized = true
    try write(value, name: "host-installation.json")
    let callbacks = initializedCallbacks
    initializedCallbacks.removeAll()
    callbacks.forEach { $0(true) }
  }
  func acknowledgeReady(transaction: String, generation: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    guard var value = try record(), value.initialized, transaction == PairingMailbox.hex(value.installation.transaction), generation == value.installation.generation,
      let doc = try document().1 else { throw Failure.invalid }
    let key = try root(value)
    try validateDocument(doc, record: value, ready: true)
    if value.ready { return }
    let plan = try plan(doc: doc, record: value, root: key)
    guard let observedRevision = revision?() else { throw Failure.unavailable }
    guard let operations = plan["operations"] as? [[String: Any]], !operations.isEmpty else { throw Failure.invalid }
    guard let outcomes = plan["outcomes"] as? [String: Any], Set(outcomes.keys) == Set(operations.compactMap { $0["key"] as? String }) else { throw Failure.invalid }
    for operation in operations {
      guard let receipt = try reconcileApplied(operation), let key = operation["key"] as? String,
        let outcome = outcomes[key], Self.equal(outcome, receipt) else { throw Failure.unavailable }
    }
    guard revision?() == observedRevision else { throw Failure.unavailable }
    let changed = !value.ready
    value.ready = true
    try write(value, name: "host-installation.json")
    if changed { onState?(.installed) }
    let callbacks = readyCallbacks
    readyCallbacks.removeAll()
    callbacks.forEach { $0(true) }
  }

  private func plan(doc: [String: Any], record: Record, root: Data) throws -> [String: Any] {
    guard let bootstrap = doc["bootstrap"] as? [String: Any], let checkpoint = bootstrap["checkpoint"] as? [String: Any],
      let name = checkpoint["name"] as? String, let expected = checkpoint["digest"] as? String else { throw Failure.invalid }
    let prefix = "sync-bootstrap-" + PairingMailbox.hex(record.installation.transaction) + "-"
    guard name.hasPrefix(prefix), name.hasSuffix(".nns"), !name.contains("/"),
      let revision = UInt64(name.dropFirst(prefix.count).dropLast(4)), revision > 0, revision <= Self.maximum,
      let encoded = String(data: try io.read(dataDirectory.appendingPathComponent(name), limit: 8 * 1024 * 1024), encoding: .utf8),
      let sealed = Data(base64Encoded: encoded), let plain = LocalDocuments.open(sealed, .state, keys: SyncKeys(entropy: root)),
      Self.priorState(plain).split(separator: ":").last.map(String.init) == expected,
      let replica = try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any],
      replica["transaction"] as? String == PairingMailbox.hex(record.installation.transaction),
      Self.integer(replica["generation"]) == record.installation.generation, Self.integer(replica["revision"]) == revision,
      let plan = replica["plan"] as? [String: Any], let operations = plan["operations"] as? [[String: Any]],
      !operations.isEmpty, operations.count <= 512, let links = plan["links"] as? [String: Any],
      let defaultKey = plan["defaultKey"] as? String, defaultKey.hasPrefix("prof:"), defaultKey.utf8.count > 5,
      let defaultLink = links["default"] as? [String: Any], defaultLink["syncId"] as? String == String(defaultKey.dropFirst(5)),
      let app = replica["app"] as? [String: Any], let records = app["records"] as? [String: Any],
      let defaultRecord = records[defaultKey] as? [String: Any], let profile = defaultRecord["v"] as? [String: Any], Self.boolean(profile["d"]) == true,
      let profileName = profile["n"] as? String, !profileName.isEmpty,
      Set(operations.compactMap({ $0["key"] as? String })).count == operations.count,
      operations.contains(where: { $0["key"] as? String == defaultKey }),
      let documentLinks = doc["profiles"], Self.equal(documentLinks, links) else { throw Failure.invalid }
    let defaults = records.filter { key, value in
      guard key.hasPrefix("prof:"), let record = value as? [String: Any], let profile = record["v"] as? [String: Any] else { return false }
      return Self.boolean(profile["d"]) == true
    }
    guard defaults.count == 1 else { throw Failure.invalid }
    return plan
  }
  private func operationState(_ operation: [String: Any]) throws -> (Record, Data, [String: Any]) {
    let allowed: Set<String> = ["operationId", "transaction", "generation", "key", "desired", "before", "localValue", "disposition"]
    guard Set(operation.keys) == allowed, let value = try record(), value.initialized,
      operation["transaction"] as? String == PairingMailbox.hex(value.installation.transaction), Self.integer(operation["generation"]) == value.installation.generation,
      let key = operation["key"] as? String, key.utf8.count <= 256,
      ["set:", "prof:", "pth:", "share:"].contains(where: { key.hasPrefix($0) }),
      let id = operation["operationId"] as? String, id.utf8.count <= 512,
      id.hasPrefix("\(PairingMailbox.hex(value.installation.transaction)):\(value.installation.generation):\(key):"),
      let disposition = operation["disposition"] as? String, ["applied", "local-choice", "opt-out"].contains(disposition),
      try Self.json(operation).count <= 65536, let doc = try document().1 else { throw Failure.invalid }
    let root = try self.root(value)
    try validateDocument(doc, record: value, ready: false)
    let plan = try self.plan(doc: doc, record: value, root: root)
    guard let intended = (plan["operations"] as? [[String: Any]])?.filter({ $0["operationId"] as? String == id }), intended.count == 1,
      Self.equal(intended[0], operation), let links = plan["links"] as? [String: Any] else { throw Failure.invalid }
    return (value, root, links)
  }
  private func receiptName(_ operation: [String: Any]) -> String {
    let id = operation["operationId"] as? String ?? ""
    return "host-receipt-" + PairingMailbox.hex(Data(SHA256.hash(data: Data(id.utf8)))) + ".nns"
  }
  private func receipt(_ operation: [String: Any], value: Any) -> [String: Any] {
    ["operationId": operation["operationId"]!, "transaction": operation["transaction"]!, "generation": operation["generation"]!,
     "key": operation["key"]!, "disposition": operation["disposition"]!, "value": value]
  }
  func reconcileApplied(_ operation: [String: Any]) throws -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    let (_, root, links) = try operationState(operation)
    guard let projection else { throw Failure.unavailable }
    let value = try projection(operation, links)
    guard Self.equal(value, operation["localValue"]!) else { return nil }
    let name = receiptName(operation)
    guard try io.contents(directory).contains(name) else { return nil }
    let sealed = try io.read(url(name), limit: 131072)
    let plain = try SyncKeys(entropy: root).open(sealed, scopeTag: "local", fileId: name)
    guard let saved = try JSONSerialization.jsonObject(with: plain) as? [String: Any],
      Self.equal(saved["operation"] as Any, operation), Self.equal(saved["receipt"] as Any, receipt(operation, value: value)) else { throw Failure.invalid }
    _ = try operationState(operation)
    return receipt(operation, value: value)
  }
  func checkpointApplied(_ operation: [String: Any]) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let (_, root, links) = try operationState(operation)
    guard let projection else { throw Failure.unavailable }
    let value = try projection(operation, links)
    guard Self.equal(value, operation["localValue"]!) else { throw Failure.unavailable }
    let result = receipt(operation, value: value)
    let name = receiptName(operation)
    if try io.contents(directory).contains(name) {
      let existing = try io.read(url(name), limit: 131072)
      let opened = try SyncKeys(entropy: root).open(existing, scopeTag: "local", fileId: name)
      guard let saved = try JSONSerialization.jsonObject(with: opened) as? [String: Any],
        Self.equal(saved["operation"] as Any, operation), Self.equal(saved["receipt"] as Any, result) else { throw Failure.invalid }
      _ = try operationState(operation)
      guard Self.equal(try projection(operation, links), value) else { throw Failure.unavailable }
      return result
    }
    let plain = try Self.json(["operation": operation, "receipt": result])
    let sealed = try SyncKeys(entropy: root).seal(plain, scopeTag: "local", fileId: name)
    try io.replace(sealed, at: url(name))
    guard try io.read(url(name), limit: 131072) == sealed else { throw Failure.unavailable }
    _ = try operationState(operation)
    guard Self.equal(try projection(operation, links), value) else { throw Failure.unavailable }
    return result
  }
}
