import Foundation

public struct HookEventData: Sendable, Equatable {
  public var event: HookEvent
  public var url: String?
  public var profile: String?
  public var title: String?
  public var file: String?
  public var mime: String?
  public var sender: HookSender?
  public var app: String? { sender?.identifier }

  public init(event: HookEvent, url: String? = nil, profile: String? = nil, title: String? = nil, file: String? = nil, mime: String? = nil, sender: HookSender? = nil) {
    self.event = event
    self.url = url
    self.profile = profile
    self.title = title
    self.file = file.flatMap { $0.hasPrefix("/") ? ($0 as NSString).standardizingPath : nil }
    self.mime = mime
    self.sender = sender
  }

  var fields: [(String, String?)] {
    [("URL", url), ("PROFILE", profile), ("TITLE", title), ("FILE", file), ("MIME", mime), ("APP", app)]
  }

  public func json(hook: String) -> Data {
    var object: [String: Any] = ["hook": HookCommand.clean(hook), "event": event.rawValue]
    for (key, value) in fields { if let value { object[key.lowercased()] = HookCommand.clean(value) } }
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
  }
}

public struct HookCommand: Sendable, Equatable {
  public static let valueLimit = 4096
  public static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"

  public let argv: [String]
  public let environment: [String]
  public let stdin: Data
  public let directory: String

  public init(rule: String, argv given: [String], data: HookEventData, home: String = HookFolder.userHome, user: String = NSUserName(), temporary: String = NSTemporaryDirectory()) {
    var argv = given
    argv[0] = HookFingerprint.program(given, home: home)
    self.argv = argv
    var environment = [
      "PATH=\(Self.basePath)", "HOME=\(home)", "USER=\(user)", "LOGNAME=\(user)", "TMPDIR=\(temporary)", "LANG=en_US.UTF-8",
      "SOLARA_HOOK=\(Self.clean(rule))", "SOLARA_EVENT=\(data.event.rawValue)",
    ]
    for (key, value) in data.fields { if let value { environment.append("SOLARA_\(key)=\(Self.clean(value))") } }
    self.environment = environment
    stdin = data.json(hook: rule)
    directory = home
  }

  public static func clean(_ value: String) -> String {
    var text = HookText.clean(value)
    if text.utf8.count > valueLimit {
      var cut = text.utf8.prefix(valueLimit)
      while String(cut) == nil { cut = cut.dropLast() }
      text = String(cut)!
    }
    return text
  }
}

#if os(macOS)
public final class HookCommandRunner: @unchecked Sendable {
  public static let perRule = 2
  public static let overall = 8
  public static let queueLimit = 16
  public static let downloadQueueLimit = 256
  public static let perMinute = 30
  public static let logLimit: off_t = 1_048_576
  public static let outputLimit = 65536
  public static let outputGrace: TimeInterval = 2

  public struct Launch: Sendable {
    public let rule: String
    public let pid: pid_t
  }

  struct Job: Sendable {
    let digest: String
    let rule: String
    let event: HookEvent
    let command: HookCommand
    let timeout: TimeInterval
  }

  final class Child: @unchecked Sendable {
    let pid: pid_t
    var reaped = false
    var source: DispatchSourceProcess?
    private let lock = NSLock()
    private var endedAt: TimeInterval?

    init(pid: pid_t) {
      self.pid = pid
    }

    func ended() {
      lock.lock()
      endedAt = ProcessInfo.processInfo.systemUptime
      lock.unlock()
    }

    var readerExpired: Bool {
      lock.lock()
      defer { lock.unlock() }
      guard let endedAt else { return false }
      return ProcessInfo.processInfo.systemUptime - endedAt > HookCommandRunner.outputGrace
    }
  }

  private let queue = DispatchQueue(label: "solara.hooks.commands")
  private let logQueue = DispatchQueue(label: "solara.hooks.log", qos: .utility)
  private let stamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private let log: URL?
  private var running: [String: Int] = [:]
  private var total = 0
  private var waiting: [String: [Job]] = [:]
  private var arrival: [String] = []
  private var recent: [String: [TimeInterval]] = [:]
  private var dropped: [String: Int] = [:]
  public var onLaunch: (@Sendable (Launch) -> Void)?
  public var onExit: (@Sendable (String, Int32) -> Void)?
  public var verify: (@Sendable (String) -> HookRunCheck)?

  private let downloadLimit: Int

  public init(log: URL?, downloadQueueLimit: Int = HookCommandRunner.downloadQueueLimit) {
    self.log = log
    downloadLimit = downloadQueueLimit
  }

  public var dropCounts: [String: Int] {
    queue.sync { dropped }
  }

