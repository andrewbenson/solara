import AppKit
import Foundation
import Security
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI
import UserNotifications

public enum HooksRead: Sendable, Equatable {
  case absent
  case contents(Data)
  case unreadable(String)
}

public final class HooksConfigFolder: @unchecked Sendable {
  public typealias Observer = @Sendable (Set<String>) -> Void

  public let url: URL
  let work = DispatchQueue(label: "solara.hooks.folder", qos: .utility)
  private var observers: [Int: Observer] = [:]
  private var nextObserver = 0
  private var fingerprints: [String: [Int64]] = [:]
  private var folderSource: DispatchSourceFileSystemObject?
  private var poll: DispatchSourceTimer?
  private let names: [String]

  public init(url: URL, names: [String] = [Hooks.fileName]) {
    self.url = url.standardizedFileURL
    self.names = names
  }

  public func file(_ name: String) -> URL { url.appendingPathComponent(name, isDirectory: false) }

  public func read(_ name: String) -> HooksRead { Self.read(file(name).path) }

  public static func read(_ path: String) -> HooksRead {
    var info = stat()
    guard stat(path, &info) == 0 else { return errno == ENOENT ? .absent : .unreadable("can't be read") }
    guard (info.st_mode & S_IFMT) == S_IFREG else { return .unreadable("isn't a regular file") }
    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return errno == ENOENT ? .absent : .unreadable("can't be opened") }
    defer { close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG else { return .unreadable("isn't a regular file") }
    if let problem = Hooks.ownershipProblem(file: path) { return .unreadable(problem) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while data.count <= HooksFile.maxBytes {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, 65536) }
      if count < 0 && errno == EINTR { continue }
      if count < 0 { return .unreadable("can't be read") }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    if data.count > HooksFile.maxBytes { return .unreadable("is larger than 1 MB") }
    return .contents(data)
  }

  @discardableResult
  public func observe(_ observer: @escaping Observer) -> Int {
    work.sync {
      nextObserver += 1
      observers[nextObserver] = observer
      if folderSource == nil && poll == nil { start() }
      return nextObserver
    }
  }

  public func removeObserver(_ id: Int) {
    work.sync {
      observers[id] = nil
      if observers.isEmpty { stop() }
    }
  }

  private func start() {
    for name in names { fingerprints[name] = fingerprint(name) }
    let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
    if descriptor >= 0 {
      let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib, .link], queue: work)
      source.setEventHandler { [weak self] in self?.rescan() }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      folderSource = source
    }
    let timer = DispatchSource.makeTimerSource(queue: work)
    timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
    timer.setEventHandler { [weak self] in self?.rescan() }
    timer.resume()
    poll = timer
  }

  private func stop() {
    folderSource?.cancel()
    folderSource = nil
    poll?.cancel()
    poll = nil
  }

  private func fingerprint(_ name: String) -> [Int64] {
    var info = stat()
    var folder = stat()
    guard stat(file(name).path, &info) == 0 else { return [] }
    _ = stat(url.path, &folder)
    return [
      Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
      Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec), Int64(info.st_mode), Int64(info.st_uid), Int64(folder.st_mode),
    ]
  }

  private func rescan() {
    var changed = Set<String>()
    for name in names {
      let now = fingerprint(name)
      if fingerprints[name] != now {
        fingerprints[name] = now
        changed.insert(name)
      }
    }
    guard !changed.isEmpty else { return }
    let current = Array(observers.values)
    DispatchQueue.main.async { for observer in current { observer(changed) } }
  }
}

final class HooksRuntime: @unchecked Sendable {
  static let shared = HooksRuntime()

  struct Event: Sendable {
    let kind: String
    let rule: String
    let detail: String
  }

  let hooks: Hooks
  let runner: HookCommandRunner
  let names = ProfileNames()
  private let lock = NSLock()
  private var recent: [Event] = []
  private var downloading: Set<String> = []
  private var lastError: String?

  private init() {
    let data = (SolaraCoreHost.dataDirectory as NSString).deletingLastPathComponent
    let appData = URL(fileURLWithPath: data.isEmpty ? NSTemporaryDirectory() : data, isDirectory: true)
    let hooks = Hooks(
      approvals: HookApprovals(file: appData.appendingPathComponent("hooks-approvals.json")),
      senders: HookSenderTeams(file: appData.appendingPathComponent("hooks-senders.json")))
    hooks.registeredTeam = { identifier in HooksRuntime.installedTeam(identifier) }
    self.hooks = hooks
    runner = HookCommandRunner(log: appData.appendingPathComponent("hooks.log"))
    runner.verify = { digest in
      guard let rule = hooks.rule(digest: digest) else { return .refused("the hook is gone") }
      return hooks.approvals.checkBeforeRun(rule, home: hooks.home)
    }
  }

