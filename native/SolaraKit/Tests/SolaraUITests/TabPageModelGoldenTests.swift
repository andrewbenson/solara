import Foundation
import SolaraModel
import SolaraUI
import Testing

struct TabPageModelGoldenTests {
  func canonical(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object): .object(JSONObject(object.keys.sorted().map { ($0, canonical(object[$0]!)) }))
    case .array(let array): .array(array.map(canonical))
    default: value
    }
  }

  @Test func replaysEveryOrderedJavaScriptEntry() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/page-events.json")
    let fixture = try JSONValue.parse(Data(contentsOf: path))
    let cases = try #require(fixture["cases"]?.array)
    #expect(fixture["version"] == 1)
    #expect(cases.count >= 12)
    for spec in cases {
      let replay = TabPageGoldenReplay(spec: spec)
      let actual = try replay.run()
      let expected = try #require(spec["writes"]?.array)
      #expect(actual.count == expected.count, "\(spec["name"]?.string ?? "") entry count")
      for index in 0..<max(actual.count, expected.count) {
        let got = canonical(index < actual.count ? actual[index] : .null)
        let wanted = canonical(index < expected.count ? expected[index] : .null)
        #expect(got == wanted, "\(spec["name"]?.string ?? "") entry \(index)")
      }
    }
  }
}

private final class TabPageGoldenReplay {
  let spec: JSONValue
  let pooled: Bool
  var tab: JSONObject?
  var page: JSONObject
  var model: TabPageModel
  var live: PageLive
  var entries: [JSONValue] = []
  var held: [JSONValue] = []
  var followQueued: Bool
  var pooledSeq: Int?
  var sessionAdoptId: JSONValue?
  var now = 0.0
  var sequence = 100
  var adoptedSequence = 0
  var activeTabIds: [String: String] = ["w": "other"]
  var activeTabId: String { activeTabIds[tab?["windowId"]?.string ?? "w"] ?? "" }

  init(spec: JSONValue) {
    self.spec = spec
    pooled = spec["pooled"]?.bool ?? false
    let initial = spec["initial"]
    var initialTab: JSONObject = ["id": "t", "windowId": "w", "profileId": "p", "url": "", "title": "", "favicon": .null]
    for (key, value) in initial?["tab"]?.object ?? [:] { initialTab[key] = value }
    tab = initialTab
    sessionAdoptId = initialTab["adoptId"]
    page = ["wasNewTab": false, "newTabShown": .null]
    for (key, value) in initial?["page"]?.object ?? [:] { page[key] = value }
    let facts = initial?["live"]
    live = PageLive(facts: PageLiveFacts(isLoading: facts?["isLoading"]?.bool ?? false, canGoBack: facts?["canGoBack"]?.bool ?? false, canGoForward: facts?["canGoForward"]?.bool ?? false, playingAudio: facts?["playingAudio"]?.bool ?? false, themeColor: facts?["themeColor"]?.string))
    let nav = Self.navigation(initialTab["navigation"])
    let handoff = spec["handoff"]?.int ?? (pooled ? nav?.seq : nil)
    model = TabPageModel(navigation: nav, adoptedUrl: initialTab["adoptId"]?.truthy == true ? initialTab["url"]?.string : nil, handoffSeq: handoff, webkitWithoutHandoff: spec["engine"]?.string == "webkit" && handoff == nil, wasNewTab: page["wasNewTab"]?.bool ?? false)
    followQueued = pooled
    pooledSeq = nav?.seq
  }

  static func navigation(_ value: JSONValue?) -> TabNavigationRequest? {
    guard let value, let seq = value["seq"]?.int, let url = value["url"]?.string else { return nil }
    return TabNavigationRequest(seq: seq, url: url, userInitiated: value["userInitiated"]?.bool ?? false)
  }

  func push(_ kind: String, _ fields: JSONObject = [:]) {
    var record = fields
    record["kind"] = .string(kind)
    entries.append(.object(record))
    if kind == "write" {
      entries.append(["kind": "subscriber", "tab": tab.map(JSONValue.object) ?? .null, "live": factsJSON, "activeTabId": .string(activeTabId)])
    }
  }

  func call(_ name: String, _ arguments: [JSONValue]) {
    push("call", ["name": .string(name), "args": .array(arguments)])
  }

  var factsJSON: JSONValue {
    guard let facts = live.facts else { return .null }
    return ["isLoading": .bool(facts.isLoading), "canGoBack": .bool(facts.canGoBack), "canGoForward": .bool(facts.canGoForward), "playingAudio": .bool(facts.playingAudio), "themeColor": JSONValue(facts.themeColor)]
  }