  public func run(digest: String, rule: String, event: HookEvent, command: HookCommand, timeout: TimeInterval) {
    queue.async {
      let now = ProcessInfo.processInfo.systemUptime
      let times = (self.recent[digest] ?? []).filter { now - $0 < 60 }
      if times.count >= Self.perMinute && event != .downloadFinished {
        self.recent[digest] = times
        self.drop(digest, rule, "more than \(Self.perMinute) runs in a minute; skipped")
        return
      }
      self.recent[digest] = times + [now]
      var list = self.waiting[digest] ?? []
      list.append(Job(digest: digest, rule: rule, event: event, command: command, timeout: timeout))
      if list.filter({ $0.event != .downloadFinished }).count > Self.queueLimit, let oldest = list.firstIndex(where: { $0.event != .downloadFinished }) {
        list.remove(at: oldest)
        self.drop(digest, rule, "too many waiting runs; the oldest was dropped")
      }
      if list.filter({ $0.event == .downloadFinished }).count > self.downloadLimit, let oldest = list.firstIndex(where: { $0.event == .downloadFinished }) {
        list.remove(at: oldest)
        self.drop(digest, rule, "more than \(self.downloadLimit) finished downloads waiting; the oldest was dropped")
      }
      self.waiting[digest] = list
      self.arrival.append(digest)
      self.pump()
    }
  }

  private func drop(_ digest: String, _ rule: String, _ why: String) {
    dropped[digest, default: 0] += 1
    note("hook \(rule): \(why)")
  }

  private func pump() {
    var index = 0
    while index < arrival.count && total < Self.overall {
      let digest = arrival[index]
      guard var list = waiting[digest], !list.isEmpty else {
        arrival.remove(at: index)
        continue
      }
      if running[digest, default: 0] >= Self.perRule {
        index += 1
        continue
      }
      let job = list.removeFirst()
      waiting[digest] = list.isEmpty ? nil : list
      arrival.remove(at: index)
      start(job)
    }
  }

  private func start(_ job: Job) {
    let check = verify?(job.digest) ?? .refused("nothing is set up to check it")
    guard case .allowed(let program, let dev, let ino) = check else {
      if case .refused(let problem) = check {
        note("hook \(job.rule): not run: \(problem); approve it again in Settings › Advanced › Hooks")
      }
      return
    }
    switch Self.spawn(job.command, program: program, dev: dev, ino: ino) {
    case .failure(let failure):
      note("hook \(job.rule): couldn't start \(job.command.argv[0]) (\(failure.reason))")
    case .success(let (pid, input, output)):
      running[job.digest, default: 0] += 1
      total += 1
      note("hook \(job.rule): started pid \(pid)")
      onLaunch?(Launch(rule: job.rule, pid: pid))
      let child = Child(pid: pid)
      feed(input, job.command.stdin, child: child, deadline: ProcessInfo.processInfo.systemUptime + job.timeout)
      collect(output, rule: job.rule, child: child)
      let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
      child.source = source
      source.setEventHandler { [weak self] in self?.reap(child, job: job) }
      source.resume()
      reap(child, job: job)
      queue.asyncAfter(deadline: .now() + job.timeout) { [weak self] in
        guard let self, !child.reaped else { return }
        self.note("hook \(job.rule): pid \(pid) ran past \(Int(job.timeout)) s; stopping it")
        killpg(pid, SIGTERM)
        self.queue.asyncAfter(deadline: .now() + 2) {
          if !child.reaped { killpg(pid, SIGKILL) }
        }
      }
    }
  }

  public static func unverified(_ path: String) -> HookRunCheck {
    guard let real = realpath(path, nil) else { return .refused("\(path) can't be resolved") }
    let resolved = String(cString: real)
    free(real)
    var info = stat()
    guard lstat(resolved, &info) == 0 else { return .refused("\(path) can't be read") }
    return .allowed(program: resolved, dev: UInt64(UInt32(bitPattern: info.st_dev)), ino: UInt64(info.st_ino))
  }