  static func installedTeam(_ identifier: String) -> String? {
    func trusted(_ url: URL) -> Bool {
      let folder = url.resolvingSymlinksInPath().deletingLastPathComponent().path
      return folder == "/Applications" || folder.hasPrefix("/Applications/") || folder == "/System/Applications"
        || folder.hasPrefix("/System/Applications/")
    }
    let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).filter(trusted)
    let teams = Set(copies.map(signingTeam))
    guard teams.count == 1, let team = teams.first else { return nil }
    return team
  }

  static func signingTeam(_ app: URL) -> String? {
    var found: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &found) == errSecSuccess, let code = found else { return nil }
    func satisfies(_ text: String) -> Bool {
      var requirement: SecRequirement?
      guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
      return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }
    if satisfies("anchor apple") { return HookSender.appleTeam }
    guard satisfies("anchor apple generic") else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let signing = info as? [String: Any]
    else { return nil }
    return signing[kSecCodeInfoTeamIdentifier as String] as? String
  }

  func apply(_ read: HooksRead, path: String) {
    switch read {
    case .absent:
      hooks.load(nil, path: path)
      lastError = nil
    case .unreadable(let problem):
      hooks.fail("hooks.json \(problem)", path: path)
      note("file", "", "hooks.json \(problem); every hook is off")
    case .contents(let data):
      if let error = hooks.load(data, path: path) {
        if error != lastError { note("file", "", "\(path) has an error; keeping the last rules that loaded: \(error)") }
        lastError = error
      } else {
        lastError = nil
        hooks.pruneApprovals()
        note("file", "", "loaded \(hooks.snapshot.count) rule(s) from \(path)")
      }
    }
  }

  var events: [Event] {
    lock.lock()
    defer { lock.unlock() }
    return recent
  }

  func clearEvents() {
    lock.lock()
    recent = []
    lock.unlock()
  }

  func note(_ kind: String, _ rule: String, _ detail: String) {
    runner.note("\(kind) \(rule): \(detail)")
    lock.lock()
    recent.append(Event(kind: kind, rule: rule, detail: detail))
    if recent.count > 200 { recent.removeFirst(recent.count - 200) }
    lock.unlock()
  }

  func finishedNow(_ download: [String: Any]) -> Bool {
    guard let id = download["id"] as? String else { return false }
    let state = download["state"] as? String
    lock.lock()
    defer { lock.unlock() }
    if state == "downloading" {
      downloading.insert(id)
      return false
    }
    return downloading.remove(id) != nil && state == "finished"
  }

  func fire(_ data: HookEventData) {
    for item in hooks.actions(for: data) {
      switch item.action {
      case .run:
        guard let (command, timeout) = hooks.command(for: item.rule, data: data) else { continue }
        note("run", item.rule.name, data.event.rawValue)
        runner.run(digest: item.rule.digest, rule: item.rule.name, event: data.event, command: command, timeout: timeout)
      case .sound(let name, _):
        note("sound", item.rule.name, name)
        DispatchQueue.main.async { NSSound(named: NSSound.Name(name))?.play() }
      case .notify:
        note("notify", item.rule.name, data.event.rawValue)
        if !SolaraCoreHost.testBuild { Self.post(item.rule.name, data) }
      default:
        continue
      }
    }
  }

  static func post(_ rule: String, _ data: HookEventData) {
    let content = UNMutableNotificationContent()
    switch data.event {
    case .downloadFinished:
      content.title = "Download finished"
      content.body = data.file.map { ($0 as NSString).lastPathComponent } ?? ""
    case .pageLoaded:
      content.title = HookText.clean(data.title ?? "Page loaded")
      content.body = data.url.flatMap { HookURL($0)?.host } ?? ""
    case .linkOpened:
      content.title = "Link opened"
      content.body = data.url.flatMap { HookURL($0)?.host } ?? ""
    }
    content.subtitle = HookText.clean(rule)
    let request = UNNotificationRequest(identifier: "solara-hook-" + UUID().uuidString, content: content, trigger: nil)
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert]) { granted, _ in
      if granted { center.add(request) }
    }
  }
}

