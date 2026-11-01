#if SOLARA_PROBES
import Darwin
import Foundation

public enum ProbeFailure: Error, Equatable {
  case invalidEnvelope
  case unsupportedProtocol
  case invalidArgument
  case oversized
  case artifactBudgetExceeded
  case expired
  case duplicate
  case testHooksDenied
  case timeout
  case unsupported
  case notReady
  case windowGone
  case tabGone

  public var code: String {
    switch self {
    case .invalidEnvelope: "invalidEnvelope"
    case .unsupportedProtocol: "unsupportedProtocol"
    case .invalidArgument: "invalidArgument"
    case .oversized: "oversized"
    case .artifactBudgetExceeded: "artifactBudgetExceeded"
    case .expired: "expired"
    case .duplicate: "duplicate"
    case .testHooksDenied: "testHooksDenied"
    case .timeout: "timeout"
    case .unsupported: "unsupported"
    case .notReady: "notReady"
    case .windowGone: "windowGone"
    case .tabGone: "tabGone"
    }
  }
}

public struct ProbeRequest {
  public let id: String
  public let command: String
  public let args: [String: Any]
  public let expiresAtMs: Int64

  public static func decode(_ data: Data, nowMs: Int64) throws -> ProbeRequest {
    guard data.count <= 65_536 else { throw ProbeFailure.oversized }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProbeFailure.invalidEnvelope }
    guard Set(object.keys) == Set(["protocol", "id", "command", "args", "expiresAtMs"]) else { throw ProbeFailure.invalidEnvelope }
    guard let version = object["protocol"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID() else { throw ProbeFailure.invalidEnvelope }
    guard version.intValue == 1, version.doubleValue == 1 else { throw ProbeFailure.unsupportedProtocol }
    guard let id = object["id"] as? String, UUID(uuidString: id) != nil,
      let command = object["command"] as? String, !command.isEmpty, command.utf8.count <= 128,
      let args = object["args"] as? [String: Any],
      let expiry = object["expiresAtMs"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
      expiry.doubleValue == Double(expiry.int64Value) else { throw ProbeFailure.invalidArgument }
    guard expiry.int64Value > nowMs, expiry.int64Value <= nowMs + 60_000 else { throw ProbeFailure.expired }
    return ProbeRequest(id: id, command: command, args: args, expiresAtMs: expiry.int64Value)
  }
}

public struct ProbeSeenIds {
  private var order: [String] = []
  private var ids: Set<String> = []

  public init() {}

  public mutating func insert(_ id: String) -> Bool {
    guard ids.insert(id).inserted else { return false }
    order.append(id)
    if order.count > 1024 { ids.remove(order.removeFirst()) }
    return true
  }
}

public final class ProbeFiles {
  public static let batch = 32
  public let dataPath: String
  private let dataFD: Int32
  private let probesFD: Int32
  private let inboxFD: Int32
  private let claimedFD: Int32
  private let outboxFD: Int32
  private let device: dev_t
  private let inode: ino_t
  private let owner: uid_t
  private let artifactLock = NSLock()

  public static func open(dataPath: String, defaultPath: String, homePath: String) throws -> ProbeFiles {
    guard Self.processStart != nil else { throw ProbeFailure.testHooksDenied }
    guard dataPath.hasPrefix("/"), !dataPath.hasSuffix("/"), !dataPath.contains("/../"), !dataPath.contains("/./") else { throw ProbeFailure.testHooksDenied }
    guard let canonical = realPath(dataPath), canonical == dataPath else { throw ProbeFailure.testHooksDenied }
    let defaultCanonical = realPath(defaultPath) ?? defaultPath
    let homeCanonical = realPath(homePath) ?? homePath
    let forbidden = [defaultCanonical, "\(homeCanonical)/Library", "\(homeCanonical)/Documents", "\(homeCanonical)/Desktop"]
    guard !forbidden.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) else { throw ProbeFailure.testHooksDenied }
    let fd = Darwin.open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ProbeFailure.testHooksDenied }
    do {
      let owner = getuid()
      let initial = try checkedDirectory(fd, owner: owner)
      let marker = openat(fd, ".solara-probe-scratch", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard marker >= 0 else { throw ProbeFailure.testHooksDenied }
      defer { close(marker) }
      var mark = stat()
      guard fstat(marker, &mark) == 0, mark.st_uid == owner, mark.st_mode & S_IFMT == S_IFREG else { throw ProbeFailure.testHooksDenied }
      let probes = try child(fd, "probes", owner: owner)
      do {
        let inbox = try child(probes, "inbox", owner: owner)
        do {
          let claimed = try child(probes, "claimed", owner: owner)
          do {
            let outbox = try child(probes, "outbox", owner: owner)
            return ProbeFiles(dataPath: canonical, dataFD: fd, probesFD: probes, inboxFD: inbox, claimedFD: claimed, outboxFD: outbox, device: initial.st_dev, inode: initial.st_ino, owner: owner)
          } catch { close(claimed); throw error }
        } catch { close(inbox); throw error }
      } catch { close(probes); throw error }
    } catch { close(fd); throw error }
  }

