import Foundation
import CryptoKit
import JavaScriptCore
import Testing
import WebKit

@Suite @MainActor struct WebKitContentBlockerTests {
  @Test func trustedHostsRequireCanonicalDNSNames() throws {
    #expect(WebKitContentBlocker.canonicalHosts(["Example.COM", "news.example.com"]) == ["example.com", "news.example.com"])
    for host in ["*", "*.example.com", "a_.com", "example.com/path", "example.com:443", " example.com", "a..com", "-a.com", "éxample.com"] {
      #expect(WebKitContentBlocker.canonicalHosts([host]).isEmpty)
    }
  }

  @Test func urlAndRegexDirectivesMatchLikeUBlock() throws {
    let settings = try WebKitContentBlocker.Settings(["enabled": true, "lists": [], "allowedHosts": [], "stats": ["ready": true],
      "trustedDirectives": ["https://shop.test/cart*", "*news.test/*", "/^https://[a-z]+\\.regex\\.test//", "https://exact.test/page", "no-slash-here", "/[/"]])
    #expect(settings.trustedDirectives.count == 4)
    for url in ["https://shop.test/cart", "https://shop.test/cart/42", "https://www.news.test/a", "https://abc.regex.test/x", "https://exact.test/page"] {
      #expect(WebKitContentBlocker.trusts(settings, url: try #require(URL(string: url))), "\(url)")
    }
    for url in ["https://shop.test/other", "https://evil.test/?https://shop.test/cart", "https://news.test.evil/a", "https://evilnews.test/a", "https://a1.regex.test/x", "https://exact.test/page2"] {
      #expect(!WebKitContentBlocker.trusts(settings, url: try #require(URL(string: url))), "\(url)")
    }
  }

  @Test func regexDirectivesValidOnlyInICUAreDropped() throws {
    for source in ["(?i)shop", "\\Ahttps:", "a++", "a*+", "a{2}+", "[[a]]", "[a&&b]", "[]a]", "\\p{L}", "\\x{41}", "(?>a)", "(a+)+$", "(?:a*)*b", "(a|b+){2,}"] {
      #expect(!WebKitContentBlocker.portableRegex(source), "\(source)")
    }
    for source in ["^https://[a-z]+\\.test/", "(?:a|b)/x", "(?=x)y", "(?<!x)y", "[^/]+\\?q=", "(a|b)+c", "\\d{2,4}", "a+?b"] {
      #expect(WebKitContentBlocker.portableRegex(source), "\(source)")
    }
    let settings = try WebKitContentBlocker.Settings(["enabled": true, "lists": [], "allowedHosts": [], "stats": ["ready": true],
      "trustedDirectives": ["/(?i)shop\\.test/", "/^https:\\/\\/ok\\.test\\//", "/(a+)+$/"]])
    #expect(settings.trustedDirectives == ["/^https:\\/\\/ok\\.test\\//"])
    #expect(WebKitContentBlocker.trusts(settings, url: try #require(URL(string: "https://ok.test/a"))))
    #expect(!WebKitContentBlocker.trusts(settings, url: try #require(URL(string: "https://SHOP.test/a"))))
  }

  @Test(.timeLimit(.minutes(1))) func catastrophicDirectivesStopWithinTheirBudget() throws {
    let settings = try WebKitContentBlocker.Settings(["enabled": true, "lists": [], "allowedHosts": [], "stats": ["ready": true],
      "trustedDirectives": ["/(a|aa)+b/", "x.test/*a*a*a*a*a*a*a*a*b"]])
    #expect(settings.trustedDirectives.count == 2)
    let url = try #require(URL(string: "https://x.test/" + String(repeating: "a", count: 4000)))
    let started = ProcessInfo.processInfo.systemUptime
    #expect(!WebKitContentBlocker.trusts(settings, url: url))
    #expect(ProcessInfo.processInfo.systemUptime - started < 1)
  }