@MainActor
public final class NativeHooks: HooksServices {
  public static let shared = NativeHooks()

  let runtime = HooksRuntime.shared
  var hooks: Hooks { runtime.hooks }
  private var folder: HooksConfigFolder?
  private var started = false
  private var model: HooksSectionModel?
  private var storeSubscription: Int?
  private var lifecycle: Int?
  private var historyObserver: NSObjectProtocol?
  private var engineConfigured = false
  private var observing = false
  var lateLoads = 0

  private init() {}

  public static func start() {
    guard !SolaraCoreHost.safeMode else { return }
    guard let directory = Hooks.configDirectory() else { return }
    shared.begin(folder: HooksConfigFolder(url: directory))
  }

  func begin(folder: HooksConfigFolder) {
    guard !started else { return }
    started = true
    self.folder = folder
    OpenURLInbox.hookPending = true
    let runtime = runtime
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard OpenURLInbox.hookPending else { return }
      runtime.note("file", "", "hooks.json wasn't read within 3 s; links from other apps open without hooks until it is")
      OpenURLInbox.hooksReady(nil)
    }
    historyObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraHistoryCleared"), object: nil, queue: nil) { _ in
      runtime.clearEvents()
      runtime.runner.clearLog()
    }
    folder.observe { _ in MainActor.assumeIsolated { NativeHooks.shared.reload() } }
    reload()
  }

  func reload() {
    guard let folder else { return }
    let path = folder.file(Hooks.fileName).path
    let runtime = runtime
    folder.work.async {
      runtime.apply(folder.read(Hooks.fileName), path: path)
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeHooks.shared.fileChanged() } }
    }
  }

  private func fileChanged() {
    install()
    changed()
  }

  func changed() {
    model?.refresh()
    NotificationCenter.default.post(name: HooksSectionModel.changed, object: nil)
  }

  private func configureEngine() {
    let names = runtime.names
    let rules = hooks.engineConfiguration { display in names.engineDirectories(display: display) }
    let payload: [String: Any] = ["version": 1, "rules": rules]
    guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
    guard let reply = SolaraCoreEngineBridge.configureHooks(json) else {
      engineConfigured = false
      hooks.engineMatch = nil
      return
    }
    engineConfigured = reply["ok"] as? Bool == true
    lateLoads = (reply["late"] as? NSNumber)?.intValue ?? lateLoads
    var problems: [String: String] = [:]
    for rule in hooks.snapshot {
      guard let wanted = rule.match.profiles, !wanted.isEmpty, wanted.allSatisfy({ names.engineDirectories(display: $0).isEmpty }) else { continue }
      if names.loaded { problems[rule.digest] = "no profile named " + wanted.joined(separator: " or ") }
    }
    for entry in reply["problems"] as? [[String: Any]] ?? [] {
      if let id = entry["id"] as? String, let problem = entry["problem"] as? String { problems[id] = problem }
    }
    hooks.setEngineProblems(problems)
    for (id, problem) in problems { runtime.note("engine", hooks.rule(digest: id)?.name ?? id, problem) }
    if engineConfigured {
      hooks.engineMatch = { @Sendable (url: String) -> (matched: Set<String>, failed: Set<String>)? in
        guard let reply = SolaraCoreEngineBridge.matchHooks(url), !reply.keys.contains("error") else { return nil }
        let matched = Set(reply["matched"] as? [String] ?? [])
        let failed = Set(reply["failed"] as? [String] ?? [])
        return (matched: matched, failed: failed)
      }
    } else {
      hooks.engineMatch = nil
    }
    observeEngine()
  }

  private func observeEngine() {
    guard !observing else { return }
    observing = true
    let runtime = runtime
    SolaraCoreEngineBridge.observe("hooks.navigation") { payload in
      let rule = payload["rule"] as? String ?? ""
      let action = payload["action"] as? String ?? ""
      if let url = payload["url"] as? String {
        let target = payload["target"] as? String
        runtime.note(action, rule, target.map { "\(url) → \($0)" } ?? url)
      } else {
        runtime.note(action, rule, "a private window's page")
      }
    }
    SolaraCoreEngineBridge.observe("hooks.download_refused") { payload in
      runtime.note("fileInto", payload["rule"] as? String ?? "", "the folder changed since it was checked; the download stays in the default folder")
    }
  }

  private func install() {
    let runtime = runtime
    let hooks = runtime.hooks
    let names = runtime.names
    let wantsProfiles = hooks.snapshot.contains { $0.match.profiles != nil } || hooks.snapshot.contains { if case .openIn = $0.action { true } else { false } }
    if wantsProfiles { watchProfiles() }
    configureEngine()

    OpenURLInbox.hooksReady(hooks.wantsLinks ? { urls, app in
      MainActor.assumeIsolated { NativeHooks.links(urls, app: app, runtime: runtime) }
    } : nil)

    SolaraCoreHost.permissionHook = hooks.wantsPermissions ? { request, directory, offTheRecord in
      if offTheRecord { return false }
      let origins = [request["origin"] as? String ?? "", request["embeddingURL"] as? String ?? ""]
      let kinds = request["permissions"] as? [String] ?? []
      let profile = names.display(directory: directory)
      guard let rule = hooks.deniedPermissions(origins: origins, kinds: kinds, profile: profile) else { return false }
      runtime.note("deny", rule, "\(origins[0]) \(kinds.joined(separator: ","))")
      return true
    } : nil

    SolaraCoreServices.downloadObserver = hooks.wantsDownloads ? { download, profile in
      guard runtime.finishedNow(download), (download["offTheRecord"] as? Bool) != true, (download["dangerous"] as? Bool) != true,
        let url = download["url"] as? String, url.hasPrefix("https://") || url.hasPrefix("http://"),
        let path = download["path"] as? String, path.hasPrefix("/")
      else { return }
      let data = HookEventData(
        event: .downloadFinished, url: url, profile: names.display(engine: profile), file: path, mime: download["mimeType"] as? String)
      runtime.fire(data)
    } : nil

    SolaraCoreWebView.setPageLoadHook(hooks.wantsPageLoads ? { page in
      guard (page["offTheRecord"] as? Bool) != true, let url = page["url"] as? String else { return }
      let profile = names.display(engine: page["profile"] as? String ?? "")
      runtime.fire(HookEventData(event: .pageLoaded, url: url, profile: profile, title: page["title"] as? String))
    } : nil)
  }

  private func watchProfiles() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.storeSubscription == nil, let store = NativeStoreHandle.store else { return }
        let names = self.runtime.names
        self.storeSubscription = store.subscribe { [weak self] commit in
          if names.update(commit.state) { DispatchQueue.main.async { MainActor.assumeIsolated { self?.configureEngine() } } }
        }
        if names.update(store.state) { self.configureEngine() }
      }
    }
  }

  static func links(_ urls: [String], app signed: String?, runtime: HooksRuntime) -> [OpenURLBatch] {
    let hooks = runtime.hooks
    let names = runtime.names
    let sender = hooks.sender(signed)
    let app = sender?.identifier
    var batches: [OpenURLBatch] = []
    for url in urls {
      var engine: String?
      var display: String?
      if let route = hooks.routeLink(url, app: sender) {
        if let found = names.engine(display: route.profile) {
          engine = found
          display = route.profile
          runtime.note("openIn", route.rule, "a link from \(app ?? "another app") → \(route.profile)")
        } else {
          runtime.note("openIn", route.rule, "no profile named \(route.profile)")
        }
      }
      if let rule = hooks.blocksLink(url, app: sender, profile: display) {
        runtime.note("block", rule, "dropped a link from \(app ?? "another app")")
        continue
      }
      if let index = batches.firstIndex(where: { $0.profile == engine }) { batches[index].urls.append(url) } else {
        batches.append(OpenURLBatch(urls: [url], profile: engine))
      }
      runtime.fire(HookEventData(event: .linkOpened, url: url, profile: display, sender: sender))
    }
    return batches
  }

  func sectionModel() -> HooksSectionModel {
    if let model { return model }
    let made = HooksSectionModel(services: self)
    model = made
    return made
  }

  public var hooksStatus: HooksStatus {
    var status = hooks.status(dropped: runtime.runner.dropCounts, engine: engineConfigured)
    status.lateLoads = lateLoads
    if status.path.isEmpty { status.path = (folder?.url ?? Hooks.configDirectory() ?? URL(fileURLWithPath: "/")).appendingPathComponent(Hooks.fileName).path }
    return status
  }

  public func approvalSnapshot(_ digest: String) -> String? {
    guard let rule = hooks.rule(digest: digest), rule.needsApproval else { return nil }
    return HookApprovals.snapshot(rule, home: hooks.home)
  }

  public func approveHook(_ digest: String, snapshotHash: String) -> String? {
    guard let rule = hooks.rule(digest: digest), rule.needsApproval else { return "This hook changed; look at it again." }
    switch hooks.approvals.approve(rule, snapshotHash: snapshotHash, home: hooks.home) {
    case .failure(.stale):
      return "This hook or a file it uses changed while you were looking at it; nothing was approved."
    case .failure(.refused(let why)):
      runtime.note("approve", rule.name, "refused: \(why)")
      return "Can't approve “\(HookText.escaped(rule.name))”: \(why)"
    case .success:
      runtime.note("approve", rule.name, rule.digest)
      install()
      changed()
      return nil
    }
  }

  public func revokeHook(_ digest: String) {
    hooks.approvals.revoke(digest)
    runtime.note("revoke", hooks.rule(digest: digest)?.name ?? "", digest)
    install()
    changed()
  }

  public func forgetAppTeam(_ identifier: String) {
    hooks.forgetAppTeam(identifier)
    runtime.note("forget", "", "the recorded signer of \(identifier)")
    changed()
  }

  public func revealHooksFile() {
    guard let directory = folder?.url ?? Hooks.configDirectory() else { return }
    let file = directory.appendingPathComponent(Hooks.fileName)
    if FileManager.default.fileExists(atPath: file.path) {
      NSWorkspace.shared.activateFileViewerSelecting([file])
    } else {
      try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      NSWorkspace.shared.open(file.deletingLastPathComponent())
    }
  }

  #if DEBUG
  func dev(_ action: String, _ argument: String?) -> [String: Any] {
    switch action {
    case "approve", "revoke":
      guard let rule = hooks.snapshot.first(where: { $0.name == argument }) else { return ["error": "no hook named \(argument ?? "")"] }
      if action == "approve" {
        guard let snapshot = approvalSnapshot(rule.digest) else { return ["error": "\(rule.name) needs no approval"] }
        if let refusal = approveHook(rule.digest, snapshotHash: HookApprovals.snapshotHash(snapshot)) { return ["error": refusal] }
      } else {
        revokeHook(rule.digest)
      }
    case "openURLs":
      guard let data = argument?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let urls = object["urls"] as? [String]
      else { return ["error": "argument is {\"urls\": [...], \"app\": \"bundle.id@TEAMID\"}"] }
      OpenURLInbox.receive(urls.compactMap(URL.init(string:)), sourceApp: object["app"] as? String)
    case "clearEvents":
      runtime.clearEvents()
    case "forgetTeam":
      forgetAppTeam(argument ?? "")
    default:
      break
    }
    let status = hooksStatus
    return [
      "path": status.path, "present": status.present, "error": status.error ?? NSNull(), "engine": status.engine,
      "rules": status.rules.map {
        [
          "name": $0.name, "kind": $0.kind, "needsApproval": $0.needsApproval, "approved": $0.approved, "problem": $0.problem ?? NSNull(),
          "state": HooksSectionModel.stateText($0), "summary": $0.summary, "dropped": $0.dropped,
        ]
      },
      "lateLoads": status.lateLoads,
      "appProblems": status.appProblems,
      "appTeams": status.appTeams.map { ["app": $0.identifier, "team": $0.team] },
      "events": runtime.events.map { ["kind": $0.kind, "rule": $0.rule, "detail": $0.detail] },
    ]
  }
  #endif
}

final class ProfileNames: @unchecked Sendable {
  private let lock = NSLock()
  private var byEngine: [String: String] = [:]
  private(set) var loaded = false

  @discardableResult
  func update(_ state: BrowserState) -> Bool {
    var next: [String: String] = [:]
    for (id, profile) in state.profiles where !Ids.isIncognitoProfile(id) { next[state.engineProfile(id)] = profile.name }
    lock.lock()
    defer { lock.unlock() }
    let first = !loaded
    loaded = true
    guard next != byEngine || first else { return false }
    byEngine = next
    return true
  }

  func display(engine: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return byEngine[engine]
  }

  func display(directory: String) -> String? {
    let engine = directory == "Default" ? "" : directory.hasPrefix("Profile ") ? String(directory.dropFirst(8)) : directory
    return display(engine: engine)
  }

  func engine(display name: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    let wanted = name.lowercased()
    return byEngine.first { $0.value.lowercased() == wanted }?.key
  }

  func engineDirectories(display name: String) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let wanted = name.lowercased()
    return byEngine.filter { $0.value.lowercased() == wanted }.map { $0.key.isEmpty ? "Default" : "Profile " + $0.key }
  }
}
