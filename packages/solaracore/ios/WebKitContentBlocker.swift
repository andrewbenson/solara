import CryptoKit
import Darwin
import Foundation
import WebKit

final class WebKitContentBlocker: NSObject, WKNavigationDelegate {
  static let firstLaunchWait: TimeInterval = 2
  static let lookupWait: TimeInterval = 10
  nonisolated static let directiveMatchLength = 2048
  nonisolated static let directiveMatchBudget: TimeInterval = 0.05
  static let settingsWait: TimeInterval = 2
  static let settingsReadTimeout: TimeInterval = 25
  static let settingsRetryWindow: TimeInterval = 120
  static let failureBackoff: TimeInterval = 30
  nonisolated static let maximumRules = 140_000
  static let appliedNotification = Notification.Name("SolaraWebKitContentBlockerApplied")
  static let coldCompileNotification = Notification.Name("SolaraWebKitContentBlockerColdCompile")

  struct Asset: Decodable {
    let file: String
    let sha256: String
  }

  struct Chunk: Decodable {
    let file: String
    let sha256: String
    let priority: Int
    let kind: String
    var rules: Int?
    var bytes: Int?
  }

  typealias Source = @Sendable () throws -> String

  struct Decision {
    let priority: Int
    let action: String
    let trigger: [String: Any]
  }

  struct Group: Decodable {
    let id: String
    let uboIds: [String]
    let defaultEnabled: Bool
    let chunks: [Chunk]
    let scriptlets: [Asset]
    let decisions: Asset
  }

  struct Manifest: Decodable {
    let schema: Int
    let version: String
    var encoding: String?
    let lists: [Group]

    func selected(_ settings: Settings) -> [Group] {
      guard settings.enabled else { return [] }
      return lists.filter { group in group.uboIds.first.map { settings.enabledLists.contains($0) } ?? false }
    }
  }

  struct Directive: @unchecked Sendable {
    let text: String
    let key: String
    let pattern: NSRegularExpression?

    func matches(_ url: String, host: String) -> Bool {
      if key != "//" {
        guard host == key || host.hasSuffix("." + key) else { return false }
        guard let pattern else { return url == text }
        return WebKitContentBlocker.boundedMatch(pattern, url)
      }
      guard let pattern else { return false }
      return WebKitContentBlocker.boundedMatch(pattern, url)
    }
  }

  struct Settings: Equatable {
    let enabled: Bool
    let enabledLists: Set<String>
    let trustedHosts: [String]
    var trustedDirectives: [String] = []
    var directives: [Directive] = []

    static func == (a: Settings, b: Settings) -> Bool {
      a.enabled == b.enabled && a.enabledLists == b.enabledLists && a.trustedHosts == b.trustedHosts && a.trustedDirectives == b.trustedDirectives
    }

    init(_ value: [String: Any]) throws {
      guard let stats = value["stats"] as? [String: Any], stats["ready"] as? Bool == true,
        let enabled = value["enabled"] as? Bool
      else { throw Failure("The content blocker settings are not ready.") }
      self.enabled = enabled
      if !enabled {
        enabledLists = []
        trustedHosts = []
        return
      }
      guard let lists = value["lists"] as? [[String: Any]], let hosts = value["allowedHosts"] as? [String] else {
        throw Failure("The content blocker list or trusted-site settings are invalid.")
      }
      var selected = Set<String>()
      var ids = Set<String>()
      for list in lists {
        guard let id = list["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
          let on = list["enabled"] as? Bool
        else { throw Failure("The content blocker list settings are invalid.") }
        if on { selected.insert(id) }
      }
      enabledLists = selected
      trustedHosts = WebKitContentBlocker.canonicalHosts(hosts)
      directives = Set(((value["trustedDirectives"] as? [Any]) ?? []).compactMap { $0 as? String }).sorted().compactMap { WebKitContentBlocker.directive($0) }
      trustedDirectives = directives.map(\.text)
    }
  }

  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
  }

  private final class Controller {
    weak var value: WKUserContentController?
    var lists: [WKContentRuleList] = []
    var scripts: [WKUserScript] = []
    var exempt = false
    init(_ value: WKUserContentController) { self.value = value }
  }

  private final class WeakView {
    weak var value: WKWebView?
    init(_ value: WKWebView) { self.value = value }
  }

  private struct Revision {
    let settings: Settings?
    let lists: [WKContentRuleList]
    let scripts: [WKUserScript]
    let generation: Int
    var groups: [String] = []
    var unsupportedLists: [String] = []
    var sourceBytes: Int = 0
    var identifiers: [String] = []
    var scriptSources: [String] = []
  }

