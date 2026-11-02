import Foundation
import Darwin
import CryptoKit

struct PairingFirstInstallationEvidence {
  var noPairingEraSyncState: Bool
  var noJoinOrStopMarker: Bool
  var keyStateKnown: Bool
  var verified: Bool { noPairingEraSyncState && noJoinOrStopMarker && keyStateKnown }
}

struct PairingConsumedApproval: Codable, Equatable {
  enum Disposition: String, Codable { case consumed }
  var disposition: Disposition = .consumed
  var cid: Data
  var rid: Data
  var aid: Data
  var transcript: Data
  var epoch: Data
  var time: UInt64
  var sealedApproval: Data
}

protocol PairingAccountingStoring: AnyObject {
  func validatePlacement(pairingFolder: URL) throws
  func persistInstallationDecision(_ decision: PairingInstallationDecision) throws -> PairingInstallationDecision
  func persistInstallationDecision(_ decision: PairingInstallationDecision, admit: () -> Bool) throws -> PairingInstallationDecision
  func installationDecision(for installation: PairingInstallation) throws -> PairingInstallationDecision?
  func cancelInstallation(_ installation: PairingInstallation) throws
  func restoreAccounting(now: UInt64, epoch: Data) -> PairingSession.RestorationDisposition
  func persistAccounting(_ value: PairingSession.Accounting) throws -> PairingSession.Accounting
  func consumeApproval(_ record: PairingConsumedApproval) throws
  func setSuppressed(_ value: Bool) throws
  var suppressed: Bool { get }
}

extension PairingAccountingStoring {
  func persistInstallationDecision(_ decision: PairingInstallationDecision, admit: () -> Bool) throws -> PairingInstallationDecision {
    guard admit() else { throw PairingDurableStore.Failure.staleRevision }
    return try persistInstallationDecision(decision)
  }
}

protocol PairingDurableIO {
  func prepare(_ directory: URL) throws
  func exists(_ url: URL) -> Bool
  func contents(_ directory: URL) throws -> [String]
  func read(_ url: URL, limit: Int) throws -> Data
  func createExclusive(_ bytes: Data, at url: URL) throws
  func replace(_ bytes: Data, at url: URL) throws
}

final class PairingDurableStore: PairingAccountingStoring {
  enum Failure: Error { case storage, placement, staleRevision, duplicate, capacity, malformed }
  let directory: URL
  private let io: PairingDurableIO
  private var firstInstallation: PairingFirstInstallationEvidence
  private var accountingRestored = false
  private let lock = NSLock()
  private var latest: PairingSession.Accounting?
  private var suppressionFailed = false
  private var accountingUncertain = false
  private var uncertainInstallations: Set<String> = []
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(dataDirectory: URL, syncFolder: URL, firstInstallation: PairingFirstInstallationEvidence, io: PairingDurableIO = PairingPOSIXDurableIO()) throws {
    directory = try Self.canonical(dataDirectory.appendingPathComponent("Application Support/sync-pairing", isDirectory: true))
    self.io = io
    self.firstInstallation = firstInstallation
    encoder.outputFormatting = [.sortedKeys]
    try validatePlacement(pairingFolder: syncFolder)
  }

  func validatePlacement(pairingFolder: URL) throws {
    let local = try Self.canonical(directory).path
    let remote = try Self.canonical(pairingFolder).path
    guard local == directory.path, remote != "/", local != remote, !local.hasPrefix(remote + "/"), !remote.hasPrefix(local + "/") else { throw Failure.placement }
    try PairingPOSIXDurableIO.validateLocalPlacement(directory)
  }