  private init(dataPath: String, dataFD: Int32, probesFD: Int32, inboxFD: Int32, claimedFD: Int32, outboxFD: Int32, device: dev_t, inode: ino_t, owner: uid_t) {
    self.dataPath = dataPath
    self.dataFD = dataFD
    self.probesFD = probesFD
    self.inboxFD = inboxFD
    self.claimedFD = claimedFD
    self.outboxFD = outboxFD
    self.device = device
    self.inode = inode
    self.owner = owner
  }

  deinit {
    close(outboxFD)
    close(claimedFD)
    close(inboxFD)
    close(probesFD)
    close(dataFD)
  }

  public static func realPath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  static func checkedDirectory(_ fd: Int32, owner: uid_t) throws -> stat {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner, info.st_mode & 0o7777 == 0o700 else { throw ProbeFailure.testHooksDenied }
    return info
  }

  private static func child(_ parent: Int32, _ name: String, owner: uid_t) throws -> Int32 {
    if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw ProbeFailure.testHooksDenied }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ProbeFailure.testHooksDenied }
    do { _ = try checkedDirectory(fd, owner: owner); return fd } catch { close(fd); throw error }
  }

  public func recheck() throws {
    let kept = try Self.checkedDirectory(dataFD, owner: owner)
    guard Self.realPath(dataPath) == dataPath else { throw ProbeFailure.testHooksDenied }
    var current = stat()
    guard fstatat(AT_FDCWD, dataPath, &current, 0) == 0, kept.st_dev == device, kept.st_ino == inode, current.st_dev == device, current.st_ino == inode else { throw ProbeFailure.testHooksDenied }
    let marker = openat(dataFD, ".solara-probe-scratch", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard marker >= 0 else { throw ProbeFailure.testHooksDenied }
    defer { close(marker) }
    var mark = stat()
    guard fstat(marker, &mark) == 0, mark.st_uid == owner, mark.st_mode & S_IFMT == S_IFREG else { throw ProbeFailure.testHooksDenied }
    for fd in [probesFD, inboxFD, claimedFD, outboxFD] { _ = try Self.checkedDirectory(fd, owner: owner) }
  }

  private func names(_ fd: Int32) -> [String] {
    let listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard listing >= 0 else { return [] }
    guard let directory = fdopendir(listing) else { close(listing); return [] }
    defer { closedir(directory) }
    var result: [String] = []
    while let entry = readdir(directory) {
      let name = Self.entryName(entry)
      if name != "." && name != ".." { result.append(name) }
      if result.count >= 4096 { break }
    }
    return result
  }

  public func clearStale(now: Date = Date()) {
    artifactLock.lock()
    try? forEachArtifact { name, info in
      let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
      if let processStart = Self.processStart, info.st_mode & S_IFMT == S_IFREG, modified < processStart { unlinkat(dataFD, name, 0) }
    }
    artifactLock.unlock()
    for fd in [claimedFD, outboxFD] {
      for name in names(fd) where name.hasSuffix(".json") || name.hasSuffix(".json.tmp") { unlinkat(fd, name, 0) }
    }
    for name in names(inboxFD) where name.hasSuffix(".json") || name.hasSuffix(".json.tmp") {
      var info = stat()
      if fstatat(inboxFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0, now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 60 { unlinkat(inboxFD, name, 0) }
    }
  }

  public func claim() -> [(String, Data?, ProbeFailure?)] {
    var result: [(String, Data?, ProbeFailure?)] = []
    for name in names(inboxFD) where name.hasSuffix(".json") {
      if result.count >= Self.batch { break }
      let id = String(name.dropLast(5))
      guard UUID(uuidString: id) != nil else { continue }
      guard renameat(inboxFD, name, claimedFD, name) == 0 else { continue }
      let fd = openat(claimedFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else { result.append((id, nil, .invalidEnvelope)); continue }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_size <= 65_536 else {
        close(fd)
        result.append((id, nil, .oversized))
        continue
      }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      result.append((id, try? handle.read(upToCount: 65_537), nil))
    }
    return result
  }

  private static let artifactLimit = 32
  private static let artifactByteLimit: Int64 = 268_435_456
  private static let processStart: Double? = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
    let start = info.kp_proc.p_starttime
    return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
  }()

  static func entryName(_ entry: UnsafePointer<dirent>) -> String {
    let record = UnsafeRawPointer(entry)
    let length = Int(record.load(fromByteOffset: MemoryLayout<dirent>.offset(of: \dirent.d_namlen)!, as: UInt16.self))
    let start = record + MemoryLayout<dirent>.offset(of: \dirent.d_name)!
    return String(decoding: UnsafeRawBufferPointer(start: start, count: length), as: UTF8.self)
  }

  private static func isArtifact(_ name: String) -> Bool {
    let name = name.hasSuffix(".png.tmp") ? String(name.dropLast(4)) : name
    let prefix = ".solara-probe-window-"
    guard name.hasPrefix(prefix), name.hasSuffix(".png") else { return false }
    let id = String(name.dropFirst(prefix.count).dropLast(4))
    return UUID(uuidString: id)?.uuidString.lowercased() == id
  }

  private func forEachArtifact(_ body: (String, stat) throws -> Void) throws {
    let listing = openat(dataFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard listing >= 0 else { throw ProbeFailure.testHooksDenied }
    guard let directory = fdopendir(listing) else { close(listing); throw ProbeFailure.testHooksDenied }
    defer { closedir(directory) }
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw ProbeFailure.testHooksDenied }
        break
      }
      let name = Self.entryName(entry)
      guard Self.isArtifact(name) else { continue }
      var info = stat()
      guard fstatat(dataFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ProbeFailure.testHooksDenied }
      try body(name, info)
    }
  }

  private func checkArtifactBudget(adding bytes: Int64) throws {
    var count = 0
    var total: Int64 = 0
    try forEachArtifact { _, info in
      guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_size >= 0 else { throw ProbeFailure.testHooksDenied }
      count += 1
      let sum = total.addingReportingOverflow(info.st_size)
      guard count < Self.artifactLimit, !sum.overflow, sum.partialValue <= Self.artifactByteLimit else { throw ProbeFailure.artifactBudgetExceeded }
      total = sum.partialValue
    }
    guard bytes > 0, bytes <= Self.artifactByteLimit - total else { throw ProbeFailure.artifactBudgetExceeded }
  }

  public func checkArtifactBudget() throws {
    artifactLock.lock()
    defer { artifactLock.unlock() }
    try recheck()
    try checkArtifactBudget(adding: 1)
  }

  public func writeArtifact(name: String, data: Data, beforePublication: () throws -> Void = {}) throws {
    let prefix = ".solara-probe-window-"
    guard name.hasPrefix(prefix), name.hasSuffix(".png") else { throw ProbeFailure.invalidArgument }
    let id = String(name.dropFirst(prefix.count).dropLast(4))
    guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
      !data.isEmpty, data.count <= 67_108_864 else { throw ProbeFailure.invalidArgument }
    artifactLock.lock()
    defer { artifactLock.unlock() }
    try recheck()
    try checkArtifactBudget(adding: Int64(data.count))
    let temp = name + ".tmp"
    let fd = openat(dataFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ProbeFailure.testHooksDenied }
    defer { close(fd); unlinkat(dataFD, temp, 0) }
    let written = data.withUnsafeBytes { bytes -> Bool in
      guard let base = bytes.baseAddress else { return false }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
    guard written else { throw ProbeFailure.testHooksDenied }
    try recheck()
    try beforePublication()
    guard linkat(dataFD, temp, dataFD, name, 0) == 0 else { throw ProbeFailure.testHooksDenied }
  }

  public func reply(id: String, data: Data, beforePublication: () throws -> Void = {}) throws {
    guard UUID(uuidString: id) != nil, data.count <= 65_536 else { throw ProbeFailure.invalidArgument }
    try recheck()
    let temp = "\(id).json.tmp"
    let final = "\(id).json"
    let fd = openat(outboxFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ProbeFailure.testHooksDenied }
    defer { close(fd); unlinkat(outboxFD, temp, 0) }
    let written = data.withUnsafeBytes { bytes -> Bool in
      guard let base = bytes.baseAddress else { return false }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
    guard written else { throw ProbeFailure.testHooksDenied }
    try recheck()
    try beforePublication()
    guard renameat(outboxFD, temp, outboxFD, final) == 0 else { throw ProbeFailure.testHooksDenied }
    unlinkat(claimedFD, final, 0)
  }
}
#endif