  func patchJSON(_ patch: PageLivePatch) -> JSONValue {
    var out = JSONObject()
    if let value = patch.isLoading { out["isLoading"] = .bool(value) }
    if let value = patch.canGoBack { out["canGoBack"] = .bool(value) }
    if let value = patch.canGoForward { out["canGoForward"] = .bool(value) }
    if let value = patch.playingAudio { out["playingAudio"] = .bool(value) }
    if let value = patch.themeColor { out["themeColor"] = JSONValue(value) }
    return .object(out)
  }

  func updatedLive(_ patch: PageLivePatch, before: PageLiveFacts?) {
    call("updateLive", ["t", patchJSON(patch)])
    if before != live.facts { push("write", ["live": factsJSON]) }
  }

  func updateTab(_ patch: JSONObject, livePatch: PageLivePatch? = nil, beforeLive: PageLiveFacts? = nil) {
    var arguments: [JSONValue] = ["t", .object(patch)]
    if let livePatch { arguments.append(patchJSON(livePatch)) }
    call("updateTab", arguments)
    guard var next = tab else { return }
    let before = next
    for (key, value) in patch { next[key] = value }
    tab = next
    var write = JSONObject()
    if next != before { write["tab"] = .object(next) }
    if livePatch != nil && beforeLive != live.facts { write["live"] = factsJSON }
    if !write.isEmpty { push("write", write) }
    if pooled { sessionAdoptId = next["adoptId"] }
    let nextSeq = Self.navigation(next["navigation"])?.seq
    if pooled && pooledSeq != nextSeq {
      pooledSeq = nextSeq
      if next["windowId"] != before["windowId"] { model.moved(sameProfile: next["profileId"] == before["profileId"]) }
      followQueued = true
    }
  }

  func follow(startedEarly: Bool = false) {
    let effects = model.issued(Self.navigation(tab?["navigation"]), newTabShown: page["newTabShown"]?.truthy ?? false, startedEarly: startedEarly)
    consume(effects)
  }

  func consume(_ effects: [TabPageEffect]) {
    for effect in effects {
      switch effect {
      case .load(let url, let initiated):
        push("handle", ["method": "loadUrl", "args": [.string(url), ["userInitiated": .bool(initiated)]]])
      case .clearNewTabShown:
        page["newTabShown"] = .null
      case .adoptNavigation(let url):
        adoptedSequence += 1
        updateTab(["navigation": ["url": .string(url), "seq": JSONValue(adoptedSequence)]])
      case .backToNewTab:
        page["backToNewTab"] = true
      case .stopLoading:
        let before = live.facts
        let patch = live.download()
        updatedLive(patch, before: before)
      case .updateURL(let url):
        updateTab(["url": .string(url)])
      case .closeTab:
        call("closeTab", ["t"])
        tab = nil
        push("write", ["tab": .null])
      case .resetToNewTab:
        page["backToNewTab"] = false
        page["newTabShown"] = .null
        updateTab(["url": "", "title": "", "favicon": .null])
      case .discarded:
        page["backToNewTab"] = false
        page["status"] = ""
        let before = live.facts
        let patch = live.discard()
        updatedLive(patch, before: before)
        push("lifecycle", ["value": "discarded"])
      case .ready:
        live.ready()
        push("lifecycle", ["value": "ready"])
      case .setMuted(let value):
        push("handle", ["method": "setMuted", "args": [.bool(value)]])
      case .markLoading, .keepNewTabShown, .navigated, .leftPage, .closeTabs:
        break
      }
    }
  }

  func navigationReport(_ payload: JSONValue) {
    let report = TabNavigationReport(url: payload["url"]?.string ?? "", title: payload["title"]?.string ?? "", isLoading: payload["isLoading"]?.bool ?? false, canGoBack: payload["canGoBack"]?.bool ?? false, canGoForward: payload["canGoForward"]?.bool ?? false, initialDocumentAccessed: payload["initialDocumentAccessed"]?.bool ?? false, committedInitial: payload["committedInitial"]?.bool)
    let context = TabPageContext(navigationUrl: tab?["navigation"]?["url"]?.string, prewarmOnly: tab?["navigation"]?.truthy != true && sessionAdoptId?.truthy != true, openedByAdoption: tab?["openerId"]?.truthy == true && sessionAdoptId?.truthy == true, newTabShownUrl: page["newTabShown"]?["url"]?.string)
    let effects = model.reported(report, context)
    for effect in effects {
      switch effect {
      case .markLoading:
        let before = live.facts
        let patch = live.markLoading()
        updatedLive(patch, before: before)
      case .keepNewTabShown(let title):
        var shown = page["newTabShown"]?.object ?? [:]
        shown["title"] = .string(title)
        page["newTabShown"] = .object(shown)
        let before = live.facts
        let patch = live.navigation(url: report.initialDocumentAccessed && report.committedInitial == true ? "about:blank" : report.url, isLoading: report.isLoading, canGoBack: report.canGoBack, canGoForward: report.canGoForward, themeColor: payload["themeColor"]?.string, now: now)
        updatedLive(patch, before: before)
      case .navigated(let url, let title, let loading, let back, let forward):
        let before = live.facts
        let patch = live.navigation(url: url, isLoading: loading, canGoBack: back, canGoForward: forward, themeColor: payload["themeColor"]?.string, now: now, tabExists: tab != nil)
        let pagePatch: JSONObject = ["url": .string(url), "title": .string(title)]
        call("navigated", ["t", .object(pagePatch), patchJSON(patch)])
        updateTab(pagePatch, livePatch: patch, beforeLive: before)
      default:
        consume([effect])
      }
    }
  }