  struct Built: @unchecked Sendable {
    let inputs: [(String, Source)]
    let sourceBytes: Int
    let scriptSources: [String]
    let groups: [String]
    let unsupported: [String]
  }

  private struct Pending {
    let controller: WKUserContentController
    let queued: TimeInterval
    let firstLaunch: Bool
    let finish: (Error?) -> Void
  }

  typealias StateReader = (@escaping ([String: Any]) -> Void) -> Void
  typealias CompilationCompletion = (Result<WKContentRuleList, Error>) -> Void
  typealias Compiler = @MainActor (String, @escaping Source, @escaping CompilationCompletion) -> Void
  #if DEBUG
  private static var compilationMetrics: [[String: Any]] = []
  private var waitMetrics: [[String: Any]] = []
  #endif
  private static var pendingCompilations: [String: [CompilationCompletion]] = [:]

  private let resourceRoot: URL?
  private let readState: StateReader
  private let compile: Compiler
  private let safeMode: () -> Bool
  private let removeStale: @MainActor (Set<String>) -> Void
  private let firstLaunchWait: TimeInterval
  private let lookupWait: TimeInterval
  private var compileObserver: NSObjectProtocol?
  private var coldCompiling = false
  private let retryDelay: TimeInterval
  private let failureBackoff: TimeInterval
  private var observer: NSObjectProtocol?
  private var controllers: [ObjectIdentifier: Controller] = [:]
  private var views: [ObjectIdentifier: WeakView] = [:]
  private var pending: [UUID: Pending] = [:]
  private var generation = 0
  private var started = false
  private var preparing = false
  private var revision: Revision?
  private var failure: Error?
  private var preparationStarted = ProcessInfo.processInfo.systemUptime
  private var preparationMs = 0.0
  private var waitedOut = false
  private var reading = false
  private var failedAt = -TimeInterval.infinity

