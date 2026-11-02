import Darwin
import Foundation

struct DiscoveryEntry: Equatable {
  let name: String
  let isRealDirectory: Bool
  let activity: Date?
  var isPlaceholder = false
}

enum DiscoveryScan: Equatable {
  case listing([DiscoveryEntry], dataless: Bool, truncated: Bool)
  case missing, unavailable, denied
}

protocol DiscoveryFileSystem: AnyObject {
  func scan(_ folder: URL, limit: Int) -> DiscoveryScan
  func requestDownload(_ url: URL)
}

final class SyncDiscovery {
  static let entriesPerPass = 256
  static let entriesPerChain = 16

  struct Candidate: Equatable {
    let cid: String
    let lastActivity: Date?
  }

  enum Result: Equatable {
    case found([Candidate])
    case empty, needsHydration, unavailable, permissionDenied, timedOut
  }

  typealias Sleep = @Sendable (Duration) async -> Void
  static let continuousSleep: Sleep = { try? await Task.sleep(for: $0, clock: .continuous) }

  private static let worker = DispatchQueue(label: "solara.sync.discovery", qos: .utility)
  private static let lock = NSLock()
  private static var busy = false
  private static var waiting: [Request] = []

  let folder: URL
  let timeout: Duration
  let fileSystem: DiscoveryFileSystem
  let sleep: Sleep

  init(folder: URL, timeout: Duration = .seconds(10), fileSystem: DiscoveryFileSystem = LiveDiscoveryFileSystem(), sleep: @escaping Sleep = SyncDiscovery.continuousSleep) {
    self.folder = folder
    self.timeout = timeout
    self.fileSystem = fileSystem
    self.sleep = sleep
  }

  func run(_ done: @escaping (Result) -> Void) {
    let request = Request(folder: folder, fileSystem: fileSystem, answer: Answer(done))
    let sleep = sleep, timeout = timeout
    Task.detached(priority: .utility) {
      await sleep(timeout)
      request.answer.once(.timedOut)
    }
    let start = Self.lock.withLock { () -> Bool in
      if Self.busy {
        Self.waiting.append(request)
        return false
      }
      Self.busy = true
      return true
    }
    if start { Self.scan([request]) }
  }

  private static func scan(_ batch: [Request]) {
    worker.async {
      let first = batch[0]
      let result = Self.result(of: first.fileSystem.scan(first.folder, limit: entriesPerPass), folder: first.folder, fileSystem: first.fileSystem)
      for request in batch where !request.answer.answered { request.answer.once(result) }
      let next = lock.withLock { () -> [Request] in
        let live = waiting.filter { !$0.answer.answered }
        let next = live.filter { $0.sameScan(as: live.first) }
        waiting = live.filter { !$0.sameScan(as: live.first) }
        if next.isEmpty { busy = false }
        return next
      }
      if !next.isEmpty { scan(next) }
    }
  }

  private struct Request {
    let folder: URL
    let fileSystem: DiscoveryFileSystem
    let answer: Answer

    func sameScan(as other: Request?) -> Bool {
      guard let other else { return false }
      return folder.standardizedFileURL == other.folder.standardizedFileURL && fileSystem === other.fileSystem
    }
  }

  static func result(of scan: DiscoveryScan, folder: URL, fileSystem: DiscoveryFileSystem) -> Result {
    switch scan {
    case .missing: return .empty
    case .unavailable: return .unavailable
    case .denied: return .permissionDenied
    case .listing(let entries, let dataless, let truncated):
      if dataless { fileSystem.requestDownload(folder) }
      let canonical = entries.filter { (try? PairingFormat.cid($0.name)) != nil }
      let placeholders = canonical.filter(\.isPlaceholder)
      for placeholder in placeholders { fileSystem.requestDownload(folder.appendingPathComponent(placeholder.name, isDirectory: true)) }
      let candidates = canonical
        .filter { $0.isRealDirectory && !$0.isPlaceholder }
        .map { Candidate(cid: $0.name, lastActivity: $0.activity) }
        .sorted { $0.cid < $1.cid }
      if !candidates.isEmpty { return .found(candidates) }
      if dataless || !placeholders.isEmpty { return .needsHydration }
      return truncated ? .unavailable : .empty
    }
  }

  private final class Answer {
    private let lock = NSLock()
    private var done: ((Result) -> Void)?
    init(_ done: @escaping (Result) -> Void) { self.done = done }
    var answered: Bool { lock.withLock { done == nil } }
    func once(_ result: Result) {
      guard let done = lock.withLock({ () -> ((Result) -> Void)? in
        defer { self.done = nil }
        return self.done
      }) else { return }
      done(result)
    }
  }
}

final class LiveDiscoveryFileSystem: DiscoveryFileSystem {
  func scan(_ folder: URL, limit: Int) -> DiscoveryScan {
    if SyncFolder.isInICloudDrive(folder), !SyncFolder.iCloudDriveAvailable { return .unavailable }
    let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      switch errno {
      case ENOENT: return Self.placeholder(of: folder) ? .listing([], dataless: true, truncated: false) : .missing
      case EACCES, EPERM, ELOOP, ENOTDIR: return .denied
      default: return .unavailable
      }
    }
    defer { close(fd) }
    let values = try? folder.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    let dataless = values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus.map { $0 != .current } == true
    guard let listing = Self.names(fd, limit: limit) else { return errno == EACCES || errno == EPERM ? .denied : .unavailable }
    var entries: [DiscoveryEntry] = []
    for name in listing.names {
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        let tag = String(name.dropFirst().dropLast(".icloud".count))
        if tag.utf8.count == 26 { entries.append(DiscoveryEntry(name: tag, isRealDirectory: false, activity: nil, isPlaceholder: true)) }
        continue
      }
      guard name.utf8.count == 26 else { continue }
      var info = stat()
      let real = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFDIR
      var activity = real ? Self.date(info) : nil
      if real {
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if child >= 0 {
          for subName in Self.names(child, limit: SyncDiscovery.entriesPerChain)?.names ?? [] {
            var subInfo = stat()
            if fstatat(child, subName, &subInfo, AT_SYMLINK_NOFOLLOW) == 0, subInfo.st_mode & S_IFMT == S_IFDIR, let date = Self.date(subInfo) {
              activity = max(activity ?? date, date)
            }
          }
          close(child)
        }
      }
      entries.append(DiscoveryEntry(name: name, isRealDirectory: real, activity: activity))
    }
    return .listing(entries, dataless: dataless, truncated: listing.truncated)
  }

  func requestDownload(_ url: URL) {
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
  }

  static func names(_ fd: Int32, limit: Int) -> (names: [String], truncated: Bool)? {
    let copy = dup(fd)
    guard copy >= 0 else { return nil }
    guard let stream = fdopendir(copy) else {
      close(copy)
      return nil
    }
    defer { closedir(stream) }
    var names: [String] = []
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      guard names.count < limit else { return (names, true) }
      names.append(name)
    }
    return (names, false)
  }

  static func placeholder(of folder: URL) -> Bool {
    let parent = open(folder.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { return false }
    defer { close(parent) }
    var info = stat()
    return fstatat(parent, ".\(folder.lastPathComponent).icloud", &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG
  }

  static func date(_ info: stat) -> Date? {
    Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
  }
}