  @Test func trustedSitesMatchTheHostAndItsSubdomainsOnly() {
    for host in ["example.com", "a.b.example.com", "EXAMPLE.com."] { #expect(WebKitContentBlocker.trusts(["example.com"], host: host)) }
    for host in ["badexample.com", "example.com.evil", "", "com"] { #expect(!WebKitContentBlocker.trusts(["example.com"], host: host)) }
  }

  @Test func mergedGroupsApplyWhenTheirMainListIsOn() throws {
    let manifest = WebKitContentBlocker.Manifest(schema: 1, version: "fixture", lists: [
      .init(id: "merged", uboIds: ["a", "b"], defaultEnabled: true, chunks: [], scriptlets: [], decisions: .init(file: "fixture", sha256: "")),
      .init(id: "single", uboIds: ["c"], defaultEnabled: false, chunks: [], scriptlets: [], decisions: .init(file: "fixture", sha256: "")),
    ])
    let state = try WebKitContentBlocker.Settings(["enabled": true, "lists": [["id": "a", "enabled": true], ["id": "b", "enabled": false], ["id": "c", "enabled": true]], "allowedHosts": [], "stats": ["ready": true]])
    #expect(manifest.selected(state).map(\.id) == ["merged", "single"])
    let mainOff = try WebKitContentBlocker.Settings(["enabled": true, "lists": [["id": "a", "enabled": false], ["id": "b", "enabled": true], ["id": "c", "enabled": true]], "allowedHosts": [], "stats": ["ready": true]])
    #expect(manifest.selected(mainOff).map(\.id) == ["single"])
  }

  @Test func packedListsDecompressAndKeepTheirDigest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func packed(_ file: String, _ text: String) throws -> [String: Any] {
      let data = Data(text.utf8)
      try ((data as NSData).compressed(using: .zlib) as Data).write(to: root.appendingPathComponent(file))
      return ["file": file, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "bytes": data.count]
    }
    let rules = "[{\"trigger\":{\"url-filter\":\"ads\"},\"action\":{\"type\":\"block\"}}]"
    var chunk = try packed("rules.json.deflate", rules)
    chunk["rules"] = 1
    chunk["priority"] = 1
    chunk["kind"] = "block"
    var broken = try packed("broken.json.deflate", rules)
    try Data("not deflate".utf8).write(to: root.appendingPathComponent("broken.json.deflate"))
    broken["rules"] = 1
    broken["priority"] = 1
    broken["kind"] = "block"
    func write(encoding: String, chunks: [[String: Any]]) throws {
      let manifest: [String: Any] = ["schema": 1, "version": "fixture", "encoding": encoding, "lists": [
        ["id": "fixture", "uboIds": ["fixture"], "defaultEnabled": true, "chunks": chunks, "scriptlets": [], "decisions": try packed("decisions.json.deflate", "[]")] as [String: Any],
      ]]
      try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    }
    let settings = try WebKitContentBlocker.Settings(["enabled": true, "lists": [["id": "fixture", "enabled": true]], "allowedHosts": [], "stats": ["ready": true]])
    try write(encoding: "deflate", chunks: [chunk])
    let built = try WebKitContentBlocker.build(settings, root: root)
    #expect(built.inputs.count == 1)
    #expect(try built.inputs.first?.1() == rules)
    #expect(built.sourceBytes == rules.utf8.count + 2)
    try write(encoding: "deflate", chunks: [broken])
    let corrupt = try WebKitContentBlocker.build(settings, root: root)
    #expect(throws: (any Error).self) { try corrupt.inputs.first?.1() }
    try write(encoding: "lzma", chunks: [chunk])
    #expect(throws: (any Error).self) { try WebKitContentBlocker.build(settings, root: root) }
  }

  @Test func unconfirmedStateCannotDisableBlocking() {
    #expect(throws: (any Error).self) {
      try WebKitContentBlocker.Settings(["enabled": false, "lists": [], "allowedHosts": [], "stats": ["ready": false]])
    }
  }

