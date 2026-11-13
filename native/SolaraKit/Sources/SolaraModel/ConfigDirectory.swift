import Foundation

#if canImport(CoreServices)
  import CoreServices
#endif

public struct ConfigLocation: Sendable, Hashable {
  public let url: URL
  public let display: String

  public init(url: URL, display: String? = nil) {
    let standard = url.standardizedFileURL
    self.url = standard
    self.display = display ?? Self.abbreviated(standard.path)
  }

  public static let directoryVariable = "SOLARA_CONFIG_DIR"

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    currentDirectory: String = FileManager.default.currentDirectoryPath
  ) -> ConfigLocation? {
    if let chosen = environment[directoryVariable], !chosen.isEmpty {
      let path = chosen.hasPrefix("/") ? chosen : currentDirectory + "/" + chosen
      return ConfigLocation(url: URL(fileURLWithPath: (path as NSString).standardizingPath, isDirectory: true))
    }
    if environment["SOLARA_DATA_DIR"]?.isEmpty == false || environment["SOLARA_BACKGROUND"] == "1" { return nil }
    return ConfigLocation(url: home.appending(path: ".config/solara", directoryHint: .isDirectory), display: "~/.config/solara")
  }

  public func file(_ name: String) -> URL { url.appending(path: name, directoryHint: .notDirectory) }

  public func display(_ name: String) -> String { display + "/" + name }

  static func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }
}

public enum ConfigRead: Sendable, Equatable {
  case absent
  case contents(Data)
  case unreadable(String)
}

public final class ConfigDirectory: @unchecked Sendable {
  public typealias Observer = @Sendable (Set<String>) -> Void

  public static let maxFileBytes = 1 << 20
  public static let defaultDebounce: TimeInterval = 0.15

  nonisolated(unsafe) public static var shared: ConfigDirectory?

  public let location: ConfigLocation
  public let debounce: TimeInterval
  let delivery: DispatchQueue
  let work = DispatchQueue(label: "solara.config-directory")

  struct State {
    var observers: [Int: Observer] = [:]
    var nextObserver = 0
    var fingerprints: [String: Fingerprint] = [:]
    var pending: DispatchWorkItem?
    var running = false
    var stream: StreamBox?
    var poll: DispatchSourceTimer?
    var linkedFolders: Set<String> = []
  }

  enum Fingerprint: Hashable {
    case contents(Data)
    case unreadable(String)
    case absent
  }

  final class StreamBox {
    #if canImport(CoreServices)
      var stream: FSEventStreamRef?
    #endif
  }

  let lock = NSLock()
  var guarded = State()

  @discardableResult
  func withState<T>(_ body: (inout State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&guarded)
  }

  public init(location: ConfigLocation, debounce: TimeInterval = ConfigDirectory.defaultDebounce, delivery: DispatchQueue = .main) {
    self.location = location
    self.debounce = debounce
    self.delivery = delivery
  }

  deinit { stopNow() }

  public func read(_ name: String) -> ConfigRead {
    Self.read(location.file(name))
  }

