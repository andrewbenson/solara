import CryptoKit
import Foundation

public struct HookProgramFile: Codable, Sendable, Equatable {
  public var path: String
  public var sha256: String
  public var dev: UInt64
  public var ino: UInt64
  public var size: Int64
  public var mtime: Double
}

public struct HookApprovalRecord: Codable, Sendable, Equatable {
  public var name: String
  public var approvedAt: Double
  public var text: String?
  public var files: [HookProgramFile]?
  public var folder: String?
  public var folderIdentity: HookFileIdentity?
}

public enum HookApprovalState: Sendable, Equatable {
  case notNeeded
  case needed
  case approved
  case changed(previous: String)
  case filesChanged(String)
}

public enum HookRunCheck: Sendable, Equatable {
  case refused(String)
  case allowed(program: String, dev: UInt64, ino: UInt64)
}

public enum HookFingerprint {
  public static let interpreters: Set<String> = [
    "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "osascript", "python", "python3", "perl", "ruby", "node", "env",
    "open", "php", "lua", "tclsh", "swift", "xargs", "awk", "launchctl", "nohup", "nice", "time", "timeout", "caffeinate", "sudo",
    "arch", "xcrun", "script", "find", "ssh", "java", "deno", "bun", "pwsh", "rscript", "shortcuts", "automator", "sed", "make",
    "git", "npx", "npm", "pnpm", "yarn", "uv", "pipx", "jshell", "kotlin", "scala", "groovy", "julia", "elixir", "erl", "go",
    "cargo", "screen", "tmux", "expect", "wish", "watch", "parallel", "su", "doas",
  ]

  public static func program(_ argv: [String], home: String) -> String {
    guard let first = argv.first else { return "" }
    return first.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(first.dropFirst(2))) : first
  }

  public static func isInterpreter(_ program: String) -> Bool {
    var names = [(program as NSString).lastPathComponent.lowercased()]
    if let real = realpath(program, nil) {
      names.append((String(cString: real) as NSString).lastPathComponent.lowercased())
      free(real)
    }
    return names.contains { name in
      interpreters.contains(name) || ["python", "perl", "ruby", "node", "php", "java", "lua", "tcl"].contains { name.hasPrefix($0) }
    }
  }

  public static func resolve(_ argument: String, home: String) -> String {
    if argument.hasPrefix("~/") { return ((home as NSString).appendingPathComponent(String(argument.dropFirst(2))) as NSString).standardizingPath }
    if argument.hasPrefix("/") { return (argument as NSString).standardizingPath }
    return ((home as NSString).appendingPathComponent(argument) as NSString).standardizingPath
  }

  static func candidates(_ argv: [String], home: String) -> [String] {
    argv.dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("-") && $0.utf8.count <= 1024 }.map { resolve($0, home: home) }
  }

  public static func fileArguments(_ argv: [String], home: String) -> [String] {
    var paths = [program(argv, home: home)]
    for expanded in candidates(argv, home: home) {
      var info = stat()
      if stat(expanded, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, !paths.contains(expanded) { paths.append(expanded) }
    }
    return paths
  }

  public static func folderArgument(_ argv: [String], home: String) -> String? {
    guard isInterpreter(program(argv, home: home)) else { return nil }
    for (expanded, given) in zip(candidates(argv, home: home), argv.dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("-") && $0.utf8.count <= 1024 }) {
      var info = stat()
      if stat(expanded, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { return given }
    }
    return nil
  }

  public static func writableProblem(_ path: String) -> String? {
    var info = stat()
    guard stat(path, &info) == 0 else { return "\(path) doesn't exist" }
    guard (info.st_mode & S_IFMT) == S_IFREG else { return "\(path) isn't a regular file" }
    if info.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "\(path) can be changed by other users (group or world writable)" }
    if info.st_uid != getuid() && info.st_uid != 0 { return "\(path) belongs to another user" }
    guard let real = realpath(path, nil) else { return "\(path) can't be resolved" }
    defer { free(real) }
    let folder = (String(cString: real) as NSString).deletingLastPathComponent
    var folderInfo = stat()
    guard stat(folder, &folderInfo) == 0 else { return "\(folder) can't be read" }
    if folderInfo.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "\(folder) can be changed by other users (group or world writable)" }
    if folderInfo.st_uid != getuid() && folderInfo.st_uid != 0 { return "\(folder) belongs to another user" }
    return nil
  }

  public static func userWritableFolder(_ path: String) -> Bool {
    guard let real = realpath(path, nil) else { return false }
    defer { free(real) }
    let folder = (String(cString: real) as NSString).deletingLastPathComponent
    return access(folder, W_OK) == 0
  }

  public static func file(_ path: String) -> HookProgramFile? {
    guard let real = realpath(path, nil) else { return nil }
    let resolved = String(cString: real)
    free(real)
    let descriptor = open(resolved, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 65536)
    var total: Int64 = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, 65536) }
      if count < 0 { return nil }
      if count == 0 { break }
      total += Int64(count)
      if total > 512 * 1_048_576 { return nil }
      buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    return HookProgramFile(
      path: path, sha256: digest, dev: UInt64(UInt32(bitPattern: info.st_dev)), ino: UInt64(info.st_ino), size: Int64(info.st_size), mtime: mtime)
  }

  public static func files(_ argv: [String], home: String) -> Result<[HookProgramFile], HookApprovalError> {
    if let folder = folderArgument(argv, home: home) {
      return .failure(.refused("\(folder) is a folder, and \((program(argv, home: home) as NSString).lastPathComponent) would run whatever is in it; name a file instead"))
    }
    var result: [HookProgramFile] = []
    for path in fileArguments(argv, home: home) {
      if let problem = writableProblem(path) { return .failure(.refused(problem)) }
      guard let entry = Self.file(path) else { return .failure(.refused("\(path) can't be read")) }
      result.append(entry)
    }
    return .success(result)
  }

  public static func changes(_ approved: [HookProgramFile], argv: [String], home: String) -> String? {
    if let folder = folderArgument(argv, home: home) { return "\(folder) is now a folder" }
    let now = fileArguments(argv, home: home)
    if now.count != approved.count || Set(now) != Set(approved.map(\.path)) { return "the files the command uses changed" }
    for file in approved {
      if let problem = writableProblem(file.path) { return problem }
      guard let current = Self.file(file.path) else { return "\(file.path) can't be read" }
      if current != file { return "\(file.path) changed since it was approved" }
    }
    return nil
  }
}