  @Test func changingOwnedScriptsPreservesUnrelatedScripts() {
    let controller = WKUserContentController()
    let baseline = WKUserScript(source: "void 0", injectionTime: .atDocumentStart, forMainFrameOnly: false)
    let blocker = WKUserScript(source: "void 1", injectionTime: .atDocumentStart, forMainFrameOnly: false)
    let extensionScript = WKUserScript(source: "void 2", injectionTime: .atDocumentStart, forMainFrameOnly: false)
    controller.addUserScript(baseline)
    controller.addUserScript(blocker)
    controller.addUserScript(extensionScript)
    WebKitContentBlocker.replaceScripts(in: controller, owned: [blocker], with: [])
    #expect(controller.userScripts.count == 2)
    #expect(controller.userScripts[0] === baseline)
    #expect(controller.userScripts[1] === extensionScript)
  }
}

@Suite @MainActor struct WebKitContentBlockerChunkTests {
  @Test func appendingSuppressorsKeepsOneValidArray() throws {
    let chunk = Data("[{\"a\":1},{\"b\":2}]\n".utf8)
    let suffix = try JSONSerialization.data(withJSONObject: [["c": 3]], options: [.sortedKeys])
    let joined = try WebKitContentBlocker.appending(suffix, to: chunk)
    let parsed = try #require(JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [[String: Int]])
    #expect(parsed == [["a": 1], ["b": 2], ["c": 3]])
    #expect(try WebKitContentBlocker.appending(Data("[]".utf8), to: chunk) == "[{\"a\":1},{\"b\":2}]")
    #expect(throws: (any Error).self) { try WebKitContentBlocker.appending(suffix, to: Data("[]".utf8)) }
    #expect(throws: (any Error).self) { try WebKitContentBlocker.appending(suffix, to: Data("{}".utf8)) }
  }

  @Test func everySplitCarriesAllSuppressors() throws {
    let base: [String: Any] = ["trigger": ["url-filter": "ads"], "action": ["type": "block"]]
    let suppressor: [String: Any] = ["trigger": ["url-filter": "allow"], "action": ["type": "ignore-previous-rules"]]
    let data = try JSONSerialization.data(withJSONObject: Array(repeating: base, count: 150_000))
    let sources = try WebKitContentBlocker.chunkSources(data, suppressors: [suppressor])
    #expect(sources.count == 2)
    var blockCount = 0
    for source in sources {
      let values = try #require(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [[String: Any]])
      #expect(values.count <= 140_000)
      #expect((values.last?["trigger"] as? [String: String])?["url-filter"] == "allow")
      blockCount += values.count - 1
    }
    #expect(blockCount == 150_000)
  }

  @Test func impossibleExceptionSuffixFailsWithoutDroppingExceptions() throws {
    let source = Data("[{\"trigger\":{\"url-filter\":\"ads\"},\"action\":{\"type\":\"block\"}}]".utf8)
    let suppressor: [String: Any] = ["trigger": ["url-filter": "allow"], "action": ["type": "ignore-previous-rules"]]
    #expect(throws: (any Error).self) {
      try WebKitContentBlocker.chunkSources(source, suppressors: Array(repeating: suppressor, count: 140_000))
    }
  }
}