  init(resourceRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("WebKitBlocker", isDirectory: true),
       safeMode: @escaping () -> Bool = { SolaraCoreHost.safeMode },
       readState: @escaping StateReader = { SolaraCoreContentBlocker.state($0) },
       compile: @escaping Compiler = WebKitContentBlocker.compileCached,
       removeStale: @escaping @MainActor (Set<String>) -> Void = WebKitContentBlocker.removeStaleRuleLists,
       firstLaunchWait: TimeInterval = WebKitContentBlocker.firstLaunchWait,
       lookupWait: TimeInterval = WebKitContentBlocker.lookupWait,
       retryDelay: TimeInterval = 1,
       failureBackoff: TimeInterval = WebKitContentBlocker.failureBackoff,
       observeChanges: Bool = true) {
    self.retryDelay = retryDelay
    self.failureBackoff = failureBackoff
    self.resourceRoot = resourceRoot
    self.removeStale = removeStale
    self.firstLaunchWait = firstLaunchWait
    self.lookupWait = lookupWait
    self.safeMode = safeMode
    self.readState = readState
    self.compile = compile
    super.init()
    compileObserver = NotificationCenter.default.addObserver(forName: Self.coldCompileNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.coldCompileStarted() }
    }
    if observeChanges {
      observer = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraCoreContentBlockerChanged"), object: nil, queue: .main) { [weak self] _ in
        guard let self, self.started else { return }
        self.refresh()
      }
    }
  }

  isolated deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    if let compileObserver { NotificationCenter.default.removeObserver(compileObserver) }
  }

  func status(host: String) -> [String: Any] {
    let settings = revision?.settings
    let allowed = URL(string: "https://\(host)/").map { Self.trusts(settings, url: $0) } ?? false
    var status: [String: Any] = [
      "enabled": settings?.enabled ?? false,
      "allowed": allowed,
      "ready": revision != nil && !preparing,
      "preparing": preparing,
      "error": failure.map { $0.localizedDescription as Any } ?? NSNull(),
      "appliedGroups": revision?.groups ?? [],
      "unsupportedLists": revision?.unsupportedLists ?? [],
    ]
    #if DEBUG
    status["generation"] = generation
    status["ruleListCount"] = revision?.lists.count ?? 0
    status["sourceBytes"] = revision?.sourceBytes ?? 0
    status["preparationMs"] = preparationMs
    status["compilations"] = Self.compilationMetrics
    status["waits"] = waitMetrics
    #endif
    return status
  }

  func bind(_ view: WKWebView) {
    views = views.filter { $0.value.value != nil }
    views[ObjectIdentifier(view)] = WeakView(view)
    register(view.configuration.userContentController)
    if let revision { cleanScriptlets(in: view, before: revision.generation) }
  }

  private func cleanScriptlets(in view: WKWebView, before generation: Int) {
    view.evaluateJavaScript(Self.cleanupScript(before: generation), in: nil, in: .page) { _ in }
  }

  static func cleanupScript(before generation: Int) -> String {
    """
      (() => {
        const key = Symbol.for("solara.ubol.cleanup");
        const keep = [];
        for (const entry of globalThis[key] || []) {
          if ((Number(entry.version) || 0) >= \(generation)) { keep.push(entry); continue; }
          try { entry.stop(); } catch (_) {}
        }
        globalThis[key] = keep;
      })();
      """
  }

  func register(_ controller: WKUserContentController) {
    controllers = controllers.filter { $0.value.value != nil }
    let key = ObjectIdentifier(controller)
    if controllers[key] == nil {
      let record = Controller(controller)
      controllers[key] = record
      if let revision { install(revision, on: record) }
    }
    start()
  }

  func start() {
    if !started { refresh() }
  }

  func prepare(_ controller: WKUserContentController, url: URL? = nil, completion: @escaping (Error?) -> Void) {
    register(controller)
    if !preparing && failure != nil && ProcessInfo.processInfo.systemUptime - failedAt >= failureBackoff { refresh() }
    let queued = ProcessInfo.processInfo.systemUptime
    let firstLaunch = revision == nil
    let finish: (Error?) -> Void = { [weak self, weak controller] error in
      #if DEBUG
      self?.recordWait(since: queued, firstLaunch: firstLaunch)
      #endif
      if error == nil, let self, let controller, let url { self.exempt(controller, for: url) }
      completion(error)
    }
    if revision == nil, !preparing, failure != nil { return finish(nil) }
    if revision != nil && !reading { return finish(nil) }
    if revision == nil && waitedOut { return finish(nil) }
    let id = UUID()
    pending[id] = Pending(controller: controller, queued: queued, firstLaunch: firstLaunch, finish: finish)
    release(id, after: firstLaunch ? (coldCompiling ? firstLaunchWait : lookupWait) : Self.settingsWait)
  }

  private func release(_ id: UUID, after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
      guard let self, let item = self.pending.removeValue(forKey: id) else { return }
      if self.revision == nil {
        self.waitedOut = true
        NSLog("[webkit-blocker] rules not applied after %.1f s; loading without them until they apply", ProcessInfo.processInfo.systemUptime - item.queued)
      }
      item.finish(nil)
    }
  }

  func coldCompileStarted() {
    guard revision == nil, preparing, !coldCompiling else { return }
    coldCompiling = true
    let now = ProcessInfo.processInfo.systemUptime
    for (id, item) in pending where item.firstLaunch {
      release(id, after: item.queued + firstLaunchWait - now)
    }
  }

  #if DEBUG
  private func recordWait(since queued: TimeInterval, firstLaunch: Bool) {
    waitMetrics.append(["ms": (ProcessInfo.processInfo.systemUptime - queued) * 1000, "firstLaunch": firstLaunch, "applied": revision != nil])
    if waitMetrics.count > 256 { waitMetrics.removeFirst(waitMetrics.count - 256) }
  }
  #endif

  func refresh() {
    started = true
    generation += 1
    let current = generation
    failure = nil
    if safeMode() { return publish(Revision(settings: nil, lists: [], scripts: [], generation: current), generation: current) }
    preparing = true
    reading = true
    preparationStarted = ProcessInfo.processInfo.systemUptime
    NotificationCenter.default.post(name: Self.appliedNotification, object: self)
    read(generation: current)
  }

  private func read(generation current: Int) {
    var answered = false
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsReadTimeout) { [weak self] in
      guard let self, self.generation == current, !answered else { return }
      answered = true
      self.retryRead(Failure("The content blocker settings could not be read."), generation: current)
    }
    readState { [weak self] value in
      DispatchQueue.main.async {
        guard let self, self.generation == current, !answered else { return }
        answered = true
        do { self.apply(try Settings(value), generation: current) }
        catch { self.retryRead(error, generation: current) }
      }
    }
  }

  private func retryRead(_ error: Error, generation current: Int) {
    guard ProcessInfo.processInfo.systemUptime - preparationStarted < Self.settingsRetryWindow else {
      return reject(error, generation: current)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
      guard let self, self.generation == current else { return }
      self.read(generation: current)
    }
  }

  private func apply(_ settings: Settings, generation current: Int) {
    if let revision, revision.settings == settings { return publish(revision, generation: current) }
    if !settings.enabled { return publish(Revision(settings: settings, lists: [], scripts: [], generation: current), generation: current) }
    if let revision, let applied = revision.settings, applied.enabled, applied.enabledLists == settings.enabledLists {
      let scripts = Self.userScripts(revision.scriptSources, settings: settings, generation: current)
      return publish(Revision(settings: settings, lists: revision.lists, scripts: scripts, generation: current, groups: revision.groups,
                              unsupportedLists: revision.unsupportedLists, sourceBytes: revision.sourceBytes, identifiers: revision.identifiers,
                              scriptSources: revision.scriptSources), generation: current)
    }
    guard let root = resourceRoot else { return reject(Failure("The bundled content blocker is missing."), generation: current) }
    reading = false
    if revision != nil { finishPending(nil) }
    Task.detached(priority: .userInitiated) { [weak self] in
      let built = Result { try autoreleasepool { try WebKitContentBlocker.build(settings, root: root) } }
      await self?.compileBuilt(built, settings: settings, generation: current)
    }
  }

  nonisolated static func build(_ settings: Settings, root: URL) throws -> Built {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    guard manifest.schema == 1, !manifest.version.isEmpty, !manifest.lists.isEmpty,
      Set(manifest.lists.map(\.id)).count == manifest.lists.count,
      manifest.lists.allSatisfy({ !$0.id.isEmpty && !$0.uboIds.isEmpty && Set($0.uboIds).count == $0.uboIds.count })
    else { throw Failure("The bundled content blocker manifest has an unsupported version or invalid lists.") }
    guard manifest.encoding == nil || manifest.encoding == "deflate" else { throw Failure("The bundled content blocker lists use an unsupported encoding.") }
    let encoding = manifest.encoding
    let selected = manifest.selected(settings)
    let covered = Set(selected.flatMap(\.uboIds))
    var decisions: [Decision] = []
    for group in selected {
      let data = try contents(group.decisions, root: root, encoding: encoding)
      guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw Failure("The bundled content blocker decisions are invalid.")
      }
      for value in values {
        guard let priority = value["priority"] as? Int, priority > 0,
          let action = value["action"] as? String, ["block", "allow", "upgradeScheme"].contains(action),
          let trigger = value["trigger"] as? [String: Any], trigger["url-filter"] is String
        else { throw Failure("A bundled content blocker decision is invalid.") }
        decisions.append(Decision(priority: priority, action: action, trigger: trigger))
      }
    }
    var inputs: [(String, Source)] = []
    var sourceBytes = 0
    var scriptSources: [String] = []
    var identifiers = Set<String>()
    for group in selected {
      for chunk in group.chunks {
        guard chunk.priority > 0, ["block", "upgradeScheme", "cosmetic"].contains(chunk.kind) else {
          throw Failure("A bundled content blocker chunk has invalid priority metadata.")
        }
        let suppressors = suppressionRules(decisions, priority: chunk.priority, kind: chunk.kind)
        let suffix = try JSONSerialization.data(withJSONObject: suppressors, options: [.sortedKeys])
        let file = Asset(file: chunk.file, sha256: chunk.sha256)
        if let count = chunk.rules, count > 0, count + suppressors.count <= maximumRules {
          let identifier = "solara.webblock.\(manifest.version).\(digest(Data(chunk.sha256.utf8) + suffix))"
          let size = chunk.bytes ?? (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(chunk.file).path)[.size] as? Int) ?? 0
          sourceBytes += size + suffix.count
          if identifiers.insert(identifier).inserted { inputs.append((identifier, { try appending(suffix, to: contents(file, root: root, encoding: encoding)) })) }
          continue
        }
        for source in try chunkSources(contents(file, root: root, encoding: encoding), suppressors: suppressors) {
          let identifier = "solara.webblock.\(manifest.version).\(digest(Data(source.utf8)))"
          sourceBytes += source.utf8.count
          if identifiers.insert(identifier).inserted { inputs.append((identifier, { source })) }
        }
      }
      for script in group.scriptlets {
        guard let source = String(data: try contents(script, root: root, encoding: encoding), encoding: .utf8) else { throw Failure("A bundled content blocker script is not UTF-8.") }
        scriptSources.append(source)
      }
    }
    return Built(inputs: inputs, sourceBytes: sourceBytes, scriptSources: scriptSources, groups: selected.map(\.id), unsupported: settings.enabledLists.subtracting(covered).sorted())
  }

  private func compileBuilt(_ result: Result<Built, Error>, settings: Settings, generation current: Int) {
    guard generation == current, preparing else { return }
    let built: Built
    switch result {
    case .failure(let error): return reject(error, generation: current)
    case .success(let value): built = value
    }
    let scripts = Self.userScripts(built.scriptSources, settings: settings, generation: current)
    let inputs = built.inputs
    let sourceBytes = built.sourceBytes
    func revision(_ lists: [WKContentRuleList]) -> Revision {
      Revision(settings: settings, lists: lists, scripts: scripts, generation: current, groups: built.groups, unsupportedLists: built.unsupported,
               sourceBytes: sourceBytes, identifiers: inputs.map(\.0), scriptSources: built.scriptSources)
    }
    if inputs.isEmpty { return publish(revision([]), generation: current) }
    var lists = [WKContentRuleList?](repeating: nil, count: inputs.count)
    var remaining = inputs.count
    for (index, input) in inputs.enumerated() {
      compile(input.0, input.1) { [weak self] result in
        DispatchQueue.main.async {
          guard let self, self.generation == current, self.preparing else { return }
          switch result {
          case .failure(let error): self.reject(error, generation: current)
          case .success(let list):
            guard lists[index] == nil else { return }
            lists[index] = list
            remaining -= 1
            if remaining == 0 { self.publish(revision(lists.compactMap { $0 }), generation: current) }
          }
        }
      }
    }
  }

  private static func userScripts(_ sources: [String], settings: Settings, generation: Int) -> [WKUserScript] {
    sources.map { WKUserScript(source: guardedScript($0, trustedHosts: settings.trustedHosts, generation: generation), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page) }
  }

  func sync(_ view: WKWebView, url: URL?) {
    guard let url else { return }
    exempt(view.configuration.userContentController, for: url)
  }

  private func exempt(_ controller: WKUserContentController, for url: URL) {
    guard let record = controllers[ObjectIdentifier(controller)], let revision, let exempt = Self.exempts(revision, url: url),
      exempt != record.exempt
    else { return }
    record.exempt = exempt
    install(revision, on: record)
  }

  private static func exempts(_ revision: Revision, url: URL) -> Bool? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    return trusts(revision.settings, url: url)
  }

  static func trusts(_ trustedHosts: [String], host: String) -> Bool {
    guard let canonical = canonicalHost(host) else { return false }
    return trustedHosts.contains { trusted in canonical == trusted || (!trusted.hasPrefix("[") && canonical.hasSuffix("." + trusted)) }
  }

  static func trusts(_ settings: Settings?, url: URL) -> Bool {
    guard let settings else { return false }
    if trusts(settings.trustedHosts, host: url.host ?? "") { return true }
    guard !settings.directives.isEmpty, let host = canonicalHost(url.host ?? "") else { return false }
    let text = url.absoluteString
    return settings.directives.contains { $0.matches(text, host: host) }
  }

  static func directive(_ text: String) -> Directive? {
    guard let key = directiveKey(text) else { return nil }
    if key == "//" {
      return Directive(text: text, key: key, pattern: try? NSRegularExpression(pattern: String(text.dropFirst().dropLast())))
    }
    guard text.contains("*") else { return Directive(text: text, key: key, pattern: nil) }
    let escaped = NSRegularExpression.escapedPattern(for: text).replacingOccurrences(of: "\\*", with: ".*?")
    guard let pattern = try? NSRegularExpression(pattern: escaped) else { return nil }
    return Directive(text: text, key: key, pattern: pattern)
  }

  nonisolated static func boundedMatch(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    let range = NSRange(location: 0, length: min((text as NSString).length, directiveMatchLength))
    let started = ProcessInfo.processInfo.systemUptime
    var found = false
    pattern.enumerateMatches(in: text, options: [.reportProgress], range: range) { result, _, stop in
      if result != nil {
        found = true
        stop.pointee = true
      } else if ProcessInfo.processInfo.systemUptime - started > directiveMatchBudget {
        stop.pointee = true
      }
    }
    return found
  }

  static func portableRegex(_ source: String) -> Bool {
    let characters = Array(source)
    var index = 0
    var inClass = false
    var groups: [Bool] = []
    func at(_ offset: Int) -> Character? { index + offset < characters.count ? characters[index + offset] : nil }
    func quantifies() {
      if !groups.isEmpty { groups[groups.count - 1] = true }
    }
    while index < characters.count {
      let character = characters[index]
      if character == "\\" {
        guard let escaped = at(1) else { return false }
        if "AZzQEGhHpPNRX".contains(escaped) { return false }
        if escaped == "x" && at(2) == "{" { return false }
        index += 2
        continue
      }
      if inClass {
        if character == "]" { inClass = false }
        else if character == "[" { return false }
        else if character == "&" && at(1) == "&" { return false }
        index += 1
        continue
      }
      switch character {
      case "[":
        if at(1) == "]" || (at(1) == "^" && at(2) == "]") { return false }
        inClass = true
      case "(":
        if at(1) == "?" {
          guard let kind = at(2), ":=!<".contains(kind) else { return false }
          index += 2
        }
        groups.append(false)
      case ")":
        guard let inner = groups.popLast() else { return false }
        if let next = at(1), inner, "*+{".contains(next) { return false }
        if inner { quantifies() }
      case "*", "+", "?":
        if at(1) == "+" { return false }
        quantifies()
      case "{":
        quantifies()
      case "}":
        if at(1) == "+" { return false }
      default:
        break
      }
      index += 1
    }
    return !inClass && groups.isEmpty
  }

  static func directiveKey(_ directive: String) -> String? {
    if directive.count > 2 && directive.hasPrefix("/") && directive.hasSuffix("/") {
      let source = String(directive.dropFirst().dropLast())
      return portableRegex(source) && (try? NSRegularExpression(pattern: source)) != nil ? "//" : nil
    }
    guard directive.contains("/"), let match = directiveHost.firstMatch(in: directive, range: NSRange(directive.startIndex..., in: directive)),
      let range = Range(match.range(at: 1), in: directive)
    else { return nil }
    return String(directive[range])
  }

  static func directiveMatches(_ directive: String, url: String, host: String) -> Bool {
    Self.directive(directive)?.matches(url, host: host) ?? false
  }

  private static let directiveHost = try! NSRegularExpression(pattern: #"([a-z0-9.\-_\[\]]+)(?::[\d*]+)?/(?:[^\x00-\x20/]|$)[^\x00-\x20]*$"#)

  private func publish(_ revision: Revision, generation current: Int) {
    guard generation == current else { return }
    preparationMs = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1000
    let previous = self.revision
    self.revision = revision
    failure = nil
    preparing = false
    reading = false
    coldCompiling = false
    let rulesChanged = previous?.settings?.enabled != revision.settings?.enabled || previous?.groups != revision.groups
    for view in views.values.compactMap(\.value) {
      let record = controllers[ObjectIdentifier(view.configuration.userContentController)]
      if let record, let url = view.backForwardList.currentItem?.url ?? view.url, let exempt = Self.exempts(revision, url: url) { record.exempt = exempt }
      if rulesChanged || record?.exempt == true { cleanScriptlets(in: view, before: revision.generation) }
    }
    for controller in controllers.values { install(revision, on: controller) }
    if !revision.identifiers.isEmpty { removeStale(Set(revision.identifiers)) }
    finishPending(nil)
    NotificationCenter.default.post(name: Self.appliedNotification, object: self)
  }

  private func reject(_ error: Error, generation current: Int) {
    guard generation == current else { return }
    generation += 1
    preparing = false
    reading = false
    coldCompiling = false
    failure = error
    failedAt = ProcessInfo.processInfo.systemUptime
    preparationMs = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1000
    NSLog("[webkit-blocker] %@%@", error.localizedDescription, revision == nil ? "; loading without rules" : "; preserving the last applied settings")
    finishPending(nil)
    NotificationCenter.default.post(name: Self.appliedNotification, object: self)
  }

  private func finishPending(_ error: Error?) {
    let ready = Array(pending.values)
    pending.removeAll()
    for item in ready { item.finish(error) }
  }

  private func install(_ revision: Revision, on record: Controller) {
    guard let controller = record.value else { return }
    let lists = record.exempt ? [] : revision.lists
    let scripts = record.exempt ? [] : revision.scripts
    for list in record.lists { controller.remove(list) }
    for list in lists { controller.add(list) }
    Self.replaceScripts(in: controller, owned: record.scripts, with: scripts)
    record.lists = lists
    record.scripts = scripts
  }

  static func replaceScripts(in controller: WKUserContentController, owned: [WKUserScript], with scripts: [WKUserScript]) {
    if owned.isEmpty && scripts.isEmpty { return }
    let identities = Set(owned.map(ObjectIdentifier.init))
    let retained = controller.userScripts.filter { !identities.contains(ObjectIdentifier($0)) }
    controller.removeAllUserScripts()
    for script in retained + scripts { controller.addUserScript(script) }
  }

  static func canonicalHosts(_ hosts: [String]) -> [String] {
    var result = Set<String>()
    for value in hosts {
      guard let host = canonicalHost(value) else {
        NSLog("[webkit-blocker] omitting an unsupported trusted-site entry")
        continue
      }
      result.insert(host)
    }
    return result.sorted()
  }

  static func canonicalHost(_ value: String) -> String? {
    let lowered = value.lowercased()
    if lowered.contains(":") {
      let raw = lowered.hasPrefix("[") && lowered.hasSuffix("]") ? String(lowered.dropFirst().dropLast()) : lowered
      guard !raw.contains("%") else { return nil }
      var address = in6_addr()
      guard inet_pton(AF_INET6, raw, &address) == 1 else { return nil }
      let words = withUnsafeBytes(of: address) { bytes in
        stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
      }
      var start = 0
      var bestStart = 0
      var bestCount = 0
      while start < words.count {
        if words[start] != 0 { start += 1; continue }
        var end = start
        while end < words.count && words[end] == 0 { end += 1 }
        if end - start > bestCount { bestStart = start; bestCount = end - start }
        start = end
      }
      let text = words.map { String($0, radix: 16) }
      if bestCount < 2 { return "[" + text.joined(separator: ":") + "]" }
      let prefix = text[..<bestStart].joined(separator: ":")
      let suffix = text[(bestStart + bestCount)...].joined(separator: ":")
      return "[" + prefix + "::" + suffix + "]"
    }
    let host = lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard !host.isEmpty, host.utf8.count <= 253, host.unicodeScalars.allSatisfy({ $0.isASCII }),
      labels.allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
          label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
      })
    else { return nil }
    return host
  }

  nonisolated static func suppressionRules(_ decisions: [Decision], priority: Int, kind: String) -> [[String: Any]] {
    var identities = Set<Data>()
    return decisions.filter { decision in
      if kind == "cosmetic" { return false }
      if decision.priority > priority { return true }
      return decision.priority == priority && (decision.action == "allow" || (kind == "upgradeScheme" && decision.action == "block"))
    }.compactMap { decision in
      guard let identity = try? JSONSerialization.data(withJSONObject: decision.trigger, options: [.sortedKeys]), identities.insert(identity).inserted else { return nil }
      return ["trigger": decision.trigger, "action": ["type": "ignore-previous-rules"]] as [String: Any]
    }
  }

  nonisolated static func appending(_ suffix: Data, to chunk: Data) throws -> String {
    let space: Set<UInt8> = [0x20, 0x0a, 0x0d, 0x09]
    guard let start = chunk.firstIndex(where: { !space.contains($0) }), let end = chunk.lastIndex(where: { !space.contains($0) }),
      chunk[start] == 0x5b, chunk[end] == 0x5d, end > start + 1
    else { throw Failure("A bundled content blocker chunk is empty or invalid.") }
    guard suffix.count > 2 else { return String(decoding: chunk[start...end], as: UTF8.self) }
    var joined = Data(chunk[start..<end])
    joined.append(0x2c)
    joined.append(suffix.dropFirst())
    return String(decoding: joined, as: UTF8.self)
  }

  nonisolated static func chunkSources(_ data: Data, suppressors: [[String: Any]]) throws -> [String] {
    guard let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rules.isEmpty else {
      throw Failure("A bundled content blocker chunk is empty or invalid.")
    }
    let capacity = maximumRules - suppressors.count
    guard capacity > 0 else { throw Failure("The selected content blocker exceptions exceed WebKit's rule limit.") }
    var sources: [String] = []
    for offset in stride(from: 0, to: rules.count, by: capacity) {
      let chunk = Array(rules[offset..<min(rules.count, offset + capacity)]) + suppressors
      sources.append(String(decoding: try JSONSerialization.data(withJSONObject: chunk, options: [.sortedKeys]), as: UTF8.self))
    }
    return sources
  }

  nonisolated private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func contents(_ asset: Asset, root: URL, encoding: String?) throws -> Data {
    let parts = asset.file.split(separator: "/", omittingEmptySubsequences: false)
    guard !asset.file.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      asset.sha256.count == 64, asset.sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
    else { throw Failure("A bundled content blocker asset has an invalid path or hash.") }
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let url = root.appendingPathComponent(asset.file).resolvingSymlinksInPath().standardizedFileURL
    guard url.path.hasPrefix(rootPath) else { throw Failure("A bundled content blocker asset is outside its resource directory.") }
    let stored = try Data(contentsOf: url)
    let data: Data
    if encoding == "deflate" {
      do { data = try (stored as NSData).decompressed(using: .zlib) as Data }
      catch { throw Failure("A bundled content blocker asset could not be decompressed.") }
    } else {
      data = stored
    }
    guard digest(data) == asset.sha256 else { throw Failure("A bundled content blocker asset failed its SHA-256 check.") }
    return data
  }

  private static func guardedScript(_ source: String, trustedHosts: [String], generation: Int) -> String {
    let hosts = String(decoding: (try? JSONSerialization.data(withJSONObject: trustedHosts)) ?? Data("[]".utf8), as: UTF8.self)
    return """
      (() => {
        try {
          if (location.protocol !== "http:" && location.protocol !== "https:") return;
          const topURL = new URL(window.top.location.href);
          if (topURL.protocol !== "http:" && topURL.protocol !== "https:") return;
          const trusted = \(hosts);
          const isTrusted = value => {
            const host = value.toLowerCase().replace(/\\.$/, "");
            return trusted.some(value => host === value || (!value.startsWith("[") && host.endsWith("." + value)));
          };
          if (isTrusted(topURL.hostname) || isTrusted(location.hostname)) return;
        } catch (_) { return; }
        globalThis[Symbol.for("solara.ubol.version")] = \(generation);
        \(source)
      })();
      """
  }

  private static func finishCompilation(_ identifier: String, result: Result<WKContentRuleList, Error>) {
    let completions = Self.pendingCompilations.removeValue(forKey: identifier) ?? []
    for completion in completions { completion(result) }
  }

  private static func compileCached(_ identifier: String, _ source: @escaping Source, completion: @escaping CompilationCompletion) {
    DispatchQueue.main.async {
      if Self.pendingCompilations[identifier] != nil {
        Self.pendingCompilations[identifier, default: []].append(completion)
        return
      }
      Self.pendingCompilations[identifier] = [completion]
      let store: WKContentRuleListStore
      do { store = try Self.ruleStore() }
      catch { return Self.finishCompilation(identifier, result: .failure(error)) }
      let started = ProcessInfo.processInfo.systemUptime
      store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
        DispatchQueue.main.async {
          if let list {
            Self.recordCompilation(identifier, bytes: 0, cached: true, started: started, error: nil)
            return Self.finishCompilation(identifier, result: .success(list))
          }
          NotificationCenter.default.post(name: Self.coldCompileNotification, object: nil)
          DispatchQueue.global(qos: .userInitiated).async {
            let text = Result { try autoreleasepool { try source() } }
            DispatchQueue.main.async {
              let encoded: String
              switch text {
              case .failure(let error): return Self.finishCompilation(identifier, result: .failure(error))
              case .success(let value): encoded = value
              }
              store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) { list, error in
                DispatchQueue.main.async {
                  Self.recordCompilation(identifier, bytes: encoded.utf8.count, cached: false, started: started, error: error)
                  if let list { Self.finishCompilation(identifier, result: .success(list)) }
                  else { Self.finishCompilation(identifier, result: .failure(error ?? Failure("WebKit could not compile a content blocker chunk."))) }
                }
              }
            }
          }
        }
      }
    }
  }

  static func removeStaleRuleLists(keeping current: Set<String>) {
    guard let store = try? ruleStore() else { return }
    store.getAvailableContentRuleListIdentifiers { identifiers in
      DispatchQueue.main.async {
        for identifier in identifiers ?? [] where identifier.hasPrefix("solara.webblock.") && !current.contains(identifier) && Self.pendingCompilations[identifier] == nil {
          store.removeContentRuleList(forIdentifier: identifier) { _ in }
        }
      }
    }
  }

  private static func ruleStore() throws -> WKContentRuleListStore {
    let environment = ProcessInfo.processInfo.environment
    if let data = environment["SOLARA_DATA_DIR"], !data.isEmpty {
      let url = URL(fileURLWithPath: data, isDirectory: true).appendingPathComponent("WebKitContentRules", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      guard let store = WKContentRuleListStore(url: url) else { throw Failure("The WebKit content rule store in the data folder is unavailable.") }
      return store
    }
    guard let store = WKContentRuleListStore.default() else { throw Failure("The WebKit content rule store is unavailable.") }
    return store
  }

  private static func recordCompilation(_ identifier: String, bytes: Int, cached: Bool, started: TimeInterval, error: Error?) {
    #if DEBUG
    var metric: [String: Any] = ["identifier": identifier, "cached": cached, "ms": (ProcessInfo.processInfo.systemUptime - started) * 1000, "sourceBytes": bytes]
    if let error { metric["error"] = error.localizedDescription }
    compilationMetrics.append(metric)
    if compilationMetrics.count > 2048 { compilationMetrics.removeFirst(compilationMetrics.count - 2048) }
    #endif
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    prepare(webView.configuration.userContentController, url: action.targetFrame?.isMainFrame == true && !action.shouldPerformDownload ? action.request.url : nil) { error in
      if let error { NSLog("[webkit-blocker] popup navigation blocked: %@", error.localizedDescription) }
      decisionHandler(error == nil ? (action.shouldPerformDownload ? .download : .allow) : .cancel)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if response.isForMainFrame { sync(webView, url: response.canShowMIMEType ? response.response.url : webView.backForwardList.currentItem?.url) }
    decisionHandler(response.canShowMIMEType ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    sync(webView, url: webView.backForwardList.currentItem?.url)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    sync(webView, url: webView.backForwardList.currentItem?.url ?? webView.url)
  }
}