  func report(_ step: JSONValue) throws {
    let payload = step["payload"] ?? .null
    switch step["name"]?.string {
    case "onNavigationChange": navigationReport(payload)
    case "onLoadError": model.loadFailed()
    case "onDownloadNavigation":
      let context = TabDownloadContext(tabExists: tab != nil, currentUrl: tab?["url"]?.string ?? "", hasOtherProfileTab: true, hasOpener: tab?["openerId"]?.truthy ?? false, hasAdoptId: tab?["adoptId"]?.truthy ?? false, wasNewTab: page["wasNewTab"]?.bool ?? false, canGoBack: live.facts?.canGoBack ?? false)
      consume(model.downloadNavigation(committedUrl: payload["committedUrl"]?.string, skipped: payload["skipped"]?.bool ?? false, context: context))
    case "onDiscarded": consume(model.discarded(payload.string ?? ""))
    case "onReady": consume(model.ready(muted: tab?["muted"]?.bool ?? false))
    case "onMedia":
      let before = live.facts
      let patch = live.media(playing: payload["playing"]?.bool ?? false)
      updatedLive(patch, before: before)
      if tab?["muted"]?.truthy == true && payload["muted"]?.truthy != true { consume([.setMuted(true)]) }
    default: throw GoldenReplayError.unsupported(step)
    }
  }

  func flush() throws {
    while !held.isEmpty { try report(held.removeFirst()) }
  }

  func microtasks() {
    while followQueued {
      followQueued = false
      follow()
    }
  }

  func observe() {
    push("observe", ["tab": tab.map(JSONValue.object) ?? .null, "live": factsJSON, "activeTabId": .string(activeTabId)])
  }

  func run() throws -> [JSONValue] {
    if let themes = spec["themes"]?.array {
      let before = live.facts
      let values = themes.filter { $0["tab"]?.string == "t" }.map { PageLiveRestoredTheme(page: $0["page"]?.string ?? "", color: $0["color"]?.string ?? "") }
      if live.restore(tabURL: tab?["url"]?.string, themes: values) != nil && before != live.facts { push("write", ["live": factsJSON]) }
    }
    for step in spec["steps"]?.array ?? [] {
      switch step["op"]?.string {
      case "report":
        if ["onNavigationChange", "onMedia", "onLoadError"].contains(step["name"]?.string ?? "") {
          held.append(step)
          if step["held"]?.bool != true { try flush() }
        } else { try flush(); try report(step) }
      case "flush": try flush(); microtasks()
      case "follow": follow(startedEarly: step["startedEarly"]?.bool ?? false)
      case "navigate":
        try flush()
        let url = step["url"]?.string ?? ""
        push("command", ["name": "navigate", "url": .string(url)])
        sequence += 1
        var navigation: JSONObject = ["seq": step["seq"] ?? JSONValue(sequence), "url": .string(url)]
        if step["userInitiated"]?.truthy == true { navigation["userInitiated"] = true }
        updateTab(["navigation": .object(navigation)])
        if !pooled { follow() }
      case "activate", "strip":
        try flush()
        push("command", ["name": step["op"]!])
        activeTabIds[tab?["windowId"]?.string ?? "w"] = step["op"]?.string == "activate" ? "t" : "other"
        push("write", ["activeTabId": .string(activeTabId)])
        observe()
      case "touch", "move":
        try flush()
        push("command", ["name": step["op"]!])
        if step["op"]?.string == "touch" { updateTab(["title": step["title"] ?? .null]) }
        else {
          activeTabIds["w2"] = "t"
          updateTab(["windowId": "w2", "navigation": ["seq": step["seq"] ?? .null, "url": step["url"] ?? .null]])
        }
      case "observe": observe()
      case "tick":
        now = step["now"]?.number ?? 0
        let before = live.facts
        if let patch = live.advance(to: now) { updatedLive(patch, before: before) }
      default: throw GoldenReplayError.unsupported(step)
      }
    }
    try flush()
    microtasks()
    return entries
  }
}

private enum GoldenReplayError: Error {
  case unsupported(JSONValue)
}