@Suite @MainActor struct WebKitContentBlockerReadinessTests {
  private func turn() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }

  private func state(enabled: Bool, ready: Bool = true) -> [String: Any] {
    ["enabled": enabled, "lists": [], "allowedHosts": [], "stats": ["ready": ready]]
  }

  @Test func unreadySettingsAreReadAgainWithoutCancellingTheNavigation() async throws {
    var readers: [([String: Any]) -> Void] = []
    let blocker = WebKitContentBlocker(resourceRoot: nil, safeMode: { false }, readState: { readers.append($0) }, retryDelay: 0, observeChanges: false)
    var outcome: Error?? = .none
    blocker.prepare(WKUserContentController()) { outcome = .some($0) }
    readers[0](state(enabled: false, ready: false))
    for _ in 0..<50 where readers.count < 2 { await turn() }
    #expect(outcome == nil)
    #expect(readers.count == 2)
    readers[1](state(enabled: false))
    await turn()
    #expect(outcome != nil && outcome! == nil)
  }

  @Test func staleStateCannotOverrideLaterSettings() async {
    var readers: [([String: Any]) -> Void] = []
    let blocker = WebKitContentBlocker(resourceRoot: nil, safeMode: { false }, readState: { readers.append($0) }, observeChanges: false)
    var completed = false
    var failed = false
    blocker.prepare(WKUserContentController()) { error in completed = true; failed = error != nil }
    blocker.refresh()
    readers[0](state(enabled: false))
    await turn()
    #expect(!completed)
    readers[1](state(enabled: true))
    await turn()
    #expect(completed)
    #expect(!failed)
  }

  @Test func failuresWithoutARevisionLoadPagesUnblocked() async {
    var readers: [([String: Any]) -> Void] = []
    let blocker = WebKitContentBlocker(resourceRoot: nil, safeMode: { false }, readState: { readers.append($0) }, observeChanges: false)
    var outcomes: [Bool] = []
    blocker.prepare(WKUserContentController()) { outcomes.append($0 == nil) }
    readers[0](["enabled": true, "lists": [], "allowedHosts": [], "stats": ["ready": true]])
    await turn()
    blocker.prepare(WKUserContentController()) { outcomes.append($0 == nil) }
    #expect(outcomes == [true, true])
    #expect(readers.count == 1)
    #expect(blocker.status(host: "example.com")["error"] is String)
  }

  @Test func transientFailurePreservesLastAppliedSettings() async {
    var readers: [([String: Any]) -> Void] = []
    let blocker = WebKitContentBlocker(resourceRoot: nil, safeMode: { false }, readState: { readers.append($0) }, retryDelay: 0, observeChanges: false)
    let controller = WKUserContentController()
    var failures = 0
    blocker.prepare(controller) { if $0 != nil { failures += 1 } }
    readers[0](state(enabled: false))
    await turn()
    blocker.refresh()
    blocker.prepare(controller) { if $0 != nil { failures += 1 } }
    readers[1](state(enabled: false, ready: false))
    for _ in 0..<50 where readers.count < 3 { await turn() }
    #expect(readers.count == 3)
    readers[2](state(enabled: false))
    await turn()
    blocker.prepare(controller) { if $0 != nil { failures += 1 } }
    #expect(failures == 0)
    #expect(blocker.status(host: "example.com")["ready"] as? Bool == true)
  }

  @Test(.timeLimit(.minutes(1))) func slowFirstCompileReleasesNavigationAndStillApplies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func asset(_ file: String, _ text: String) throws -> [String: Any] {
      let data = Data(text.utf8)
      try data.write(to: root.appendingPathComponent(file))
      return ["file": file, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
    var chunk = try asset("rules.json", "[{\"trigger\":{\"url-filter\":\"ads\"},\"action\":{\"type\":\"block\"}}]")
    chunk["rules"] = 1
    chunk["priority"] = 1
    chunk["kind"] = "block"
    let manifest: [String: Any] = ["schema": 1, "version": "fixture", "lists": [
      ["id": "fixture", "uboIds": ["fixture"], "defaultEnabled": true, "chunks": [chunk], "scriptlets": [], "decisions": try asset("decisions.json", "[]")] as [String: Any],
    ]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    let on: [String: Any] = ["enabled": true, "lists": [["id": "fixture", "enabled": true]], "allowedHosts": [], "stats": ["ready": true]]
    var held: [(String, WebKitContentBlocker.Source, WebKitContentBlocker.CompilationCompletion)] = []
    var readers: [([String: Any]) -> Void] = []
    let blocker = WebKitContentBlocker(resourceRoot: root, safeMode: { false }, readState: { readers.append($0) },
                                       compile: { held.append(($0, $1, $2)) }, removeStale: { _ in }, firstLaunchWait: 0.05, observeChanges: false)
    var first: Error?? = .none
    blocker.prepare(WKUserContentController()) { first = .some($0) }
    readers[0](on)
    for _ in 0..<500 where held.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(held.count == 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(first == nil)
    blocker.coldCompileStarted()
    try await Task.sleep(for: .milliseconds(100))
    #expect(first != nil && first! == nil)
    var second = false
    blocker.prepare(WKUserContentController()) { second = $0 == nil }
    #expect(second)
    let store = try #require(WKContentRuleListStore(url: root.appendingPathComponent("store")))
    let (identifier, source, completion) = held[0]
    let list: WKContentRuleList? = await withCheckedContinuation { done in
      store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: (try? source()) ?? "") { list, _ in done.resume(returning: list) }
    }
    completion(.success(try #require(list)))
    await turn()
    #expect(blocker.status(host: "example.com")["ready"] as? Bool == true)
    #expect(blocker.status(host: "example.com")["appliedGroups"] as? [String] == ["fixture"])
    blocker.refresh()
    var whileRecompiling = false
    blocker.prepare(WKUserContentController()) { whileRecompiling = $0 == nil }
    #expect(!whileRecompiling)
    readers[1](["enabled": true, "lists": [["id": "fixture", "enabled": true], ["id": "other", "enabled": true]], "allowedHosts": [], "stats": ["ready": true]])
    await turn()
    #expect(whileRecompiling)
    #expect(blocker.status(host: "example.com")["preparing"] as? Bool == true)
  }

  @Test(.timeLimit(.minutes(1))) func cachedLaunchWaitsForTheLookupBeyondTheCompileCap() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func asset(_ file: String, _ text: String) throws -> [String: Any] {
      let data = Data(text.utf8)
      try data.write(to: root.appendingPathComponent(file))
      return ["file": file, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
    var chunk = try asset("rules.json", "[{\"trigger\":{\"url-filter\":\"ads\"},\"action\":{\"type\":\"block\"}}]")
    chunk["rules"] = 1
    chunk["priority"] = 1
    chunk["kind"] = "block"
    let manifest: [String: Any] = ["schema": 1, "version": "fixture", "lists": [
      ["id": "fixture", "uboIds": ["fixture"], "defaultEnabled": true, "chunks": [chunk], "scriptlets": [], "decisions": try asset("decisions.json", "[]")] as [String: Any],
    ]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    var held: [(String, WebKitContentBlocker.Source, WebKitContentBlocker.CompilationCompletion)] = []
    var readers: [([String: Any]) -> Void] = []
    let blocker = WebKitContentBlocker(resourceRoot: root, safeMode: { false }, readState: { readers.append($0) },
                                       compile: { held.append(($0, $1, $2)) }, removeStale: { _ in }, firstLaunchWait: 0.05, lookupWait: 5, observeChanges: false)
    var released = false
    var appliedWhenReleased = false
    blocker.prepare(WKUserContentController()) { _ in
      released = true
      appliedWhenReleased = blocker.status(host: "example.com")["ready"] as? Bool == true
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(!released)
    readers[0](["enabled": true, "lists": [["id": "fixture", "enabled": true]], "allowedHosts": [], "stats": ["ready": true]])
    for _ in 0..<500 where held.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!released)
    let store = try #require(WKContentRuleListStore(url: root.appendingPathComponent("store")))
    let (identifier, source, completion) = held[0]
    let list: WKContentRuleList? = await withCheckedContinuation { done in
      store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: (try? source()) ?? "") { list, _ in done.resume(returning: list) }
    }
    completion(.success(try #require(list)))
    await turn()
    #expect(released)
    #expect(appliedWhenReleased)
    var waits: [[String: Any]] = []
    #if DEBUG
    waits = blocker.status(host: "example.com")["waits"] as? [[String: Any]] ?? []
    #endif
    #expect(waits.isEmpty || (waits.first?["applied"] as? Bool == true))
  }

  @Test func safeModeDoesNotFetchSettingsOrCompileRules() {
    var reads = 0
    var compiles = 0
    let blocker = WebKitContentBlocker(resourceRoot: nil, safeMode: { true }, readState: { _ in reads += 1 }, compile: { _, _, _ in compiles += 1 }, observeChanges: false)
    var completed = false
    blocker.prepare(WKUserContentController()) { error in completed = error == nil }
    #expect(completed)
    #expect(reads == 0)
    #expect(compiles == 0)
  }
}

@Suite @MainActor struct WebKitContentBlockerPriorityTests {
  @Test func crossListIgnoresPreserveGlobalDNRPrecedence() {
    let decisions: [WebKitContentBlocker.Decision] = [
      .init(priority: 1, action: "allow", trigger: ["url-filter": "lowerAllow"]),
      .init(priority: 2, action: "allow", trigger: ["url-filter": "equalAllow"]),
      .init(priority: 2, action: "block", trigger: ["url-filter": "equalBlock"]),
      .init(priority: 2, action: "upgradeScheme", trigger: ["url-filter": "equalUpgrade"]),
      .init(priority: 3, action: "block", trigger: ["url-filter": "higherBlock"]),
      .init(priority: 3, action: "upgradeScheme", trigger: ["url-filter": "higherUpgrade"]),
    ]
    func filters(_ kind: String) -> [String] {
      WebKitContentBlocker.suppressionRules(decisions, priority: 2, kind: kind).compactMap { ($0["trigger"] as? [String: String])?["url-filter"] }
    }
    #expect(filters("block") == ["equalAllow", "higherBlock", "higherUpgrade"])
    #expect(filters("upgradeScheme") == ["equalAllow", "equalBlock", "higherBlock", "higherUpgrade"])
    #expect(filters("cosmetic").isEmpty)
  }
}

@Suite @MainActor struct WebKitContentBlockerTrustedCompatibilityTests {
  @Test func canonicalizesIPv6AndDNSDotsWithoutBroadeningInvalidEntries() {
    #expect(WebKitContentBlocker.canonicalHosts(["Example.COM.", "[0:0:0:0:0:0:0:1]", "::1", "[::ffff:192.0.2.1]", "invalid/path"]) == ["[::1]", "[::ffff:c000:201]", "example.com"])
    #expect(WebKitContentBlocker.canonicalHosts(["[::1]:8080", "[fe80::1%en0]", "[broken]", "example.com.."]).isEmpty)
  }

  @Test func malformedTrustedEntryDoesNotInvalidateConfirmedOffState() throws {
    let off = try WebKitContentBlocker.Settings(["enabled": false, "allowedHosts": NSNull(), "stats": ["ready": true]])
    #expect(!off.enabled)
    #expect(off.trustedHosts.isEmpty)
    let on = try WebKitContentBlocker.Settings(["enabled": true, "lists": [], "allowedHosts": ["example.com", "[::1]", "invalid/path"], "stats": ["ready": true]])
    #expect(on.trustedHosts == ["[::1]", "example.com"])
  }

  @Test func trustedIPv6IsExactAndDNSMatchesTrailingDot() {
    let hosts = WebKitContentBlocker.canonicalHosts(["[::1]", "example.com."])
    for url in ["http://[::1]:8080/", "https://user:pass@[::1]/", "http://example.com.:9090/", "https://user:pass@a.example.com/"] {
      #expect(WebKitContentBlocker.trusts(hosts, host: URL(string: url)?.host ?? ""))
    }
    for url in ["http://[::11]/", "https://[::1]@evil/", "https://example.com@evil/", "https://example.com.evil/"] {
      #expect(!WebKitContentBlocker.trusts(hosts, host: URL(string: url)?.host ?? ""))
    }
  }

  @Test func duplicateSuppressionTriggersOccupyOneSuffixRule() {
    let trigger: [String: Any] = ["url-filter": "allow", "resource-type": ["script"]]
    let decisions: [WebKitContentBlocker.Decision] = [
      .init(priority: 2, action: "allow", trigger: trigger),
      .init(priority: 3, action: "block", trigger: trigger),
      .init(priority: 3, action: "upgradeScheme", trigger: trigger),
    ]
    #expect(WebKitContentBlocker.suppressionRules(decisions, priority: 1, kind: "block").count == 1)
  }
}


@Suite @MainActor struct WebKitContentBlockerStatusTests {
  private func turn() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }

  @Test(.timeLimit(.minutes(1))) func statusPreservesOffAfterCompileFailureAndRetryCanEnable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func asset(_ file: String, _ text: String) throws -> [String: String] {
      let data = Data(text.utf8)
      try data.write(to: root.appendingPathComponent(file))
      return ["file": file, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
    let rules = try asset("rules.json", "[{\"trigger\":{\"url-filter\":\"ads\"},\"action\":{\"type\":\"block\"}}]")
    let decisions = try asset("decisions.json", "[]")
    var chunk: [String: Any] = rules
    chunk["priority"] = 1
    chunk["kind"] = "block"
    let manifest: [String: Any] = ["schema": 1, "version": "fixture", "lists": [
      ["id": "fixture", "uboIds": ["fixture"], "defaultEnabled": true, "chunks": [chunk], "scriptlets": [], "decisions": decisions] as [String: Any],
    ]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    var readers: [([String: Any]) -> Void] = []
    var compiles = 0
    var kept: [Set<String>] = []
    let blocker = WebKitContentBlocker(resourceRoot: root, safeMode: { false }, readState: { readers.append($0) }, compile: { identifier, source, completion in
      compiles += 1
      if compiles == 1 { return completion(.failure(WebKitContentBlocker.Failure("fixture compile failed"))) }
      try? FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
      guard let store = WKContentRuleListStore(url: root.appendingPathComponent("store")) else {
        return completion(.failure(WebKitContentBlocker.Failure("The test rule store is unavailable.")))
      }
      store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: (try? source()) ?? "") { list, error in
        if let list { completion(.success(list)) }
        else { completion(.failure(error ?? WebKitContentBlocker.Failure("The test rules did not compile."))) }
      }
    }, removeStale: { kept.append($0) }, failureBackoff: 0, observeChanges: false)
    #expect(blocker.status(host: "example.com")["ready"] as? Bool == false)
    #expect(blocker.status(host: "example.com")["enabled"] as? Bool == false)
    let controller = WKUserContentController()
    blocker.prepare(controller) { _ in }
    readers[0](["enabled": false, "stats": ["ready": true]])
    await turn()
    #expect(blocker.status(host: "example.com")["ready"] as? Bool == true)
    blocker.refresh()
    #expect(blocker.status(host: "example.com")["preparing"] as? Bool == true)
    #expect(blocker.status(host: "example.com")["enabled"] as? Bool == false)
    readers[1](["enabled": true, "lists": [["id": "fixture", "enabled": true]], "allowedHosts": ["example.com"], "stats": ["ready": true]])
    for _ in 0..<500 where blocker.status(host: "example.com")["preparing"] as? Bool == true { try await Task.sleep(for: .milliseconds(10)) }
    let status = blocker.status(host: "example.com")
    #expect(compiles == 1)
    #expect(status["enabled"] as? Bool == false)
    #expect(status["allowed"] as? Bool == false)
    #expect(status["ready"] as? Bool == true)
    #expect(status["preparing"] as? Bool == false)
    #expect(status["error"] as? String == "fixture compile failed")
    var retryError: Error?
    var retryFinished = false
    blocker.prepare(controller) { retryError = $0; retryFinished = true }
    #expect(readers.count == 3)
    #expect(blocker.status(host: "example.com")["preparing"] as? Bool == true)
    if readers.count == 3 {
      readers[2](["enabled": true, "lists": [["id": "fixture", "enabled": true]], "allowedHosts": ["example.com"], "stats": ["ready": true]])
    }
    await turn()
    #expect(retryFinished)
    #expect(retryError == nil)
    for _ in 0..<500 where blocker.status(host: "example.com")["preparing"] as? Bool == true { try await Task.sleep(for: .milliseconds(10)) }
    #expect(compiles == 2)
    #expect(kept.count == 1 && kept.first?.count == 1 && kept.first?.first?.hasPrefix("solara.webblock.fixture.") == true)
    let retried = blocker.status(host: "sub.example.com")
    #expect(retried["enabled"] as? Bool == true)
    #expect(retried["allowed"] as? Bool == true)
    #expect(retried["ready"] as? Bool == true)
    #expect(retried["preparing"] as? Bool == false)
    #expect(retried["error"] is NSNull)
    blocker.refresh()
    readers[3](["enabled": true, "lists": [["id": "fixture", "enabled": true]], "allowedHosts": [], "stats": ["ready": true]])
    await turn()
    let untrusted = blocker.status(host: "sub.example.com")
    #expect(compiles == 2)
    #expect(untrusted["allowed"] as? Bool == false)
    #expect(untrusted["ready"] as? Bool == true)
  }
}


@Suite @MainActor struct WebKitContentBlockerCleanupTests {
  @Test func delayedCleanupStopsOnlyOlderGenerations() throws {
    let context = try #require(JSContext())
    context.evaluateScript("""
      globalThis.stopped = [];
      globalThis[Symbol.for("solara.ubol.cleanup")] = [
        { version: 6, stop() { stopped.push("old"); } },
        { version: 7, stop() { stopped.push("current"); } },
        { version: 8, stop() { stopped.push("newer"); } },
      ];
      """)
    context.evaluateScript(WebKitContentBlocker.cleanupScript(before: 7))
    #expect(context.evaluateScript("stopped.join(',')")?.toString() == "old")
    #expect(context.evaluateScript("globalThis[Symbol.for('solara.ubol.cleanup')].map(entry => entry.version).join(',')")?.toString() == "7,8")
    context.evaluateScript(WebKitContentBlocker.cleanupScript(before: 6))
    #expect(context.evaluateScript("stopped.join(',')")?.toString() == "old")
    context.evaluateScript(WebKitContentBlocker.cleanupScript(before: 8))
    #expect(context.evaluateScript("stopped.join(',')")?.toString() == "old,current")
  }
}

@Suite @MainActor struct WebKitContentBlockerCoverageTests {
  private func turn() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }

  @Test func unavailableSelectedListsAreReportedAlongsideSupportedGroups() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("[]".utf8)
    try data.write(to: root.appendingPathComponent("decisions.json"))
    let decisions = ["file": "decisions.json", "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    let manifest: [String: Any] = ["schema": 1, "version": "fixture", "lists": [
      ["id": "merged", "uboIds": ["a", "b"], "defaultEnabled": true, "chunks": [], "scriptlets": [], "decisions": decisions],
      ["id": "single", "uboIds": ["c"], "defaultEnabled": false, "chunks": [], "scriptlets": [], "decisions": decisions],
    ]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
    let blocker = WebKitContentBlocker(resourceRoot: root, safeMode: { false }, readState: { done in
      done(["enabled": true, "lists": [["id": "a", "enabled": false], ["id": "b", "enabled": true], ["id": "c", "enabled": true], ["id": "unknown", "enabled": true]], "allowedHosts": [], "stats": ["ready": true]])
    }, observeChanges: false)
    blocker.prepare(WKUserContentController()) { _ in }
    for _ in 0..<500 where blocker.status(host: "example.com")["ready"] as? Bool != true { try await Task.sleep(for: .milliseconds(10)) }
    let status = blocker.status(host: "example.com")
    #expect(status["ready"] as? Bool == true)
    #expect(status["enabled"] as? Bool == true)
    #expect(status["unsupportedLists"] as? [String] == ["b", "unknown"])
    #expect(status["appliedGroups"] as? [String] == ["single"])
  }

  @Test func settingsChangesDoNotStartABlockerNoWebKitTabNeeds() async {
    var reads = 0
    let blocker = WebKitContentBlocker(resourceRoot: nil, safeMode: { false }, readState: { _ in reads += 1 })
    NotificationCenter.default.post(name: Notification.Name("SolaraCoreContentBlockerChanged"), object: nil)
    await turn()
    #expect(reads == 0)
    #expect(blocker.status(host: "example.com")["generation"] as? Int == 0)
    blocker.start()
    #expect(reads == 1)
    blocker.start()
    #expect(reads == 1)
    NotificationCenter.default.post(name: Notification.Name("SolaraCoreContentBlockerChanged"), object: nil)
    await turn()
    #expect(reads == 2)
  }

  @Test func refreshPublishesPreparingBeforeSettingsReply() {
    let blocker = WebKitContentBlocker(resourceRoot: nil, safeMode: { false }, readState: { _ in }, observeChanges: false)
    nonisolated(unsafe) var preparing = false
    let observer = NotificationCenter.default.addObserver(forName: WebKitContentBlocker.appliedNotification, object: blocker, queue: .main) { _ in
      MainActor.assumeIsolated { preparing = blocker.status(host: "example.com")["preparing"] as? Bool == true }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    blocker.refresh()
    #expect(preparing)
  }
}