public enum HookApprovalError: Error, Equatable, Sendable {
  case refused(String)
  case stale
}

public final class HookApprovals: @unchecked Sendable {
  public let file: URL?
  private let lock = NSLock()
  private var records: [String: HookApprovalRecord] = [:]

  public init(file: URL?) {
    self.file = file
    guard let file, let data = try? Data(contentsOf: file),
      let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 2
    else { return }
    records = stored.approved
  }

  struct Stored: Codable {
    var version: Int
    var approved: [String: HookApprovalRecord]
  }

  public func record(_ digest: String) -> HookApprovalRecord? {
    lock.lock()
    defer { lock.unlock() }
    return records[digest]
  }

  public func isApproved(_ digest: String) -> Bool { record(digest) != nil }

  public var digests: Set<String> {
    lock.lock()
    defer { lock.unlock() }
    return Set(records.keys)
  }

  public func previousText(named name: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return records.values.filter { $0.name.lowercased() == name.lowercased() }.max { $0.approvedAt < $1.approvedAt }?.text
  }

  public func state(_ rule: HookRule, home: String) -> HookApprovalState {
    guard rule.needsApproval else { return .notNeeded }
    guard let record = record(rule.digest) else {
      if let previous = previousText(named: rule.name), previous != rule.text { return .changed(previous: previous) }
      return .needed
    }
    if let problem = problem(rule, record: record, home: home) { return .filesChanged(problem) }
    return .approved
  }

  public func problem(_ rule: HookRule, record: HookApprovalRecord, home: String) -> String? {
    switch rule.action {
    case .run(let argv, _, _):
      return HookFingerprint.changes(record.files ?? [], argv: argv, home: home)
    case .fileInto(let text):
      guard let folder = HookFolder(text, home: home) else { return "the folder isn't valid" }
      if folder.insideDownloads { return nil }
      guard let identity = record.folderIdentity, record.folder == folder.resolved,
        HookFolder.directoryIdentity(folder.resolved) == identity
      else { return "\(text) isn't the folder that was approved" }
      return nil
    default:
      return nil
    }
  }

  public func usable(_ rule: HookRule, home: String) -> Bool {
    guard rule.needsApproval else { return true }
    guard let record = record(rule.digest) else { return false }
    switch rule.action {
    case .fileInto: return problem(rule, record: record, home: home) == nil
    default: return true
    }
  }

