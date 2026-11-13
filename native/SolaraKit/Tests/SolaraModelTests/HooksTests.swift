import Foundation
import SolaraModel
import Testing

@Suite struct HooksFileTests {
  func rules(_ json: String) throws -> [HookRule] { try HooksFile.parse(Data(json.utf8)) }

  func error(_ json: String) -> String? {
    do {
      _ = try HooksFile.parse(Data(json.utf8))
      return nil
    } catch {
      return error.description
    }
  }

  @Test func parsesEveryAction() throws {
    let parsed = try rules("""
      {"version": 1, "hooks": [
        {"name": "old-reddit", "match": {"hosts": ["www.reddit.com"]}, "rewrite": "https://old.reddit.com{path}{query}{fragment}"},
        {"name": "no-tiktok", "match": {"hosts": "*.tiktok.com"}, "block": true},
        {"name": "slack", "match": {"apps": ["com.tinyspeck.slackmacgap"]}, "openIn": {"profile": "Work"}},
        {"name": "invoices", "match": {"urls": ["https://billing.example.com/*"]}, "fileInto": "~/Downloads/Invoices"},
        {"name": "no-camera", "match": {"hosts": ["*.example.com"]}, "deny": ["camera", "microphone"]},
        {"name": "script", "on": "download.finished", "run": ["/usr/bin/true"], "timeout": 5},
        {"name": "clean", "match": {"hosts": ["*.example.com"]}, "stripParams": ["utm_*", "fbclid"]},
        {"name": "secure", "match": {"hosts": ["plain.example"]}, "https": true},
        {"name": "ding", "on": ["download.finished"], "sound": "Glass"},
        {"name": "tell", "on": "download.finished", "notify": true}
      ]}
      """)
    #expect(parsed.map(\.action.kind) == ["rewrite", "block", "openIn", "fileInto", "deny", "run", "stripParams", "https", "sound", "notify"])
    #expect(parsed.map(\.needsApproval) == [true, false, false, false, false, true, false, false, false, false])
    if case .run(let argv, let events, let timeout) = parsed[5].action {
      #expect(argv == ["/usr/bin/true"])
      #expect(events == [.downloadFinished])
      #expect(timeout == 5)
    } else {
      Issue.record("not a run hook")
    }
    #expect(parsed[6].action == .stripParams(["utm_*", "fbclid"]))
    #expect(parsed[8].action.events == [.downloadFinished])
  }

