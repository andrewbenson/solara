import Foundation
import SolaraModel
@testable import SolaraStore
import Synchronization
import Testing

struct PageReportGoldenTests {
  @Test func stepFourGoldenRunsThroughStoreIngress() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/page-events.json")
    let fixture = try JSONValue.parse(Data(contentsOf: path))
    for spec in try #require(fixture["cases"]?.array) {
      let initial = spec["initial"]
      var tab: JSONObject = ["id": "t", "windowId": "w", "profileId": "p", "url": "", "title": "", "favicon": .null]
      for (key, value) in initial?["tab"]?.object ?? [:] { tab[key] = value }
      tab["engine"] = spec["engine"] ?? "chromium"
      var state = BrowserState(settings: Settings.hydrated(from: nil))
      state.profiles["p"] = Profile(id: "p", name: "P", color: "blue", icon: nil, createdAt: 0)
      state.profileOrder = ["p"]
      state.tabs["t"] = try Tab(json: tab)
      state.tabs["other"] = Tab(id: "other", windowId: "w", profileId: "p", url: "https://other.test/", now: 0)
      for id in ["w", "w2"] {
        var window = BrowserWindow(id: id, profileId: "p", incognito: false, frame: nil, createdAt: 0)
        window.tabIds = id == "w" ? ["t", "other"] : []
        window.activeTabIds["p"] = id == "w" ? "other" : "t"
        state.windows[id] = window
      }
      state.windowOrder = ["w", "w2"]
      if let live = initial?["live"]?.object { state.live["t"] = try PageLiveFacts(json: live) }
      var config = StoreConfig()
      config.listeners = []
      let now = Mutex<Double>(0)
      var memory = StoreMemory()
      memory.navSeq = tab["navigation"]?["seq"]?.int ?? 0
      let store = Store(state: state, memory: memory, config: config, checksInvariants: false, clock: { now.withLock { $0 } })
      let pooled = spec["pooled"]?.bool ?? false
      let page = initial?["page"]
      var created: JSONObject = ["type": "created", "generation": "golden", "navigationSeq": tab["navigation"]?["seq"] ?? .null, "contextRevision": 0, "engine": spec["engine"] ?? "chromium",
        "wasNewTab": page?["wasNewTab"] ?? false, "newTabShownUrl": page?["newTabShown"]?["url"] ?? .null]
      created["handoffSeq"] = spec["handoff"] ?? (pooled ? tab["navigation"]?["seq"] : nil) ?? .null
      store.enqueuePageReport(id: "t", report: .object(created))
      store.sequence {}
      if let live = initial?["live"]?.object {
        let seeded = try PageLiveFacts(json: live)
        try store.transact { session in
          session.memory.pages["t"]?.live = PageLive(facts: seeded)
          session.update { $0.live["t"] = seeded }
        }
      }
      if let themes = spec["themes"] { try store.dispatch(Command("pageReport", ["t", ["type": "restore", "themes": themes]])) }
      let loadingEdges = Mutex<[Bool]>([])
      let priorLoading = Mutex(store.state.live["t"]?.isLoading ?? false)
      let token = store.subscribe { commit in
        guard let live = commit.state.live["t"] else { return }
        let changed = priorLoading.withLock { previous in
          defer { previous = live.isLoading }
          return previous != live.isLoading
        }
        if changed { loadingEdges.withLock { $0.append(live.isLoading) } }
      }
      var goldenDiscarded = initial?["live"]?["discarded"]?.bool ?? false
      func expectedFacts(_ live: JSONObject) throws -> PageLiveFacts {
        var facts = try PageLiveFacts(json: live)
        if live["discarded"] == nil { facts.discarded = goldenDiscarded }
        return facts
      }
      var observations = (spec["writes"]?.array ?? []).filter { $0["kind"] == "observe" }
      func observe() throws {
        store.sequence {}
        let expected = try #require(observations.first)
        observations.removeFirst()
        let label = spec["name"]?.string ?? ""
        #expect(store.state.tabs["t"]?.url == expected["tab"]?["url"]?.string, "\(label) observed URL")
        if let live = expected["live"]?.object, store.state.tabs["t"] != nil {
          #expect(store.state.live["t"] == (try expectedFacts(live)), "\(label) observed live")
        }
        let window = store.state.tabs["t"]?.windowId ?? "w"
        #expect(store.state.windows[window]?.activeTabIds["p"] == expected["activeTabId"]?.string, "\(label) observed activation")
      }
      var shouldFollow = pooled
      var contextRevision = 0
      var issuedLoads: [JSONValue] = []
      func follow(_ startedEarly: Bool = false, moved: Bool = false) throws {
        contextRevision += 1
        let context = store.memory.pages["t"]
        let report: JSONValue = ["type": "issued", "generation": "golden",
          "navigationSeq": (store.state.tabs["t"]?.navigation).map { .number($0.seq) } ?? .null,
          "contextRevision": JSONValue(contextRevision), "wasNewTab": .bool(context?.wasNewTab ?? false),
          "newTabShownUrl": JSONValue(context?.newTabShownUrl),
          "navigation": store.state.tabs["t"]?.navigation?.jsonValue ?? .null,
          "startedEarly": .bool(startedEarly), "sameProfileMove": .bool(moved)]
        guard let prepared = try store.preparePooledIssue(id: "t", report: report) else {
          Issue.record("golden issue was refused")
          return
        }
        #expect(store.consumePooledIssue(id: "t", prepared: prepared))
        for action in prepared.actions.array ?? [] {
          if action["type"] == "load" {
            issuedLoads.append([action["url"] ?? .null, ["userInitiated": action["userInitiated"] ?? false]])
          }
          if action["type"] == "clearNewTabShown" { #expect(store.memory.pages["t"]?.newTabShownUrl == nil) }
        }
      }
      for step in spec["steps"]?.array ?? [] {
        switch step["op"]?.string {
        case "report":
          let name = step["name"]?.string ?? ""
          let mapping = ["onNavigationChange": "navigation", "onMedia": "media", "onDiscarded": "discarded", "onReady": "ready", "onDownloadNavigation": "download", "onLoadError": "failed"]
          var report = step["payload"]?.object ?? [:]
          report["type"] = .string(mapping[name] ?? "failed")
          report["generation"] = "golden"
          if name == "onNavigationChange" {
            for key in ["isLoading", "canGoBack", "canGoForward"] { if report[key] == nil { report[key] = false } }
          }
          if name == "onReady" {
            report["browserId"] = step["payload"]?.array?.first ?? .null
            report["tabId"] = step["payload"]?.array?.dropFirst().first ?? .null
          }
          if name == "onDiscarded" {
            report["url"] = step["payload"]
            goldenDiscarded = true
          }
          if name == "onReady" { goldenDiscarded = false }
          store.enqueuePageReport(id: "t", report: .object(report))
          if step["held"]?.bool != true { store.sequence {} }
        case "follow": try follow(step["startedEarly"]?.bool ?? false)
        case "flush":
          store.sequence {}
          if shouldFollow { try follow(); shouldFollow = false }
        case "navigate":
          try store.dispatch(Command("navigate", ["t", step["url"] ?? "", ["userInitiated": step["userInitiated"] ?? false]]))
          shouldFollow = pooled
          if !pooled { try follow() }
        case "activate": try store.dispatch(Command("activate", ["t"])); try observe()
        case "strip":
          try store.sequence { try store.dispatch(Command("activate", ["other"])) }; try observe()
        case "touch": try store.dispatch(Command("updateTab", ["t", ["title": step["title"] ?? ""]]))
        case "move":
          try store.dispatch(Command("updateTab", ["t", ["windowId": "w2", "navigation": ["seq": step["seq"] ?? 0, "url": step["url"] ?? ""]]]))
          try follow(moved: true)
        case "tick":
          now.withLock { $0 = step["now"]?.number ?? 0 }
          try store.dispatch(Command("pageReport", ["t", ["type": "advance", "generation": "golden"]]))
        case "observe": try observe()
        default: Issue.record("unknown golden operation")
        }
      }
      store.sequence {}
      store.unsubscribe(token)
      #expect(observations.isEmpty)
      let expectedLoads = (spec["writes"]?.array ?? []).filter { $0["kind"] == "handle" && $0["method"] == "loadUrl" }.compactMap { $0["args"] }
      #expect(issuedLoads == expectedLoads, "\(spec["name"]?.string ?? "") load and overlay decisions")
      var expectedLoading = initial?["live"]?["isLoading"]?.bool ?? false
      var expectedEdges: [Bool] = []
      for entry in spec["writes"]?.array ?? [] where entry["kind"] == "subscriber" && entry["tab"]?.isNull != true {
        if let loading = entry["live"]?["isLoading"]?.bool, loading != expectedLoading {
          expectedEdges.append(loading)
          expectedLoading = loading
        }
      }
      #expect(loadingEdges.withLock { $0 } == expectedEdges, "\(spec["name"]?.string ?? "") loading subscriber edges")
      let expected = (spec["writes"]?.array ?? []).last { $0["kind"] == "subscriber" || $0["kind"] == "observe" }
      let label = spec["name"]?.string ?? ""
      if let expectedTab = expected?["tab"], !expectedTab.isNull {
        let expectedURL = expectedTab["url"]?.string == "" ? expectedTab["navigation"]?["url"]?.string ?? "" : expectedTab["url"]?.string
        #expect(store.state.tabs["t"]?.url == expectedURL, "\(label) URL")
        #expect(store.state.tabs["t"]?.title == expectedTab["title"]?.string, "\(label) title")
        if let live = expected?["live"]?.object {
          #expect(store.state.live["t"] == (try expectedFacts(live)), "\(label) facts")
        }
      } else if expected?["tab"]?.isNull == true {
        #expect(store.state.tabs["t"] == nil, "\(label) closed")
        #expect(store.state.live["t"] == nil, "\(label) pruned")
      }
    }
  }
}