  public func verifyBeforeRun(_ rule: HookRule, home: String) -> String? {
    guard rule.needsApproval else { return nil }
    guard let record = record(rule.digest) else { return "not approved" }
    return problem(rule, record: record, home: home)
  }

  public func checkBeforeRun(_ rule: HookRule, home: String) -> HookRunCheck {
    guard case .run = rule.action else { return .refused("not a command") }
    guard let record = record(rule.digest) else { return .refused("not approved") }
    if let problem = problem(rule, record: record, home: home) { return .refused(problem) }
    guard let program = record.files?.first, let real = realpath(program.path, nil) else { return .refused("the program can't be resolved") }
    defer { free(real) }
    return .allowed(program: String(cString: real), dev: program.dev, ino: program.ino)
  }

  public static func snapshot(_ rule: HookRule, home: String, files given: [HookProgramFile]? = nil) -> String {
    var lines = ["name: " + HookText.escaped(rule.name), "rule: " + HookText.escaped(rule.text)]
    switch rule.action {
    case .run(let argv, _, _):
      let program = HookFingerprint.program(argv, home: home)
      lines.append("program: " + HookText.escaped(program))
      for (index, argument) in argv.dropFirst().enumerated() { lines.append("argument \(index + 1): " + HookText.escaped(argument)) }
      if let files = given ?? (try? HookFingerprint.files(argv, home: home).get()) {
        for file in files { lines.append("file: " + HookText.escaped(file.path) + " sha256 " + file.sha256) }
      } else {
        for path in HookFingerprint.fileArguments(argv, home: home) { lines.append("file: " + HookText.escaped(path) + " unreadable") }
      }
    case .fileInto(let text):
      if let folder = HookFolder(text, home: home) { lines.append("folder: " + HookText.escaped(folder.resolved)) }
    default:
      break
    }
    return lines.joined(separator: "\n")
  }

  public static func snapshotHash(_ snapshot: String) -> String {
    SHA256.hash(data: Data(snapshot.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public func approve(_ rule: HookRule, snapshotHash: String, home: String, now: Date = Date()) -> Result<Void, HookApprovalError> {
    var files: [HookProgramFile]?
    if case .run(let argv, _, _) = rule.action {
      switch HookFingerprint.files(argv, home: home) {
      case .failure(let error): return .failure(error)
      case .success(let found): files = found
      }
    }
    guard Self.snapshotHash(Self.snapshot(rule, home: home, files: files)) == snapshotHash else { return .failure(.stale) }
    var record = HookApprovalRecord(name: rule.name, approvedAt: now.timeIntervalSince1970 * 1000, text: rule.text)
    switch rule.action {
    case .run:
      record.files = files
    case .fileInto(let text):
      guard let folder = HookFolder(text, home: home) else { return .failure(.refused("the folder isn't valid")) }
      if !folder.insideDownloads {
        guard let identity = HookFolder.directoryIdentity(folder.resolved) else {
          return .failure(.refused("\(folder.resolved) must exist as a folder (not a link) before it can be approved"))
        }
        record.folder = folder.resolved
        record.folderIdentity = identity
      }
    default:
      break
    }
    update { $0[rule.digest] = record }
    return .success(())
  }

  public func revoke(_ digest: String) {
    update { $0[digest] = nil }
  }

  public func keepOnly(_ digests: Set<String>, names: Set<String>) {
    lock.lock()
    var latest: [String: (String, Double)] = [:]
    for (digest, record) in records where !digests.contains(digest) && names.contains(record.name.lowercased()) {
      let key = record.name.lowercased()
      if (latest[key]?.1 ?? -1) < record.approvedAt { latest[key] = (digest, record.approvedAt) }
    }
    let kept = Set(latest.values.map(\.0))
    let stale = records.keys.filter { !digests.contains($0) && !kept.contains($0) }
    lock.unlock()
    guard !stale.isEmpty else { return }
    update { records in for digest in stale { records[digest] = nil } }
  }

  private func update(_ change: (inout [String: HookApprovalRecord]) -> Void) {
    lock.lock()
    change(&records)
    let snapshot = records
    lock.unlock()
    guard let file else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let data = try? encoder.encode(Stored(version: 2, approved: snapshot)) else { return }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(getpid()).tmp")
    unlink(temporary.path)
    guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
    if rename(temporary.path, file.path) != 0 { unlink(temporary.path) }
  }
}
