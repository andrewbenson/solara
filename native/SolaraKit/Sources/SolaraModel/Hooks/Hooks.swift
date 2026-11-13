import Foundation

public struct HookRuleStatus: Sendable, Equatable, Identifiable {
  public var id: String { digest }
  public let name: String
  public let digest: String
  public let kind: String
  public let summary: String
  public let detail: String
  public let needsApproval: Bool
  public let approval: HookApprovalState
  public var problem: String?
  public var dropped: Int
  public let argv: [String]?
  public let flags: [String]
  public var text = ""

  public var approved: Bool { approval == .approved }
}

public struct HooksStatus: Sendable, Equatable {
  public var path: String
  public var present: Bool
  public var error: String?
  public var rules: [HookRuleStatus]
  public var engine: Bool
  public var lateLoads = 0
  public var appProblems: [String] = []
  public var appTeams: [HookAppTeam] = []

  public static let none = HooksStatus(path: "", present: false, error: nil, rules: [], engine: false)
}

public struct HookEventAction: Sendable {
  public let rule: HookRule
  public let action: HookAction
}

public final class Hooks: @unchecked Sendable {
  public static let fileName = "hooks.json"

  public let approvals: HookApprovals
  public let senders: HookSenderTeams
  public let home: String
  private let lock = NSLock()
  private var rules: [HookRule] = []
  private var error: String?
  private var present = false
  private var path = ""
  private var engineProblems: [String: String] = [:]
  public var engineMatch: (@Sendable (String) -> (matched: Set<String>, failed: Set<String>)?)?

  public init(approvals: HookApprovals, senders: HookSenderTeams = HookSenderTeams(file: nil), home: String = HookFolder.userHome) {
    self.approvals = approvals
    self.senders = senders
    self.home = home
  }

  public var registeredTeam: (@Sendable (String) -> String?)?

  public func sender(_ signed: String?) -> HookSender? {
    let rules = snapshot
    let registered = registeredTeam
    return senders.check(
      signed, registered: { registered?($0) },
      wanted: { identifier in rules.contains { $0.match.team == nil && $0.match.apps?.contains(identifier) == true } })
  }

  public func forgetAppTeam(_ identifier: String) {
    senders.forget(identifier)
  }