  private static func canonical(_ url: URL) throws -> URL {
    guard url.isFileURL else { throw Failure.placement }
    var ancestor = url.standardizedFileURL
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: ancestor.path) && ancestor.path != "/" {
      suffix.insert(ancestor.lastPathComponent, at: 0)
      ancestor.deleteLastPathComponent()
    }
    guard let pointer = realpath(ancestor.path, nil) else { throw Failure.placement }
    defer { free(pointer) }
    var result = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    for component in suffix { result.appendPathComponent(component, isDirectory: true) }
    return result
  }

  private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

  private func valid(_ installation: PairingInstallation) -> Bool {
    installation.transaction.count == 32 && (try? PairingFormat.cid(installation.cid)) != nil && (try? PairingFormat.cid(installation.device)) != nil && !installation.folderIdentity.isEmpty && installation.folderIdentity.count <= 4096 && installation.generation > 0
  }

  private func installationName(_ installation: PairingInstallation) -> String {
    "installation-" + Base32.encode(Data(SHA256.hash(data: installation.transaction))) + "-" + String(installation.generation) + ".json"
  }

  private func cancellationName(_ installation: PairingInstallation) -> String {
    "cancelled-" + String(installationName(installation).dropFirst("installation-".count))
  }

  private func readDecision(_ installation: PairingInstallation, name: String) throws -> PairingInstallationDecision {
    let bytes = try io.read(url(name), limit: 16384)
    let decision = try decoder.decode(PairingInstallationDecision.self, from: bytes)
    guard valid(decision.installation), decision.installation == installation else { throw Failure.malformed }
    return decision
  }

  func cancelInstallation(_ installation: PairingInstallation) throws {
    lock.lock()
    defer { lock.unlock() }
    guard valid(installation) else { throw Failure.malformed }
    try persistCancellation(installation)
  }

  private func readCancellation(_ installation: PairingInstallation, name: String) throws -> PairingInstallationDecision {
    let decision = try readDecision(installation, name: name)
    guard decision.disposition == .cancelled else { throw Failure.malformed }
    return decision
  }

  private func persistCancellation(_ installation: PairingInstallation) throws {
    try io.prepare(directory)
    let name = cancellationName(installation)
    let names = try io.contents(directory)
    let decision = PairingInstallationDecision(installation: installation, disposition: .cancelled)
    let bytes = try encoder.encode(decision)
    if names.contains(name) {
      guard try readCancellation(installation, name: name) == decision else { throw Failure.malformed }
      try io.replace(bytes, at: url(name))
    } else {
      guard names.filter({ $0.hasPrefix("cancelled-") }).count < 512 else { throw Failure.capacity }
      try io.createExclusive(bytes, at: url(name))
    }
    guard try io.read(url(name), limit: 16384) == bytes, try readCancellation(installation, name: name) == decision else { throw Failure.storage }
  }

  func installationDecision(for installation: PairingInstallation) throws -> PairingInstallationDecision? {
    lock.lock()
    defer { lock.unlock() }
    guard valid(installation) else { throw Failure.malformed }
    let name = installationName(installation)
    try io.prepare(directory)
    let names = try io.contents(directory)
    let veto = cancellationName(installation)
    if names.contains(veto) { return try readCancellation(installation, name: veto) }
    guard !uncertainInstallations.contains(name) else { throw Failure.storage }
    guard names.contains(name) else { return nil }
    return try readDecision(installation, name: name)
  }

  func persistInstallationDecision(_ decision: PairingInstallationDecision) throws -> PairingInstallationDecision {
    lock.lock()
    defer { lock.unlock() }
    guard valid(decision.installation) else { throw Failure.malformed }
    let name = installationName(decision.installation)
    guard !uncertainInstallations.contains(name) else { throw Failure.storage }
    do {
      try io.prepare(directory)
      let names = try io.contents(directory)
      let veto = cancellationName(decision.installation)
      if names.contains(veto) {
        _ = try readCancellation(decision.installation, name: veto)
        guard decision.disposition == .cancelled else { throw Failure.duplicate }
      }
      if names.contains(name) {
        let saved = try readDecision(decision.installation, name: name)
        guard saved == decision else { throw Failure.duplicate }
        return saved
      }
      if decision.disposition == .cancelled {
        try persistCancellation(decision.installation)
        return decision
      }
      guard names.filter({ $0.hasPrefix("installation-") }).count < 512 else { throw Failure.capacity }
      let bytes = try encoder.encode(decision)
      try io.createExclusive(bytes, at: url(name))
      guard try io.read(url(name), limit: 16384) == bytes, try readDecision(decision.installation, name: name) == decision else { throw Failure.storage }
      return decision
    } catch {
      uncertainInstallations.insert(name)
      throw error
    }
  }

  private func valid(_ value: PairingSession.Accounting) -> Bool {
    let bound = value.lastTime.addingReportingOverflow(120000)
    return value.version == 1 && !value.clockEpoch.isEmpty && value.clockEpoch.count <= 64 && value.reveals.count <= 512 && (0...512).contains(value.uncertainReveals) && value.reveals.allSatisfy { $0 <= (bound.overflow ? UInt64.max : bound.partialValue) }
  }

  private func write<T: Codable & Equatable>(_ value: T, name: String) throws {
    let bytes = try encoder.encode(value)
    try io.replace(bytes, at: url(name))
    let returned = try io.read(url(name), limit: 1048576)
    guard returned == bytes, try decoder.decode(T.self, from: returned) == value else { throw Failure.storage }
  }

  private func quarantined(_ value: PairingSession.Accounting?, now: UInt64, epoch: Data) -> PairingSession.Accounting {
    let old = value
    var result = old ?? .init(clockEpoch: epoch)
    let addition = now.addingReportingOverflow(86400000)
    result.version = 1
    result.clockEpoch = epoch
    result.uncertainReveals = min(512, max(20, (old?.uncertainReveals ?? 0) + (old?.reveals.count ?? 0)))
    result.reveals = []
    result.blockedUntil = addition.overflow ? UInt64.max : addition.partialValue
    result.lastTime = now
    result.readable = true
    result.revision = result.revision == UInt64.max ? UInt64.max : result.revision + 1
    return result
  }

  func setFirstInstallationEvidence(_ evidence: PairingFirstInstallationEvidence) {
    lock.lock()
    defer { lock.unlock() }
    guard !accountingRestored else { return }
    firstInstallation = evidence
  }

  func restoreAccounting(now: UInt64, epoch: Data) -> PairingSession.RestorationDisposition {
    lock.lock()
    defer { lock.unlock() }
    accountingRestored = true
    guard !epoch.isEmpty, epoch.count <= 64 else { return .unreadable }
    do {
      try io.prepare(directory)
      let names = try io.contents(directory)
      if names.isEmpty && firstInstallation.verified {
        try io.createExclusive(Data([1]), at: url("initialized"))
        guard try io.read(url("initialized"), limit: 1) == Data([1]) else { throw Failure.storage }
        let initial = PairingSession.Accounting(clockEpoch: epoch, lastTime: now)
        try write(initial, name: "accounting.json")
        latest = initial
        accountingUncertain = false
        return .newInstallation
      }
      guard let bytes = try? io.read(url("accounting.json"), limit: 32768), let saved = try? decoder.decode(PairingSession.Accounting.self, from: bytes), valid(saved), saved.readable else {
        let normalized = quarantined(nil, now: now, epoch: epoch)
        try write(normalized, name: "accounting.json")
        if !io.exists(url("initialized")) { try io.createExclusive(Data([1]), at: url("initialized")) }
        latest = normalized
        accountingUncertain = false
        return .restored(normalized)
      }
      if saved.clockEpoch != epoch || now < saved.lastTime {
        let normalized = quarantined(saved, now: now, epoch: epoch)
        try write(normalized, name: "accounting.json")
        latest = normalized
        accountingUncertain = false
        return .restored(normalized)
      }
      latest = saved
      accountingUncertain = false
      return .restored(saved)
    } catch {
      suppressionFailed = true
      accountingUncertain = true
      return .unreadable
    }
  }

  func persistAccounting(_ value: PairingSession.Accounting) throws -> PairingSession.Accounting {
    lock.lock()
    defer { lock.unlock() }
    guard valid(value), value.readable else { throw Failure.malformed }
    guard !accountingUncertain, let prior = latest else { throw Failure.storage }
    guard value.revision >= prior.revision, value.revision != prior.revision || value == prior else { throw Failure.staleRevision }
    guard value.clockEpoch == prior.clockEpoch, value.lastTime >= prior.lastTime else { throw Failure.staleRevision }
    do {
      try write(value, name: "accounting.json")
      latest = value
    } catch {
      accountingUncertain = true
      throw error
    }
    return value
  }

  private func valid(_ record: PairingConsumedApproval) -> Bool {
    record.cid.count == 16 && record.rid.count == 16 && record.aid.count == 16 && record.transcript.count == 32 && record.epoch.count == 16 && record.sealedApproval.count == 1160
  }

  func consumeApproval(_ record: PairingConsumedApproval) throws {
    lock.lock()
    defer { lock.unlock() }
    guard valid(record) else { throw Failure.malformed }
    try io.prepare(directory)
    var records: [PairingConsumedApproval] = []
    let names = try io.contents(directory)
    if names.contains("consumed-approvals.json") {
      records = try decoder.decode([PairingConsumedApproval].self, from: io.read(url("consumed-approvals.json"), limit: 1048576))
      guard records.count <= 512, records.allSatisfy(valid) else { throw Failure.malformed }
    }
    guard !records.contains(where: { $0.cid == record.cid && $0.rid == record.rid && $0.aid == record.aid && $0.transcript == record.transcript }) else { throw Failure.duplicate }
    guard records.count < 512 else { throw Failure.capacity }
    records.append(record)
    try write(records, name: "consumed-approvals.json")
  }

  var suppressed: Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !suppressionFailed, let bytes = try? io.read(url("suppression.json"), limit: 16), let value = try? decoder.decode(Bool.self, from: bytes) else { return true }
    return value
  }

  func setSuppressed(_ value: Bool) throws {
    lock.lock()
    defer { lock.unlock() }
    do {
      try io.prepare(directory)
      try write(value, name: "suppression.json")
      suppressionFailed = false
    } catch {
      suppressionFailed = true
      throw error
    }
  }
}