  public static func read(_ url: URL) -> ConfigRead {
    var info = stat()
    guard stat(url.path, &info) == 0 else {
      return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable("couldn't be read: \(String(cString: strerror(errno)))")
    }
    switch info.st_mode & S_IFMT {
    case S_IFREG: break
    case S_IFDIR: return .unreadable("is a folder, not a file")
    default: return .unreadable("isn't a regular file")
    }
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
      if data.count > maxFileBytes { return .unreadable("is larger than 1 MB") }
      return .contents(data)
    } catch {
      if !FileManager.default.fileExists(atPath: url.path) { return .absent }
      return .unreadable("couldn't be read: \((error as NSError).localizedDescription)")
    }
  }

  public func names(in folder: String) -> [String] {
    let url = folder.isEmpty ? location.url : location.url.appending(path: folder, directoryHint: .isDirectory)
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    return entries.filter { !$0.hasPrefix(".") }.sorted().map { folder.isEmpty ? $0 : folder + "/" + $0 }
  }

  @discardableResult
  public func observe(_ observer: @escaping Observer) -> Int {
    let (id, start) = withState { s -> (Int, Bool) in
      let id = s.nextObserver
      s.nextObserver += 1
      s.observers[id] = observer
      return (id, !s.running)
    }
    if start { self.start() }
    return id
  }

  public func removeObserver(_ id: Int) {
    let stop = withState { s -> Bool in
      s.observers.removeValue(forKey: id)
      return s.observers.isEmpty
    }
    if stop { stopNow() }
  }

  public func rescanNow() {
    work.async { self.rescan() }
  }

  func start() {
    let begin = withState { s -> Bool in
      if s.running { return false }
      s.running = true
      return true
    }
    guard begin else { return }
    work.sync {
      let first = self.fingerprints()
      let linked = self.linkedFolders()
      self.withState {
        $0.fingerprints = first
        $0.linkedFolders = linked
      }
    }
    #if canImport(CoreServices)
      startStream()
    #else
      startPolling()
    #endif
  }

  func stopNow() {
    let (box, poll, pending) = withState { s -> (StreamBox?, DispatchSourceTimer?, DispatchWorkItem?) in
      s.running = false
      defer {
        s.stream = nil
        s.poll = nil
        s.pending = nil
      }
      return (s.stream, s.poll, s.pending)
    }
    pending?.cancel()
    poll?.cancel()
    #if canImport(CoreServices)
      if let stream = box?.stream {
        box?.stream = nil
        work.async { Self.tearDown(stream) }
      }
    #else
      _ = box
    #endif
  }

  func watchedPaths() -> [String] {
    let parent = location.url.deletingLastPathComponent().path
    return Array(Set(folderPaths() + [parent]))
  }

  func folderPaths() -> [String] {
    let direct = location.url.path
    let resolved = location.url.resolvingSymlinksInPath().path
    return Array(Set([direct, resolved, Self.realPath(direct)]).union(withState { $0.linkedFolders }))
  }

  static func realPath(_ path: String) -> String {
    if let resolved = realpath(path, nil) {
      defer { free(resolved) }
      return String(cString: resolved)
    }
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent().path
    guard parent != path, parent != "/" else { return path }
    return realPath(parent) + "/" + url.lastPathComponent
  }

  func linkedFolders() -> Set<String> {
    var out = Set<String>()
    func follow(_ name: String) {
      let url = location.file(name)
      guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink else { return }
      let target = URL(fileURLWithPath: Self.realPath(url.path))
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return }
      out.insert(isDirectory.boolValue ? target.path : target.deletingLastPathComponent().path)
    }
    for name in names(in: "") {
      follow(name)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: location.file(name).path, isDirectory: &isDirectory), isDirectory.boolValue {
        for inner in names(in: name) { follow(inner) }
      }
    }
    return out
  }

  func concerns(_ path: String) -> Bool {
    for folder in folderPaths() where path == folder || path.hasPrefix(folder + "/") { return true }
    return false
  }

  #if canImport(CoreServices)
    func startStream() {
      let box = StreamBox()
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
        retain: { info in
          guard let info else { return nil }
          _ = Unmanaged<ConfigDirectory>.fromOpaque(info).retain()
          return info
        },
        release: { info in
          guard let info else { return }
          Unmanaged<ConfigDirectory>.fromOpaque(info).release()
        },
        copyDescription: nil)
      let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let directory = Unmanaged<ConfigDirectory>.fromOpaque(info).takeUnretainedValue()
        let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        let broad = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs)
        for index in 0..<count where flags[index] & broad != 0 || directory.concerns(String(cString: names[index])) {
          directory.noteEvent()
          return
        }
      }
      let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
      guard let stream = FSEventStreamCreate(
        nil, callback, &context, watchedPaths() as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
      else {
        startPolling()
        return
      }
      FSEventStreamSetDispatchQueue(stream, work)
      FSEventStreamStart(stream)
      box.stream = stream
      let kept = withState { s -> Bool in
        guard s.running, s.stream == nil, s.poll == nil else { return false }
        s.stream = box
        return true
      }
      if !kept {
        box.stream = nil
        work.async { Self.tearDown(stream) }
      }
    }

    static func tearDown(_ stream: FSEventStreamRef) {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }

    #if DEBUG
    var streamCount: Int { withState { $0.stream?.stream == nil ? 0 : 1 } }
    #endif

    func restartStream() {
      let old = withState { s -> StreamBox? in
        guard s.running, s.poll == nil else { return nil }
        defer { s.stream = nil }
        return s.stream
      }
      guard let old, let stream = old.stream else { return }
      old.stream = nil
      Self.tearDown(stream)
      startStream()
    }
  #endif

  func startPolling() {
    let timer = DispatchSource.makeTimerSource(queue: work)
    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
    timer.setEventHandler { [weak self] in self?.rescan() }
    timer.resume()
    let kept = withState { s -> Bool in
      guard s.running, s.poll == nil, s.stream == nil else { return false }
      s.poll = timer
      return true
    }
    if !kept { timer.cancel() }
  }

  func noteEvent() {
    let item = DispatchWorkItem { [weak self] in self?.rescan() }
    let previous = withState { s -> DispatchWorkItem? in
      guard s.running else { return nil }
      let old = s.pending
      s.pending = item
      return old
    }
    previous?.cancel()
    work.asyncAfter(deadline: .now() + debounce, execute: item)
  }

  func fingerprints() -> [String: Fingerprint] {
    var out: [String: Fingerprint] = [:]
    for name in names(in: "") {
      var isDirectory: ObjCBool = false
      let url = location.file(name)
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        for inner in names(in: name) { out[inner] = fingerprint(inner) }
      } else {
        out[name] = fingerprint(name)
      }
    }
    return out
  }

  func fingerprint(_ name: String) -> Fingerprint {
    switch read(name) {
    case .contents(let data): .contents(data)
    case .unreadable(let reason): .unreadable(reason)
    case .absent: .absent
    }
  }

  func rescan() {
    let next = fingerprints()
    let linked = linkedFolders()
    let (changed, observers, relink) = withState { s -> (Set<String>, [Observer], Bool) in
      guard s.running else { return ([], [], false) }
      var changed = Set<String>()
      for (name, print) in next where s.fingerprints[name] != print { changed.insert(name) }
      for name in s.fingerprints.keys where next[name] == nil { changed.insert(name) }
      s.fingerprints = next
      let relink = s.linkedFolders != linked
      s.linkedFolders = linked
      return (changed, Array(s.observers.values), relink)
    }
    #if canImport(CoreServices)
      if relink { restartStream() }
    #else
      _ = relink
    #endif
    guard !changed.isEmpty, !observers.isEmpty else { return }
    delivery.async { for observer in observers { observer(changed) } }
  }
}