  public static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = HookFolder.userHome) -> URL? {
    if let dir = environment["SOLARA_CONFIG_DIR"], !dir.isEmpty {
      let path = dir.hasPrefix("/") ? dir : FileManager.default.currentDirectoryPath + "/" + dir
      return URL(fileURLWithPath: (path as NSString).standardizingPath, isDirectory: true)
    }
    if environment["SOLARA_DATA_DIR"]?.isEmpty == false || environment["SOLARA_BACKGROUND"] == "1" { return nil }
    return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config/solara", isDirectory: true)
  }

  public static func ownershipProblem(file: String) -> String? {
    var info = stat()
    guard stat(file, &info) == 0 else { return nil }
    if info.st_uid != getuid() { return "hooks.json isn't owned by you; it's ignored" }
    if info.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "hooks.json can be changed by other users (group or world writable); it's ignored until you run chmod go-w on it" }
    guard let real = realpath(file, nil) else { return "hooks.json can't be resolved" }
    defer { free(real) }
    let folder = (String(cString: real) as NSString).deletingLastPathComponent
    var folderInfo = stat()
    guard stat(folder, &folderInfo) == 0 else { return "hooks.json's folder can't be read" }
    if folderInfo.st_uid != getuid() { return "\(folder) isn't owned by you; hooks.json is ignored" }
    if folderInfo.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "\(folder) can be changed by other users; hooks.json is ignored until you run chmod go-w on it" }
    return nil
  }

  @discardableResult
  public func load(_ data: Data?, path: String) -> String? {
    guard let data else {
      lock.lock()
      rules = []
      error = nil
      present = false
      self.path = path
      engineProblems = [:]
      lock.unlock()
      return nil
    }
    do {
      let parsed = try HooksFile.parse(data)
      lock.lock()
      rules = parsed
      error = nil
      present = true
      self.path = path
      engineProblems = [:]
      lock.unlock()
      return nil
    } catch {
      lock.lock()
      self.error = error.description
      present = true
      self.path = path
      lock.unlock()
      return error.description
    }
  }

  public func fail(_ message: String, path: String) {
    lock.lock()
    error = message
    present = true
    self.path = path
    rules = []
    engineProblems = [:]
    lock.unlock()
  }

  public func setEngineProblems(_ problems: [String: String]) {
    lock.lock()
    engineProblems = problems
    lock.unlock()
  }

  public var snapshot: [HookRule] {
    lock.lock()
    defer { lock.unlock() }
    return rules
  }

  public var active: Bool { !snapshot.isEmpty }

  public var wantsLinks: Bool {
    snapshot.contains { rule in
      switch rule.action {
      case .block, .openIn: true
      default: rule.action.events.contains(.linkOpened)
      }
    }
  }

  public var wantsDownloads: Bool { snapshot.contains { $0.action.events.contains(.downloadFinished) } }
  public var wantsPermissions: Bool { snapshot.contains { if case .deny = $0.action { true } else { false } } }
  public var wantsPageLoads: Bool { snapshot.contains { $0.action.events.contains(.pageLoaded) } }

  public func usable(_ rule: HookRule) -> Bool { approvals.usable(rule, home: home) && Self.ruleProblem(rule, home: home) == nil }

  public func outcomes(_ text: String) -> (HookRule) -> HookURLOutcome {
    let engine = engineMatch?(text)
    let url = HookURL(text)
    return { rule in
      if !rule.match.hasURLCondition { return .matched([]) }
      if let engine {
        if engine.failed.contains(rule.digest) { return .failed }
        return engine.matched.contains(rule.digest) ? .matched([]) : .missed
      }
      return rule.match.outcome(url)
    }
  }

  public func blocksLink(_ text: String, app: HookSender?, profile: String?) -> String? {
    let outcome = outcomes(text)
    for rule in snapshot {
      guard case .block = rule.action, rule.match.matchesApp(app), rule.match.matchesProfile(profile) else { continue }
      switch outcome(rule) {
      case .matched, .failed: return rule.name
      case .missed: continue
      }
    }
    return nil
  }

  public func routeLink(_ text: String, app: HookSender?) -> (profile: String, rule: String)? {
    let outcome = outcomes(text)
    for rule in snapshot {
      guard case .openIn(let profile) = rule.action, rule.match.matchesApp(app), usable(rule) else { continue }
      guard outcome(rule).matched else { continue }
      return (profile, rule.name)
    }
    return nil
  }

  public func deniedPermissions(origins: [String], kinds: [String], profile: String?) -> String? {
    let asked = Set(kinds.map { $0 == "cameraPanTiltZoom" ? "camera" : $0 })
    let checks = origins.filter { !$0.isEmpty }.map { outcomes($0) }
    for rule in snapshot {
      guard case .deny(let denied) = rule.action, rule.match.matchesProfile(profile), usable(rule) else { continue }
      guard denied.contains(where: { asked.contains($0.rawValue) }) else { continue }
      for outcome in checks {
        switch outcome(rule) {
        case .matched, .failed: return rule.name
        case .missed: continue
        }
      }
    }
    return nil
  }

  public func actions(for data: HookEventData) -> [HookEventAction] {
    let outcome = data.url.map { outcomes($0) }
    var result: [HookEventAction] = []
    for rule in snapshot {
      guard rule.action.events.contains(data.event) else { continue }
      guard rule.match.matchesProfile(data.profile), rule.match.matchesApp(data.sender), usable(rule) else { continue }
      if rule.match.hasURLCondition {
        guard let outcome, outcome(rule).matched else { continue }
      }
      result.append(HookEventAction(rule: rule, action: rule.action))
    }
    return result
  }

  public func command(for rule: HookRule, data: HookEventData) -> (HookCommand, TimeInterval)? {
    guard case .run(let argv, _, let timeout) = rule.action else { return nil }
    return (HookCommand(rule: rule.name, argv: argv, data: data, home: home), timeout)
  }

  public func engineConfiguration(profileDirectories: (String) -> [String]) -> [[String: Any]] {
    snapshot.map { rule in
      var entry: [String: Any] = ["id": rule.digest, "name": rule.name, "action": "none"]
      if !rule.match.hosts.isEmpty { entry["hosts"] = rule.match.hosts.map(\.pattern) }
      if !rule.match.urls.isEmpty { entry["urls"] = rule.match.urls.map(\.pattern) }
      if let regex = rule.match.regex { entry["regex"] = regex.source }
      if let profiles = rule.match.profiles { entry["profiles"] = profiles.flatMap(profileDirectories) }
      switch rule.action {
      case .block where rule.match.apps == nil:
        entry["action"] = "block"
      case .rewrite(let template) where rule.match.apps == nil && usable(rule):
        entry["action"] = "rewrite"
        entry["template"] = template.text
      case .stripParams(let names) where rule.match.apps == nil:
        entry["action"] = "stripParams"
        entry["params"] = names
      case .https where rule.match.apps == nil:
        entry["action"] = "https"
      case .fileInto(let text) where usable(rule):
        let record = approvals.record(rule.digest)
        if let folder = HookFolder(text, home: home), let spec = folder.spec(approved: record?.folderIdentity) {
          entry["action"] = "fileInto"
          entry["root"] = spec.root
          entry["rootDev"] = String(spec.identity.dev)
          entry["rootIno"] = String(spec.identity.ino)
          entry["below"] = spec.below
        }
      default:
        break
      }
      return entry
    }
  }

  public func status(dropped: [String: Int] = [:], engine: Bool = false) -> HooksStatus {
    lock.lock()
    let rules = self.rules
    let error = self.error
    let present = self.present
    let path = self.path
    let problems = engineProblems
    lock.unlock()
    var status = HooksStatus(path: path, present: present, error: error, rules: rules.map { rule in
      var argv: [String]?
      if case .run(let given, _, _) = rule.action { argv = given }
      return HookRuleStatus(
        name: rule.name, digest: rule.digest, kind: rule.action.kind, summary: Self.summary(rule, home: home), detail: Self.detail(rule),
        needsApproval: rule.needsApproval, approval: approvals.state(rule, home: home), problem: problems[rule.digest] ?? Self.ruleProblem(rule, home: home),
        dropped: dropped[rule.digest] ?? 0, argv: argv, flags: Self.flags(rule, home: home), text: rule.text)
    }, engine: engine)
    status.appProblems = senders.problems
    let named = Set(rules.flatMap { $0.match.apps ?? [] })
    status.appTeams = senders.recorded.filter { named.contains($0.identifier) }
    return status
  }

  public func rule(digest: String) -> HookRule? { snapshot.first { $0.digest == digest } }

  public func pruneApprovals() {
    lock.lock()
    let hasError = error != nil
    let digests = Set(rules.map(\.digest))
    let names = Set(rules.map { $0.name.lowercased() })
    lock.unlock()
    if !hasError { approvals.keepOnly(digests, names: names) }
  }

  public static func ruleProblem(_ rule: HookRule, home: String) -> String? {
    guard case .run(let argv, _, _) = rule.action, let folder = HookFingerprint.folderArgument(argv, home: home) else { return nil }
    return "\(folder) is a folder, and \((argv[0] as NSString).lastPathComponent) would run whatever is in it; this hook is off until it names a file"
  }

  public static func flags(_ rule: HookRule, home: String) -> [String] {
    guard case .run(let argv, _, _) = rule.action else { return [] }
    var flags: [String] = []
    let program = HookFingerprint.program(argv, home: home)
    if HookFingerprint.isInterpreter(program) {
      flags.append("\((program as NSString).lastPathComponent) runs whatever its arguments say: read them all")
      if argv.dropFirst().contains(where: { $0.contains("SOLARA_") }) {
        flags.append("The arguments use SOLARA_ values, which come from web pages: a page can choose them")
      }
    }
    if HookFingerprint.userWritableFolder(program) { flags.append("The program is in a folder you can write to, so other programs you run can change it") }
    if let problem = HookFingerprint.writableProblem(program) { flags.append("Can't be approved: \(problem)") }
    if argv.contains(where: { $0.unicodeScalars.contains(where: HookText.unsafe) }) {
      flags.append("An argument contains invisible or direction-changing characters (shown escaped)")
    }
    return flags
  }

  public static func summary(_ rule: HookRule, home: String) -> String {
    switch rule.action {
    case .block: return rule.match.apps == nil ? "Blocks matching pages and links" : "Drops matching links from these apps"
    case .rewrite(let template): return "Opens matching pages at " + HookText.escaped(template.text)
    case .stripParams(let names): return "Removes the query parameters " + names.joined(separator: ", ")
    case .https: return "Opens matching http pages over https"
    case .openIn(let profile): return "Opens links from other apps in the \(HookText.escaped(profile)) profile"
    case .fileInto(let folder):
      let inside = HookFolder(folder, home: home)?.insideDownloads ?? false
      return "Saves matching downloads in \(HookText.escaped(folder))" + (inside ? "" : " (outside Downloads)")
    case .deny(let kinds): return "Denies " + kinds.map(\.rawValue).joined(separator: " and ") + " without asking"
    case .notify(let events): return "Shows a notification on " + events.map(\.rawValue).joined(separator: ", ")
    case .sound(let name, let events): return "Plays \(name) on " + events.map(\.rawValue).joined(separator: ", ")
    case .run(let argv, let events, let timeout):
      return "Runs " + argv.map(quoted).joined(separator: " ") + " on " + events.map(\.rawValue).joined(separator: ", ") + " (stopped after \(Int(timeout)) s)"
    }
  }

  public static func detail(_ rule: HookRule) -> String {
    var parts: [String] = []
    if !rule.match.urls.isEmpty { parts.append("URLs " + rule.match.urls.map(\.pattern).joined(separator: ", ")) }
    if !rule.match.hosts.isEmpty { parts.append("hosts " + rule.match.hosts.map(\.pattern).joined(separator: ", ")) }
    if let regex = rule.match.regex { parts.append("regex " + HookText.escaped(regex.source)) }
    if let apps = rule.match.apps { parts.append("from " + apps.joined(separator: ", ")) }
    if let profiles = rule.match.profiles { parts.append("profiles " + profiles.map(HookText.escaped).joined(separator: ", ")) }
    return parts.isEmpty ? "Everything" : parts.joined(separator: "; ")
  }

  public static func quoted(_ text: String) -> String {
    let shown = HookText.escaped(text)
    return shown.isEmpty || shown.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) ? "\"" + shown.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : shown
  }
}