protocol PairingPOSIXSyncing {
  func fullSync(_ descriptor: Int32) -> Int32
  func sync(_ descriptor: Int32) -> Int32
}

struct PairingDarwinSync: PairingPOSIXSyncing {
  func fullSync(_ descriptor: Int32) -> Int32 { fcntl(descriptor, F_FULLFSYNC) }
  func sync(_ descriptor: Int32) -> Int32 { fsync(descriptor) }
}

struct PairingPOSIXDurableIO: PairingDurableIO {
  let barriers: PairingPOSIXSyncing

  init(barriers: PairingPOSIXSyncing = PairingDarwinSync()) { self.barriers = barriers }

  private func checked(_ value: Int32) throws -> Int32 {
    guard value >= 0 else { throw PairingDurableStore.Failure.storage }
    return value
  }

  private func directory(_ url: URL, create: Bool) throws -> Int32 {
    var fd = try checked(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    do {
      for component in url.pathComponents.dropFirst() {
        if create {
          guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw PairingDurableStore.Failure.storage }
          guard barriers.sync(fd) == 0 else { throw PairingDurableStore.Failure.storage }
        }
        let next = try checked(openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        let previous = fd
        fd = next
        guard close(previous) == 0 else { throw PairingDurableStore.Failure.storage }
      }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }

  static func validateLocalPlacement(_ target: URL) throws {
    var ancestor = target
    while !FileManager.default.fileExists(atPath: ancestor.path) && ancestor.path != "/" { ancestor.deleteLastPathComponent() }
    let resources = try ancestor.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey])
    guard resources.volumeIsLocal == true, resources.isUbiquitousItem != true else { throw PairingDurableStore.Failure.placement }
  }