  private func reap(_ child: Child, job: Job) {
    guard !child.reaped else { return }
    var info = siginfo_t()
    var waited: Int32
    repeat { waited = waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOHANG | WNOWAIT) } while waited < 0 && errno == EINTR
    guard waited == 0, info.si_pid == child.pid else { return }
    killpg(child.pid, SIGKILL)
    var status: Int32 = 0
    var result: pid_t
    repeat { result = waitpid(child.pid, &status, 0) } while result < 0 && errno == EINTR
    guard result == child.pid else { return }
    child.reaped = true
    child.ended()
    child.source?.cancel()
    child.source = nil
    running[job.digest, default: 1] -= 1
    if running[job.digest] == 0 { running[job.digest] = nil }
    total -= 1
    let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
    note("hook \(job.rule): pid \(child.pid) ended (\(code))")
    onExit?(job.rule, code)
    pump()
  }

  private func feed(_ input: Int32, _ body: Data, child: Child, deadline: TimeInterval) {
    _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK)
    Thread.detachNewThread {
      body.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count && !child.readerExpired && ProcessInfo.processInfo.systemUptime < deadline {
          let written = write(input, raw.baseAddress! + offset, raw.count - offset)
          if written > 0 {
            offset += written
            continue
          }
          if written < 0 && errno == EINTR { continue }
          guard written < 0 && errno == EAGAIN else { break }
          var wanted = pollfd(fd: input, events: Int16(POLLOUT), revents: 0)
          _ = poll(&wanted, 1, 250)
        }
      }
      close(input)
    }
  }

  private func collect(_ output: Int32, rule: String, child: Child) {
    let pid = child.pid
    _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK)
    Thread.detachNewThread { [weak self] in
      var kept = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      var truncated = false
      var abandoned = false
      reading: while true {
        var wanted = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
        let ready = poll(&wanted, 1, 250)
        if ready < 0 && errno != EINTR { break }
        if ready <= 0 {
          if child.readerExpired {
            abandoned = true
            break
          }
          continue
        }
        while true {
          let count = buffer.withUnsafeMutableBytes { read(output, $0.baseAddress, 4096) }
          if count < 0 && errno == EINTR { continue }
          if count < 0 && errno == EAGAIN { break }
          if count <= 0 { break reading }
          if kept.count < Self.outputLimit {
            kept.append(contentsOf: buffer.prefix(min(count, Self.outputLimit - kept.count)))
            if kept.count >= Self.outputLimit { truncated = true }
          } else {
            truncated = true
          }
        }
        if child.readerExpired {
          abandoned = true
          break
        }
      }
      close(output)
      guard let self else { return }
      let text = String(decoding: kept, as: UTF8.self)
      self.queue.async {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) { self.note("hook \(rule) [\(pid)]: \(line)") }
        if truncated { self.note("hook \(rule) [\(pid)]: output cut at \(Self.outputLimit / 1024) KB") }
        if abandoned { self.note("hook \(rule) [\(pid)]: something it started kept its output open; stopped reading") }
      }
    }
  }

  struct SpawnFailure: Error {
    let reason: String
  }

  static func spawn(_ command: HookCommand, program: String, dev: UInt64, ino: UInt64) -> Result<(pid_t, Int32, Int32), SpawnFailure> {
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
      return .failure(SpawnFailure(reason: "this macOS can't start it outside Solara's privacy permissions"))
    }
    var input: [Int32] = [-1, -1]
    var output: [Int32] = [-1, -1]
    guard pipe(&input) == 0 else { return .failure(SpawnFailure(reason: String(cString: strerror(errno)))) }
    guard pipe(&output) == 0 else {
      close(input[0])
      close(input[1])
      return .failure(SpawnFailure(reason: String(cString: strerror(errno))))
    }
    for descriptor in input + output { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
    _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
      close(input[0])
      close(output[1])
    }
    posix_spawn_file_actions_adddup2(&actions, input[0], 0)
    posix_spawn_file_actions_adddup2(&actions, output[1], 1)
    posix_spawn_file_actions_adddup2(&actions, output[1], 2)
    posix_spawn_file_actions_addchdir_np(&actions, command.directory)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    var defaults = sigset_t()
    sigfillset(&defaults)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)
    let everyException = exception_mask_t(
      EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_EMULATION | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT
        | EXC_MASK_SYSCALL | EXC_MASK_MACH_SYSCALL | EXC_MASK_RPC_ALERT | EXC_MASK_RESOURCE | EXC_MASK_GUARD)
    posix_spawnattr_setexceptionports_np(&attributes, everyException, mach_port_t(MACH_PORT_NULL), exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
    guard unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1) == 0 else {
      close(input[1])
      close(output[0])
      return .failure(SpawnFailure(reason: "couldn't start it outside Solara's privacy permissions"))
    }
    var current = stat()
    guard lstat(program, &current) == 0, (current.st_mode & S_IFMT) == S_IFREG, UInt64(UInt32(bitPattern: current.st_dev)) == dev,
      UInt64(current.st_ino) == ino
    else {
      close(input[1])
      close(output[0])
      return .failure(SpawnFailure(reason: "\(program) changed just before it would have run"))
    }
    var pid: pid_t = 0
    let code = withCStrings(command.argv) { argv in
      withCStrings(command.environment) { env in
        posix_spawn(&pid, program, &actions, &attributes, argv, env)
      }
    }
    guard code == 0 else {
      close(input[1])
      close(output[0])
      return .failure(SpawnFailure(reason: String(cString: strerror(code))))
    }
    return .success((pid, input[1], output[0]))
  }

  static func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
  }

  public func clearLog() {
    guard let log else { return }
    logQueue.async {
      unlink(log.path)
      unlink(log.deletingLastPathComponent().appendingPathComponent("hooks.1.log").path)
    }
  }

  public func flushLog() {
    logQueue.sync {}
  }

  private func openLog() -> Int32 {
    guard let log else { return -1 }
    var info = stat()
    if stat(log.path, &info) == 0, info.st_size > Self.logLimit {
      let previous = log.deletingLastPathComponent().appendingPathComponent("hooks.1.log").path
      unlink(previous)
      rename(log.path, previous)
    }
    return open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
  }

  public func note(_ line: String) {
    guard log != nil else { return }
    let now = Date()
    logQueue.async {
      let output = self.openLog()
      guard output >= 0 else { return }
      defer { close(output) }
      let text = "[\(self.stamp.string(from: now))] \(HookText.clean(line))\n"
      _ = text.withCString { write(output, $0, strlen($0)) }
    }
  }
}
#endif