  @Test func refusesWhatIsntAllowed() {
    let cases: [(String, String)] = [
      (#"[]"#, "must be an object"),
      (#"{"hooks": [], "extra": 1}"#, "unknown key"),
      (#"{"version": 2, "hooks": []}"#, "must be 1"),
      (#"{"hooks": [{"match": {}, "block": true}]}"#, "needs a name"),
      (#"{"hooks": [{"name": "a‮b", "match": {"hosts": "x.com"}, "block": true}]}"#, "needs a name"),
      (#"{"hooks": [{"name": "a", "block": true, "rewrite": "https://x/"}]}"#, "exactly one"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": "x.com"}, "block": true}, {"name": "A", "match": {"hosts": "x.com"}, "block": true}]}"#, "used by another hook"),
      (#"{"hooks": [{"name": "a", "block": "yes"}]}"#, "must be true"),
      (#"{"hooks": [{"name": "a", "block": true}]}"#, "needs urls, hosts or regex"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "javascript:alert(1)"}]}"#, "must start with"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "file:///etc/passwd"}]}"#, "must start with"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "{url}"}]}"#, "must start with"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "https://y.com/{nope}"}]}"#, "every { closed"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "https://y.com/{1}"}]}"#, "every { closed"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "{origin}.evil.net{path}"}]}"#, "must end the host"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "{origin}:8443{path}"}]}"#, "must end the host"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "{scheme}://{host}{port}.evil.net/{url}"}]}"#, "must end the host"),
      (#"{"hooks": [{"name": "a", "match": {"regex": "https://x\\.com/(.*)"}, "rewrite": "https://{1}.mirror.net/"}]}"#, "a placeholder can't be part of the host"),
      (#"{"hooks": [{"name": "a", "match": {"regex": "https://x\\.com/(.*)"}, "rewrite": "https://a{1}/"}]}"#, "a placeholder can't be part of the host"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["x.com"]}, "rewrite": "https://a@b.com/"}]}"#, "must start with a valid"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": "x.com", "regex": "https://x\\.com/(.*)"}, "rewrite": "https://y.com/{1}"}]}"#, "every { closed"),
      (#"{"hooks": [{"name": "a", "rewrite": "https://y.com/"}]}"#, "needs urls, hosts or regex"),
      (#"{"hooks": [{"name": "a", "match": {"apps": ["x"], "hosts": "x.com"}, "rewrite": "https://y.com/"}]}"#, "apps only applies"),
      (#"{"hooks": [{"name": "a", "match": {"regex": "(a+)+"}, "block": true}]}"#, "allowed regular expression"),
      (#"{"hooks": [{"name": "a", "match": {"regex": "(?>a)b"}, "block": true}]}"#, "allowed regular expression"),
      (#"{"hooks": [{"name": "a", "match": {"regex": "(?=a)a"}, "block": true}]}"#, "allowed regular expression"),
      (#"{"hooks": [{"name": "a", "match": {"regex": "(a)\\1"}, "block": true}]}"#, "allowed regular expression"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": ["bücher.de"]}, "block": true}]}"#, "punycode"),
      (#"{"hooks": [{"name": "a", "match": {"urls": ["https://a b/*"]}, "block": true}]}"#, "URL pattern"),
      (#"{"hooks": [{"name": "a", "match": {"urls": ["https://a.com"]}, "block": true}]}"#, "URL pattern"),
      (#"{"hooks": [{"name": "a", "match": {"urls": ["https://a*.com/"]}, "block": true}]}"#, "URL pattern"),
      (#"{"hooks": [{"name": "a", "match": {"what": 1}, "block": true}]}"#, "unknown key"),
      (#"{"hooks": [{"name": "a", "fileInto": "Downloads/x"}]}"#, "starting with ~/"),
      (#"{"hooks": [{"name": "a", "fileInto": "~/Downloads/../Library"}]}"#, "starting with ~/"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": "x.com"}, "deny": ["location"]}]}"#, "camera and microphone"),
      (#"{"hooks": [{"name": "a", "deny": ["camera"]}]}"#, "needs urls, hosts or regex"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": "x.com"}, "stripParams": ["a b"]}]}"#, "parameter names"),
      (#"{"hooks": [{"name": "a", "match": {"hosts": "x.com"}, "https": false}]}"#, "must be true"),
      (#"{"hooks": [{"name": "a", "sound": "../x", "on": "page.loaded"}]}"#, "system sound"),
      (#"{"hooks": [{"name": "a", "notify": true}]}"#, "needs \"on\""),
      (#"{"hooks": [{"name": "a", "run": "say hi", "on": "page.loaded"}]}"#, "must be a list"),
      (#"{"hooks": [{"name": "a", "run": ["say", "hi"], "on": "page.loaded"}]}"#, "full path"),
      (#"{"hooks": [{"name": "a", "run": ["/usr/bin/say"]}]}"#, "needs \"on\""),
      (#"{"hooks": [{"name": "a", "run": ["/usr/bin/say"], "on": "tab.closed"}]}"#, "events are"),
      (#"{"hooks": [{"name": "a", "run": ["/usr/bin/say"], "on": "page.loaded", "timeout": 0}]}"#, "1 to 600"),
      (#"{"hooks": [{"name": "a", "on": "page.loaded", "match": {"hosts": "x.com"}, "block": true}]}"#, "only run, notify and sound"),
      (#"{"hooks": [{"name": "a", "match": {"apps": ["x"]}, "fileInto": "~/Downloads/x"}]}"#, "apps only applies"),
      (#"{"hooks": [{"name": "a", "match": {"apps": ["x"]}, "run": ["/bin/echo"], "on": "page.loaded"}]}"#, "apps only applies"),
      (#"{"hooks": [{"name": "a", "openIn": {"profile": ""}}]}"#, "openIn"),
      ("{", "valid JSON"),
    ]
    for (json, expected) in cases {
      let message = error(json)
      #expect(message?.contains(expected) == true, "\(json) → \(message ?? "no error")")
    }
  }

  @Test func acceptsTemplatesThatKeepTheHost() throws {
    for template in [
      "https://old.reddit.com{path}{query}", "https://old.reddit.com/x?u={url}", "{origin}{path}", "{scheme}://{host}{port}/a",
      "https://{host}{path}", "http://{host}/", "https://proxy.example/?h={host}&p={path}",
    ] {
      #expect(error(#"{"hooks": [{"name": "r", "match": {"hosts": "x.com"}, "rewrite": "\#(template)"}]}"#) == nil, "\(template)")
    }
    #expect(error(#"{"hooks": [{"name": "r", "match": {"regex": "https://g\\.example/item/([0-9]+)"}, "rewrite": "https://g.example/v/{1}"}]}"#) == nil)
  }

  @Test func errorsNameTheHook() {
    #expect(error(#"{"hooks": [{"name": "ok", "match": {"hosts": "x.com"}, "block": true}, {"name": "bad", "block": false}]}"#) == "hooks[1] (bad).block: must be true")
  }

  @Test func approvalDigestFollowsContentNotOrder() throws {
    let one = try rules(#"{"hooks": [{"name": "a", "run": ["/bin/echo", "x"], "on": "page.loaded"}, {"name": "b", "match": {"hosts": "x.com"}, "block": true}]}"#)
    let swapped = try rules(#"{"hooks": [{"name": "b", "match": {"hosts": "x.com"}, "block": true}, {"on": "page.loaded", "run": ["/bin/echo", "x"], "name": "a"}]}"#)
    let edited = try rules(#"{"hooks": [{"name": "a", "run": ["/bin/echo", "y"], "on": "page.loaded"}]}"#)
    #expect(one[0].digest == swapped[1].digest)
    #expect(one[0].digest != edited[0].digest)
    #expect(one[0].digest.count == 64)
    #expect(one[0].text == #"{"name":"a","on":"page.loaded","run":["/bin/echo","x"]}"#)
  }
}

@Suite struct HookURLTests {
  @Test func readsCanonicalURLs() throws {
    let url = try #require(HookURL("HTTPS://WWW.Example.COM:443/a/b?c=d#e"))
    #expect(url.scheme == "https")
    #expect(url.host == "www.example.com")
    #expect(url.port == nil)
    #expect(url.effectivePort == 443)
    #expect(url.path == "/a/b")
    #expect(url.queryText == "?c=d")
    #expect(url.fragmentText == "#e")
    #expect(HookURL("http://example.com")?.string == "http://example.com/")
    #expect(HookURL("http://example.com:8080/x")?.origin == "http://example.com:8080")
    #expect(HookURL("https://tiktok.com./x")?.host == "tiktok.com")
    #expect(HookURL("http://[::1]:8000/")?.host == "[::1]")
    #expect(HookURL("http://127.0.0.1/")?.host == "127.0.0.1")
    #expect(HookURL("https://a@www.tiktok.com/")?.host == "www.tiktok.com")
    #expect(HookURL("https://user:pw@bank.example/x")?.string == "https://bank.example/x")
  }

  @Test func refusesAmbiguousURLs() {
    for text in [
      "https://evil.example\\@bank.example/", "https://bank.example /", "https://b%61nk.example/",
      "https://bücher.de/", "javascript:alert(1)", "file:///etc/passwd", "chrome://settings", "https://127.1/", "https://0x7f.0.0.1/",
      "https://0177.0.0.1/", "https://2130706433/", "https://[0:0::1]/", "https://a.com:0/", "https://a.com:080/", "https://a.com:70000/",
      "https://a..com/", "https://a.com/\u{0}x", "ftp://a.com/",
    ] {
      #expect(HookURL(text) == nil, "\(text)")
    }
  }
}

@Suite struct HookMatchingTests {
  static let home = "/Users/test"

  func hooks(_ json: String) throws -> Hooks {
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: Self.home)
    #expect(hooks.load(Data(json.utf8), path: "hooks.json") == nil)
    return hooks
  }

  func url(_ text: String) -> HookURL { HookURL(text)! }

  @Test func urlPatternsMatchEachPart() throws {
    let pattern = try #require(HookURLPattern("https://*.billing.com/*"))
    #expect(pattern.matches(url("https://billing.com/")))
    #expect(pattern.matches(url("https://a.b.billing.com/x?y")))
    #expect(!pattern.matches(url("https://evil.net/x.billing.com/")))
    #expect(!pattern.matches(url("http://www.billing.com/")))
    #expect(!pattern.matches(url("https://www.billing.com.evil.com/")))
    #expect(!pattern.matches(url("https://notbilling.com/")))
    #expect(HookURLPattern("https://a.com/x*y*z")!.matches(url("https://a.com/xyz")))
    #expect(!HookURLPattern("https://a.com/x*y*z")!.matches(url("https://a.com/xzy")))
    #expect(HookURLPattern("*://*/*")!.matches(url("http://anything.example:81/")))
    #expect(HookURLPattern("https://a.com/")!.matches(url("https://a.com/")))
    #expect(!HookURLPattern("https://a.com/")!.matches(url("https://a.com/?q")))
    #expect(HookURLPattern("https://a.com:8443/*")!.matches(url("https://a.com:8443/x")))
    #expect(!HookURLPattern("https://a.com:8443/*")!.matches(url("https://a.com/x")))
    #expect(!HookURLPattern("https://a.com/*a*a")!.matches(url("https://a.com/a")))
    #expect(HookURLPattern("https://a.com/x")!.matches(url("https://a.com/x#frag")))
  }

  @Test func hostsMatchSubdomainsOnlyWithAStar() {
    let any = HookHostPattern("*.Example.com")!
    #expect(any.matches("example.com"))
    #expect(any.matches("a.example.com"))
    #expect(!any.matches("badexample.com"))
    let exact = HookHostPattern("example.com")!
    #expect(exact.matches("example.com"))
    #expect(!exact.matches("www.example.com"))
  }

  @Test func regexMatchesTheWholeURLAndFailsClosed() throws {
    let regex = try #require(HookRegex("https://a\\.example/(\\w+)"))
    #expect(regex.match("https://a.example/x") == .matched(["https://a.example/x", "x"]))
    #expect(regex.match("https://a.example/x/more") == .missed)
    #expect(regex.match("https://evil.example/?https://a.example/x") == .missed)
    #expect(regex.match("https://a.example/" + String(repeating: "a", count: 70000)) == .failed)
    for good in ["https://a\\.com/.*", "a(b|c)d", "[a-z]+x", "(?:ab)c", "x{2,3}", "(?<id>[0-9]+)"] { #expect(HookRegex(good) != nil, "\(good)") }
    for bad in ["(a+)+", "(a*)*", "a++", "(?>a)", "(?i)a", "\\Aa", "[]", "a)", "(a", "(?=a)", "(?<=a)b", "(a)\\1", String(repeating: "a", count: 1025)] {
      #expect(HookRegex(bad) == nil, "\(bad)")
    }
  }

  @Test func linksFromAppsAreBlockedAndRouted() throws {
    let hooks = try hooks(
      """
      {"hooks": [
        {"name": "no-tiktok", "match": {"hosts": ["*.tiktok.com"]}, "block": true},
        {"name": "slack-block", "match": {"apps": ["com.tinyspeck.slackmacgap"], "hosts": ["x.example"]}, "block": true},
        {"name": "slack", "match": {"apps": ["com.tinyspeck.slackmacgap"]}, "openIn": {"profile": "Work"}},
        {"name": "long", "match": {"regex": "https://l\\\\.example/.*"}, "block": true}
      ]}
      """)
    #expect(hooks.blocksLink("https://www.tiktok.com/@a", app: nil, profile: nil) == "no-tiktok")
    #expect(hooks.blocksLink("https://a@www.tiktok.com/", app: nil, profile: nil) == "no-tiktok")
    #expect(hooks.blocksLink("https://tiktok.com./", app: nil, profile: nil) == "no-tiktok")
    #expect(hooks.blocksLink("https://x.example/", app: nil, profile: nil) == nil)
    let slack = HookSender(identifier: "com.TinySpeck.slackmacgap", team: "BQR82RBBHL", vouched: true)
    #expect(hooks.blocksLink("https://x.example/", app: slack, profile: nil) == "slack-block")
    #expect(hooks.blocksLink("https://other.example/" + String(repeating: "a", count: 70000), app: nil, profile: nil) == "long")
    #expect(hooks.routeLink("https://y.example/", app: slack)?.profile == "Work")
    #expect(hooks.routeLink("https://y.example/", app: HookSender(identifier: "com.apple.mail", team: "apple", vouched: true)) == nil)
    #expect(hooks.routeLink("https://y.example/", app: HookSender(identifier: "com.TinySpeck.slackmacgap", team: "BQR82RBBHL")) == nil)
    #expect(hooks.routeLink("https://y.example/", app: nil) == nil)
  }

  @Test func aLongURLOnlyFailsRulesThatCouldMatchIt() throws {
    let hooks = try hooks(#"{"hooks": [{"name": "p", "match": {"urls": ["https://p.example/*"]}, "block": true}]}"#)
    let tail = String(repeating: "a", count: 70000)
    #expect(hooks.blocksLink("https://other.example/" + tail, app: nil, profile: nil) == nil)
    #expect(hooks.blocksLink("https://p.example/" + tail, app: nil, profile: nil) == "p")
  }

  @Test func theEngineMatcherDecidesWhenPresent() throws {
    let hooks = try hooks(#"{"hooks": [{"name": "b", "match": {"hosts": ["x.example"]}, "block": true}]}"#)
    let digest = hooks.snapshot[0].digest
    hooks.engineMatch = { url in url.contains("engine-says-yes") ? ([digest], []) : url.contains("engine-failed") ? ([], [digest]) : ([], []) }
    #expect(hooks.blocksLink("https://x.example/", app: nil, profile: nil) == nil)
    #expect(hooks.blocksLink("https://y.example/engine-says-yes", app: nil, profile: nil) == "b")
    #expect(hooks.blocksLink("https://y.example/engine-failed", app: nil, profile: nil) == "b")
  }

  @Test func permissionsDenyForTheRequesterOrTheEmbedder() throws {
    let hooks = try hooks(#"{"hooks": [{"name": "cam", "match": {"hosts": ["*.example.com"]}, "deny": ["camera"]}]}"#)
    #expect(hooks.deniedPermissions(origins: ["https://meet.example.com/"], kinds: ["camera", "microphone"], profile: nil) == "cam")
    #expect(hooks.deniedPermissions(origins: ["https://meet.example.com/"], kinds: ["cameraPanTiltZoom"], profile: nil) == "cam")
    #expect(hooks.deniedPermissions(origins: ["https://meet.example.com/"], kinds: ["microphone"], profile: nil) == nil)
    #expect(hooks.deniedPermissions(origins: ["https://other.com/"], kinds: ["camera"], profile: nil) == nil)
    #expect(hooks.deniedPermissions(origins: ["https://widget.other.com/", "https://app.example.com/"], kinds: ["camera"], profile: nil) == "cam")
  }

  @Test func eventActionsNeedApprovalOnlyToRun() throws {
    let json = #"{"hooks": [{"name": "say", "on": ["page.loaded"], "match": {"hosts": ["a.example"]}, "run": ["~/bin/hook", "--flag"]}, {"name": "ding", "on": "page.loaded", "sound": "Glass"}]}"#
    let hooks = try hooks(json)
    let data = HookEventData(event: .pageLoaded, url: "https://a.example/$(rm%20-rf%20~)", profile: "Personal", title: "x\0y\u{202E}z")
    #expect(hooks.actions(for: data).map(\.rule.name) == ["ding"])
    let (command, _) = try #require(hooks.command(for: hooks.snapshot[0], data: data))
    #expect(command.argv == ["/Users/test/bin/hook", "--flag"])
    #expect(command.environment.contains("SOLARA_URL=https://a.example/$(rm%20-rf%20~)"))
    #expect(command.environment.contains("SOLARA_TITLE=xyz"))
    #expect(command.environment.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
    #expect(!command.environment.contains { $0.hasPrefix("DYLD_") || $0.hasPrefix("SOLARA_DATA_DIR") || $0.hasPrefix("SOLARA_REMOTE") })
    let stdin = try JSONSerialization.jsonObject(with: command.stdin) as? [String: String]
    #expect(stdin?["url"] == "https://a.example/$(rm%20-rf%20~)")
    #expect(stdin?["event"] == "page.loaded")
    #expect(HookEventData(event: .downloadFinished, file: "relative/x").file == nil)
    #expect(HookEventData(event: .downloadFinished, file: "/a/../b/x").file == "/b/x")
  }

  @Test func theEngineGetsOnlyUsableNavigationRules() throws {
    let hooks = try hooks(
      """
      {"hooks": [
        {"name": "b", "match": {"hosts": ["x.example"], "profiles": ["Work"]}, "block": true},
        {"name": "r", "match": {"hosts": ["www.reddit.com"]}, "rewrite": "https://old.reddit.com{path}"},
        {"name": "s", "match": {"hosts": ["*.example.com"]}, "stripParams": ["utm_*"]},
        {"name": "h", "match": {"hosts": ["plain.example"]}, "https": true},
        {"name": "a", "match": {"apps": ["com.x"], "hosts": ["y.example"]}, "block": true},
        {"name": "o", "match": {"apps": ["com.x"]}, "openIn": {"profile": "Work"}}
      ]}
      """)
    let config = hooks.engineConfiguration { $0 == "work" ? ["Profile 2"] : [] }
    #expect(config.map { $0["action"] as? String } == ["block", "none", "stripParams", "https", "none", "none"])
    #expect(config[0]["profiles"] as? [String] == ["Profile 2"])
    #expect(config[0]["hosts"] as? [String] == ["x.example"])
    #expect(config[2]["params"] as? [String] == ["utm_*"])
    #expect(config.allSatisfy { ($0["id"] as? String)?.count == 64 })
  }

  @Test func anInvalidFileTurnsEverythingOff() throws {
    let hooks = Hooks(approvals: HookApprovals(file: nil))
    hooks.load(Data(#"{"hooks": [{"name": "b", "match": {"hosts": "x.example"}, "block": true}]}"#.utf8), path: "h")
    #expect(hooks.load(Data("{".utf8), path: "h") != nil)
    #expect(hooks.status().error != nil)
    hooks.fail("bad", path: "h")
    #expect(!hooks.active)
    hooks.load(nil, path: "h")
    #expect(!hooks.active)
  }
}

@Suite struct HookApprovalTests {
  func scratch() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-approve-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard let real = realpath(dir, nil) else { return dir }
    defer { free(real) }
    return String(cString: real)
  }

  func script(_ dir: String, _ body: String, mode: Int = 0o700) throws -> String {
    let path = dir + "/hook.sh"
    try Data(body.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, mode_t(mode))
    return path
  }

  func load(_ hooks: Hooks, _ json: String) {
    #expect(hooks.load(Data(json.utf8), path: "") == nil)
  }

  func approve(_ hooks: Hooks, _ rule: HookRule) -> Result<Void, HookApprovalError> {
    hooks.approvals.approve(rule, snapshotHash: HookApprovals.snapshotHash(HookApprovals.snapshot(rule, home: hooks.home)), home: hooks.home)
  }

  func approved(_ hooks: Hooks, _ rule: HookRule) -> Bool {
    if case .success = approve(hooks, rule) { return true }
    return false
  }

  @Test func approvalBindsTheProgramsBytes() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let program = try script(dir, "#!/bin/sh\necho one\n")
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: dir)
    load(hooks, #"{"hooks": [{"name": "s", "on": "page.loaded", "run": ["\#(program)"]}]}"#)
    let rule = hooks.snapshot[0]
    #expect(hooks.approvals.state(rule, home: dir) == .needed)
    #expect(approved(hooks, rule))
    #expect(hooks.approvals.state(rule, home: dir) == .approved)
    #expect(hooks.approvals.verifyBeforeRun(rule, home: dir) == nil)
    try Data("#!/bin/sh\necho two\n".utf8).write(to: URL(fileURLWithPath: program))
    #expect(hooks.approvals.verifyBeforeRun(rule, home: dir)?.contains("changed since it was approved") == true)
    if case .filesChanged = hooks.approvals.state(rule, home: dir) {} else { Issue.record("expected filesChanged") }
  }

  @Test func scriptArgumentsAreBoundToo() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let body = try script(dir, "echo hi\n", mode: 0o600)
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: dir)
    load(hooks, #"{"hooks": [{"name": "s", "on": "page.loaded", "run": ["/bin/sh", "\#(body)"]}]}"#)
    let rule = hooks.snapshot[0]
    #expect(approved(hooks, rule))
    try Data("rm -rf ~\n".utf8).write(to: URL(fileURLWithPath: body))
    #expect(hooks.approvals.verifyBeforeRun(rule, home: dir) != nil)
    #expect(Hooks.flags(rule, home: dir).contains { $0.contains("runs whatever its arguments say") })
  }

  @Test func relativeArgumentsAreFingerprintedFromHome() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let body = dir + "/bin/notify.sh"
    try Data("echo one\n".utf8).write(to: URL(fileURLWithPath: body))
    chmod(body, 0o600)
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: dir)
    load(hooks, #"{"hooks": [{"name": "s", "on": "page.loaded", "run": ["/bin/sh", "bin/notify.sh"]}]}"#)
    let rule = hooks.snapshot[0]
    #expect(HookApprovals.snapshot(rule, home: dir).contains("file: \((body as NSString).standardizingPath) sha256"))
    #expect(approved(hooks, rule))
    #expect(hooks.approvals.verifyBeforeRun(rule, home: dir) == nil)
    if case .allowed(let program, _, _) = hooks.approvals.checkBeforeRun(rule, home: dir) {
      #expect(program == ("/bin/sh" as NSString).resolvingSymlinksInPath)
    } else {
      Issue.record("an approved command wasn't allowed")
    }
    try Data("echo two\n".utf8).write(to: URL(fileURLWithPath: body))
    #expect(hooks.approvals.verifyBeforeRun(rule, home: dir)?.contains("changed since it was approved") == true)
    if case .refused = hooks.approvals.checkBeforeRun(rule, home: dir) {} else { Issue.record("a changed script was allowed") }
  }

  @Test func anInterpreterGivenAFolderTurnsOnlyThatHookOff() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: dir)
    load(hooks, #"{"hooks": [{"name": "p", "on": "page.loaded", "run": ["/usr/bin/python3", "\#(dir)"]}, {"name": "d", "on": "page.loaded", "notify": true}]}"#)
    #expect(hooks.snapshot.count == 2)
    let status = hooks.status()
    #expect(status.error == nil)
    #expect(status.rules[0].problem?.contains("is a folder") == true)
    #expect(status.rules[1].problem == nil)
    if case .failure(.refused(let why)) = approve(hooks, hooks.snapshot[0]) { #expect(why.contains("is a folder")) } else { Issue.record("approved a folder argument") }
    #expect(!hooks.usable(hooks.snapshot[0]))
    #expect(hooks.actions(for: HookEventData(event: .pageLoaded, url: "https://x/")).map(\.rule.name) == ["d"])
    #expect(HookFingerprint.folderArgument(["/bin/echo", dir], home: dir) == nil)
  }

  @Test func aLinkToAnInterpreterIsStillAnInterpreter() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    symlink("/bin/sh", dir + "/notify")
    #expect(HookFingerprint.isInterpreter(dir + "/notify"))
    #expect(HookFingerprint.isInterpreter("/usr/bin/nohup"))
    #expect(!HookFingerprint.isInterpreter("/usr/bin/true"))
  }

  @Test func everyInvisibleCharacterIsEscaped() {
    for value: UInt32 in [0x2060, 0x2064, 0x00AD, 0x034F, 0x180E, 0xFE0F, 0xE0041, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x200B, 0x202E, 0x2066] {
      #expect(HookText.unsafe(Unicode.Scalar(value)!), "U+\(String(value, radix: 16))")
    }
    for character in "aé中 -_/" { #expect(!character.unicodeScalars.contains(where: HookText.unsafe)) }
    #expect(HookText.escaped("a\u{2060}b") == "a\\u{2060}b")
  }

  @Test func aChangedRuleShowsALineDiff() {
    let before = HookText.pretty(#"{"name":"say","on":"page.loaded","run":["/usr/bin/true","a"]}"#)
    let after = HookText.pretty(#"{"name":"say","on":"page.loaded","run":["/usr/bin/true","b"]}"#)
    let diff = HookText.lineDiff(before, after)
    #expect(diff.filter { $0.hasPrefix("- ") }.map { $0.replacingOccurrences(of: " ", with: "") } == [#"-"a""#])
    #expect(diff.filter { $0.hasPrefix("+ ") }.map { $0.replacingOccurrences(of: " ", with: "") } == [#"+"b""#])
  }

  @Test func writableProgramsAreRefused() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let program = try script(dir, "#!/bin/sh\n", mode: 0o722)
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: dir)
    load(hooks, #"{"hooks": [{"name": "s", "on": "page.loaded", "run": ["\#(program)"]}]}"#)
    if case .failure(.refused(let why)) = approve(hooks, hooks.snapshot[0]) {
      #expect(why.contains("group or world writable"))
    } else {
      Issue.record("approved a world-writable program")
    }
    chmod(program, 0o700)
    chmod(dir, 0o777)
    defer { chmod(dir, 0o700) }
    if case .failure(.refused) = approve(hooks, hooks.snapshot[0]) {} else { Issue.record("approved a program in a world-writable folder") }
  }

  @Test func aStaleSheetCantApprove() throws {
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: "/Users/test")
    load(hooks, #"{"hooks": [{"name": "s", "on": "page.loaded", "run": ["/usr/bin/true"]}]}"#)
    let shown = HookApprovals.snapshotHash("something else")
    if case .failure(.stale) = hooks.approvals.approve(hooks.snapshot[0], snapshotHash: shown, home: "/Users/test") {} else { Issue.record("a stale sheet approved") }
    #expect(!hooks.approvals.isApproved(hooks.snapshot[0].digest))
  }

  @Test func editingARuleShowsWhatChanged() throws {
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: "/Users/test")
    load(hooks, #"{"hooks": [{"name": "say", "on": "page.loaded", "run": ["/usr/bin/true", "a"]}]}"#)
    #expect(approved(hooks, hooks.snapshot[0]))
    #expect(hooks.status().rules[0].approved)
    load(hooks, #"{"hooks": [{"name": "say", "on": "page.loaded", "run": ["/usr/bin/true", "b"]}]}"#)
    #expect(!hooks.status().rules[0].approved)
    #expect(hooks.status().rules[0].approval == .changed(previous: #"{"name":"say","on":"page.loaded","run":["/usr/bin/true","a"]}"#))
    #expect(hooks.actions(for: HookEventData(event: .pageLoaded, url: "https://x/")).isEmpty)
  }

  @Test func snapshotsEscapeHiddenCharacters() throws {
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: "/Users/test")
    load(hooks, #"{"hooks": [{"name": "s", "on": "page.loaded", "run": ["/usr/bin/true", "a                    b", "x‮y"]}]}"#)
    let snapshot = HookApprovals.snapshot(hooks.snapshot[0], home: "/Users/test")
    #expect(snapshot.contains("argument 2: x\\u{202E}y"))
    #expect(snapshot.contains("argument 1: a                    b"))
    #expect(Hooks.flags(hooks.snapshot[0], home: "/Users/test").contains { $0.contains("invisible") })
  }

  @Test func approvalsPersistPrivately() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let file = URL(fileURLWithPath: dir).appendingPathComponent("hooks-approvals.json")
    let hooks = Hooks(approvals: HookApprovals(file: file), home: "/Users/test")
    load(hooks, #"{"hooks": [{"name": "say", "on": "page.loaded", "run": ["/usr/bin/true"]}]}"#)
    #expect(approved(hooks, hooks.snapshot[0]))
    #expect(HookApprovals(file: file).isApproved(hooks.snapshot[0].digest))
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func foldersOutsideDownloadsAreBoundToTheirIdentity() throws {
    let home = try scratch()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: home + "/Elsewhere", withIntermediateDirectories: true)
    let hooks = Hooks(approvals: HookApprovals(file: nil), home: home)
    load(hooks, #"{"hooks": [{"name": "f", "fileInto": "~/Elsewhere"}]}"#)
    let rule = hooks.snapshot[0]
    #expect(hooks.engineConfiguration { _ in [] }[0]["action"] as? String == "none")
    #expect(approved(hooks, rule))
    let config = hooks.engineConfiguration { _ in [] }[0]
    #expect(config["action"] as? String == "fileInto")
    #expect(config["root"] as? String == home + "/Elsewhere")
    #expect(config["below"] as? [String] == [])
    try FileManager.default.moveItem(atPath: home + "/Elsewhere", toPath: home + "/Moved")
    try FileManager.default.createDirectory(atPath: home + "/Elsewhere", withIntermediateDirectories: true)
    #expect(hooks.engineConfiguration { _ in [] }[0]["action"] as? String == "none")
    if case .filesChanged = hooks.approvals.state(rule, home: home) {} else { Issue.record("a replaced folder kept its approval") }
  }
}

@Suite struct HookFolderTests {
  @Test func foldersInsideDownloadsNeedNoApproval() throws {
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-home-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: made + "/Downloads/Real", withIntermediateDirectories: true)
    let home = try #require(realpath(made, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) })
    defer { try? FileManager.default.removeItem(atPath: home) }
    try FileManager.default.createDirectory(atPath: home + "/Elsewhere", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: home + "/Downloads/Sneaky", withDestinationPath: home + "/Elsewhere")
    #expect(HookFolder("~/Downloads/New/Deeper", home: home)?.insideDownloads == true)
    #expect(HookFolder("~/Downloads", home: home)?.insideDownloads == true)
    #expect(HookFolder("~/Downloads/Sneaky", home: home)?.insideDownloads == false)
    #expect(HookFolder("~/DownloadsX", home: home)?.insideDownloads == false)
    #expect(HookFolder(home + "/Downloads/A", home: home)?.insideDownloads == true)
    #expect(HookFolder("~/Downloads/./A", home: home) == nil)
    let spec = try #require(HookFolder("~/Downloads/Real/New", home: home)?.spec())
    #expect(spec.root == home + "/Downloads")
    #expect(spec.below == ["Real", "New"])
    #expect(spec.identity == HookFileIdentity.of(home + "/Downloads"))
    #expect(HookFolder("~/Downloads/Sneaky", home: home)?.spec() == nil)
  }
}

#if os(macOS)
@Suite struct HookCommandRunnerTests {
  func waitForLog(_ path: String, containing text: String) async -> Bool {
    for _ in 0..<50 {
      if let log = try? String(contentsOfFile: path, encoding: .utf8), log.contains(text) { return true }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return false
  }

  @Test func runsWithACleanEnvironmentAndStdin() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("out.txt").path
    setenv("SOLARA_REMOTE_DEBUGGING_PORT", "9222", 1)
    let command = HookCommand(
      rule: "t", argv: ["/bin/sh", "-c", "env > \"$0\"; cat >> \"$0\"; echo said-hello", out],
      data: HookEventData(event: .pageLoaded, url: "https://a.example/;touch /tmp/pwned", profile: "P"))
    let log = dir.appendingPathComponent("hooks.log")
    let runner = HookCommandRunner(log: log)
    runner.verify = { _ in HookCommandRunner.unverified("/bin/sh") }
    let ended = AsyncStream<Int32>.makeStream()
    runner.onExit = { _, code in ended.continuation.yield(code) }
    runner.run(digest: "t", rule: "t", event: .pageLoaded, command: command, timeout: 10)
    var iterator = ended.stream.makeAsyncIterator()
    #expect(await iterator.next() == 0)
    let text = try String(contentsOfFile: out, encoding: .utf8)
    #expect(text.contains("SOLARA_URL=https://a.example/;touch /tmp/pwned"))
    #expect(!text.contains("SOLARA_REMOTE_DEBUGGING_PORT"))
    #expect(text.contains("\"event\":\"page.loaded\""))
    #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
    #expect(await waitForLog(log.path, containing: "said-hello"))
  }

  @Test func aCommandThatOutlivesItsTimeoutIsStopped() async throws {
    let runner = HookCommandRunner(log: nil)
    runner.verify = { _ in HookCommandRunner.unverified("/bin/sleep") }
    let ended = AsyncStream<Int32>.makeStream()
    runner.onExit = { _, code in ended.continuation.yield(code) }
    let started = Date()
    runner.run(digest: "slow", rule: "slow", event: .pageLoaded, command: HookCommand(rule: "slow", argv: ["/bin/sleep", "30"], data: HookEventData(event: .pageLoaded)), timeout: 1)
    var iterator = ended.stream.makeAsyncIterator()
    #expect(await iterator.next() == -SIGTERM)
    #expect(Date().timeIntervalSince(started) < 5)
  }

  @Test func aChangedProgramDoesntRun() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-verify-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("hooks.log")
    let marker = dir.appendingPathComponent("ran").path
    let runner = HookCommandRunner(log: log)
    runner.verify = { _ in .refused("changed since it was approved") }
    runner.run(digest: "v", rule: "v", event: .pageLoaded, command: HookCommand(rule: "v", argv: ["/usr/bin/touch", marker], data: HookEventData(event: .pageLoaded)), timeout: 5)
    #expect(await waitForLog(log.path, containing: "not run: changed since it was approved"))
    #expect(!FileManager.default.fileExists(atPath: marker))
  }

  @Test func floodsDropPageEventsButNeverDownloads() async throws {
    let runner = HookCommandRunner(log: nil)
    runner.verify = { _ in HookCommandRunner.unverified("/bin/sleep") }
    let ended = AsyncStream<String>.makeStream()
    runner.onExit = { rule, _ in ended.continuation.yield(rule) }
    let slow = HookCommand(rule: "x", argv: ["/bin/sleep", "0.3"], data: HookEventData(event: .pageLoaded))
    for _ in 0..<5 { runner.run(digest: "dl", rule: "dl", event: .downloadFinished, command: slow, timeout: 5) }
    for _ in 0..<40 { runner.run(digest: "page", rule: "page", event: .pageLoaded, command: slow, timeout: 5) }
    var downloads = 0
    var iterator = ended.stream.makeAsyncIterator()
    while downloads < 5, let rule = await iterator.next() { if rule == "dl" { downloads += 1 } }
    #expect(downloads == 5)
    #expect(runner.dropCounts["dl"] == nil)
    #expect((runner.dropCounts["page"] ?? 0) > 0)
  }

  @Test func finishedDownloadsAreBoundedToo() async throws {
    let runner = HookCommandRunner(log: nil, downloadQueueLimit: 3)
    runner.verify = { _ in HookCommandRunner.unverified("/bin/sleep") }
    let ended = AsyncStream<String>.makeStream()
    runner.onExit = { rule, _ in ended.continuation.yield(rule) }
    let slow = HookCommand(rule: "x", argv: ["/bin/sleep", "0.3"], data: HookEventData(event: .downloadFinished))
    for _ in 0..<10 { runner.run(digest: "dl", rule: "dl", event: .downloadFinished, command: slow, timeout: 5) }
    var finished = 0
    var iterator = ended.stream.makeAsyncIterator()
    while finished < 5, await iterator.next() != nil { finished += 1 }
    #expect(runner.dropCounts["dl"] == 5)
  }

  @Test func whatACommandLeavesRunningIsStoppedWithIt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-orphan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = dir.appendingPathComponent("pid").path
    let runner = HookCommandRunner(log: nil)
    runner.verify = { _ in HookCommandRunner.unverified("/bin/sh") }
    let ended = AsyncStream<Int32>.makeStream()
    runner.onExit = { _, code in ended.continuation.yield(code) }
    let command = HookCommand(rule: "o", argv: ["/bin/sh", "-c", "/bin/sleep 30 & echo $! > \"$0\"", marker], data: HookEventData(event: .pageLoaded))
    runner.run(digest: "o", rule: "o", event: .pageLoaded, command: command, timeout: 60)
    var iterator = ended.stream.makeAsyncIterator()
    #expect(await iterator.next() == 0)
    let pid = pid_t(try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    #expect(pid > 0)
    var gone = false
    for _ in 0..<30 where !gone {
      gone = kill(pid, 0) != 0 && errno == ESRCH
      if !gone { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    #expect(gone)
  }

  @Test func withoutACheckNothingRuns() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-nocheck-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("hooks.log")
    let marker = dir.appendingPathComponent("ran").path
    let runner = HookCommandRunner(log: log)
    runner.run(digest: "n", rule: "n", event: .pageLoaded, command: HookCommand(rule: "n", argv: ["/usr/bin/touch", marker], data: HookEventData(event: .pageLoaded)), timeout: 5)
    #expect(await waitForLog(log.path, containing: "not run: nothing is set up to check it"))
    #expect(!FileManager.default.fileExists(atPath: marker))
  }

  @Test func aCommandThatNeverReadsStdinDoesntHangTheWriter() async throws {
    let runner = HookCommandRunner(log: nil)
    runner.verify = { _ in HookCommandRunner.unverified("/bin/sh") }
    let ended = AsyncStream<Int32>.makeStream()
    runner.onExit = { _, code in ended.continuation.yield(code) }
    let big = String(repeating: "x", count: 4000)
    let data = HookEventData(event: .pageLoaded, url: "https://a.example/" + big, profile: big, title: big)
    let started = Date()
    runner.run(digest: "w", rule: "w", event: .pageLoaded, command: HookCommand(rule: "w", argv: ["/bin/sh", "-c", "exec 0<&-; /bin/sleep 0.5"], data: data), timeout: 10)
    var iterator = ended.stream.makeAsyncIterator()
    #expect(await iterator.next() == 0)
    #expect(Date().timeIntervalSince(started) < 5)
  }

  @Test func theVerifiedProgramIsTheOneThatRuns() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-swap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("hooks.log")
    let marker = dir.appendingPathComponent("ran").path
    let runner = HookCommandRunner(log: log)
    runner.verify = { _ in .allowed(program: "/usr/bin/touch", dev: 1, ino: 1) }
    runner.run(digest: "s", rule: "s", event: .pageLoaded, command: HookCommand(rule: "s", argv: ["/usr/bin/touch", marker], data: HookEventData(event: .pageLoaded)), timeout: 5)
    #expect(await waitForLog(log.path, containing: "changed just before it would have run"))
    #expect(!FileManager.default.fileExists(atPath: marker))
  }
}

@Suite struct HookSenderTests {
  func made(_ json: String, file: URL? = nil, installed: [String: String] = [:]) -> Hooks {
    let hooks = Hooks(approvals: HookApprovals(file: nil), senders: HookSenderTeams(file: file), home: "/Users/test")
    hooks.registeredTeam = { installed[$0] }
    #expect(hooks.load(Data(json.utf8), path: "") == nil)
    return hooks
  }

  @Test func theInstalledAppsTeamDecides() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-senders-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("hooks-senders.json")
    let rule = #"{"hooks": [{"name": "o", "match": {"apps": ["com.example.chat"]}, "openIn": {"profile": "Work"}}]}"#
    let hooks = made(rule, file: file, installed: ["com.example.chat": "ABCDE12345"])
    #expect(hooks.sender("com.example.chat@ZZZZZ99999")?.vouched == false)
    #expect(hooks.routeLink("https://x/", app: hooks.sender("com.example.chat@ZZZZZ99999")) == nil)
    #expect(hooks.status().appProblems.contains { $0.contains("ZZZZZ99999") && $0.contains("ABCDE12345") })
    #expect(hooks.sender("com.example.chat@ABCDE12345")?.vouched == true)
    #expect(hooks.routeLink("https://x/", app: hooks.sender("com.example.chat@ABCDE12345"))?.profile == "Work")
    #expect(hooks.status().appTeams == [HookAppTeam(identifier: "com.example.chat", team: "ABCDE12345")])
    #expect(HookSenderTeams(file: file).team(of: "com.example.chat") == "ABCDE12345")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(hooks.sender("com.other.app@ABCDE12345")?.vouched == false)
    #expect(HookSenderTeams(file: file).team(of: "com.other.app") == nil)
    hooks.forgetAppTeam("com.example.chat")
    #expect(HookSenderTeams(file: file).team(of: "com.example.chat") == nil)
    #expect(hooks.status().appTeams.isEmpty)
  }

  @Test func withNoInstalledCopyNothingIsVouched() throws {
    let hooks = made(#"{"hooks": [{"name": "o", "match": {"apps": ["com.example.chat"]}, "openIn": {"profile": "Work"}}]}"#)
    #expect(hooks.sender("com.example.chat@ABCDE12345")?.vouched == false)
    #expect(hooks.status().appTeams.isEmpty)
    #expect(hooks.status().appProblems.contains { $0.contains("no installed copy") })
  }

  @Test func appleNamesNeedApplesOwnSignature() throws {
    let hooks = made(#"{"hooks": [{"name": "m", "match": {"apps": ["com.apple.mail"]}, "openIn": {"profile": "Work"}}]}"#)
    #expect(hooks.sender("com.apple.mail@apple")?.vouched == true)
    #expect(hooks.sender("com.apple.mail@ABCDE12345") == nil)
    #expect(hooks.sender("com.apple.mail") == nil)
    #expect(hooks.sender(nil) == nil)
  }

  @Test func aPinnedTeamAppliesOnlyToItsOwnRule() throws {
    let hooks = made(
      #"{"hooks": [{"name": "pinned", "match": {"apps": ["com.example.chat"], "team": "ZZZZZ99999", "hosts": ["p.example"]}, "block": true}, {"name": "o", "match": {"apps": ["com.example.chat"]}, "openIn": {"profile": "Work"}}]}"#,
      installed: ["com.example.chat": "ABCDE12345"])
    let other = hooks.sender("com.example.chat@ZZZZZ99999")
    #expect(hooks.blocksLink("https://p.example/", app: other, profile: nil) == "pinned")
    #expect(hooks.routeLink("https://x/", app: other) == nil)
    let real = hooks.sender("com.example.chat@ABCDE12345")
    #expect(hooks.blocksLink("https://p.example/", app: real, profile: nil) == nil)
    #expect(hooks.routeLink("https://x/", app: real)?.profile == "Work")
  }
}
#endif