  func prepare(_ target: URL) throws {
    try Self.validateLocalPlacement(target)
    let fd = try directory(target, create: true)
    defer { close(fd) }
    guard fchmod(fd, 0o700) == 0, barriers.sync(fd) == 0 else { throw PairingDurableStore.Failure.storage }
  }

  func exists(_ url: URL) -> Bool {
    guard let parent = try? directory(url.deletingLastPathComponent(), create: false) else { return false }
    defer { close(parent) }
    var info = stat()
    return fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0
  }

  func contents(_ target: URL) throws -> [String] {
    let fd = try directory(target, create: false)
    guard let stream = fdopendir(fd) else { close(fd); throw PairingDurableStore.Failure.storage }
    defer { closedir(stream) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      if name != "." && name != ".." { names.append(name) }
      guard names.count <= 1024 else { throw PairingDurableStore.Failure.storage }
    }
    guard errno == 0 else { throw PairingDurableStore.Failure.storage }
    return names
  }

  func read(_ url: URL, limit: Int) throws -> Data {
    let parent = try directory(url.deletingLastPathComponent(), create: false)
    defer { close(parent) }
    let fd = try checked(openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK))
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= limit else { throw PairingDurableStore.Failure.storage }
    var bytes = Data(count: Int(info.st_size))
    try bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw PairingDurableStore.Failure.storage }
        offset += count
      }
    }
    var trailing: UInt8 = 0
    guard Darwin.read(fd, &trailing, 1) == 0 else { throw PairingDurableStore.Failure.storage }
    return bytes
  }

  private func write(_ bytes: Data, name: String, parent: Int32) throws {
    let fd = try checked(openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
    var descriptorOpen = true
    do {
      try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw PairingDurableStore.Failure.storage }
          offset += count
        }
      }
      if barriers.fullSync(fd) != 0 { guard barriers.sync(fd) == 0 else { throw PairingDurableStore.Failure.storage } }
      descriptorOpen = false
      guard close(fd) == 0 else { throw PairingDurableStore.Failure.storage }
    } catch {
      if descriptorOpen { close(fd) }
      throw error
    }
  }

  func createExclusive(_ bytes: Data, at url: URL) throws {
    let parent = try directory(url.deletingLastPathComponent(), create: false)
    defer { close(parent) }
    let temp = ".pending-" + UUID().uuidString
    defer { unlinkat(parent, temp, 0) }
    try write(bytes, name: temp, parent: parent)
    guard renameatx_np(parent, temp, parent, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0, barriers.sync(parent) == 0 else { throw PairingDurableStore.Failure.storage }
  }

  func replace(_ bytes: Data, at url: URL) throws {
    let parent = try directory(url.deletingLastPathComponent(), create: false)
    defer { close(parent) }
    let temp = ".pending-" + UUID().uuidString
    defer { unlinkat(parent, temp, 0) }
    try write(bytes, name: temp, parent: parent)
    guard renameat(parent, temp, parent, url.lastPathComponent) == 0, barriers.sync(parent) == 0 else { throw PairingDurableStore.Failure.storage }
  }
}
