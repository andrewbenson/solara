import Foundation
import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct PinnedRowsTests {
  static func cases() throws -> [JSONObject] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Cases/pinned-rows.json")
    return try JSONValue.parse(Data(contentsOf: url))["cases"]?.array?.compactMap(\.object) ?? []
  }

  static func freshStore() throws -> Store {
    let store = makeStore()
    try store.dispatch(Command("updateSettings", [["newTabOpens": "page", "newTabPosition": "bottom", "cmdClickCreatesTabGroup": false]]))
    return store
  }

  static func host(_ url: String) -> String {
    guard url.hasPrefix("https://"), url.hasSuffix(".com/") else { return url }
    return String(url.dropFirst("https://".count).dropLast(".com/".count))
  }

  static func hosts(_ store: Store, _ window: String, _ keep: (Tab) -> Bool) throws -> [String] {
    try #require(store.state.windows[window], "window \(window)").tabIds.compactMap { store.state.tabs[$0] }.filter(keep).map { host($0.url) }
  }

  struct Refs {
    var ids: [String: String] = [:]

    func resolve(_ value: JSONValue) throws -> JSONValue {
      if let text = value.string, text.hasPrefix("$") {
        return .string(try #require(ids[String(text.dropFirst())], "unknown \(text)"))
      }
      if let list = value.array { return .array(try list.map(resolve)) }
      if let object = value.object {
        var out: JSONObject = [:]
        for (key, item) in object { out[key] = try resolve(item) }
        return .object(out)
      }
      return value
    }

    func id(_ key: String) throws -> String { try #require(try resolve(.string(key)).string) }
  }

  static func run(_ steps: [JSONValue], _ store: Store, _ name: String) throws {
    var refs = Refs()
    for step in steps.compactMap(\.object) {
      if let hosts = step["window"]?.array?.compactMap(\.string) {
        let window = try #require(try store.dispatch(Command("createWindow", [["url": .string("https://\(hosts[0]).com/")]])).result?.string)
        var ids = [store.state.windows[window]!.tabIds[0]]
        for host in hosts.dropFirst() {
          ids.append(try #require(try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://\(host).com/")]])).result?.string))
        }
        try store.dispatch(Command("activate", [.string(ids[0])]))
        refs.ids[step["as"]!.string!] = window
        for (host, id) in zip(hosts, ids) where refs.ids[host] == nil { refs.ids[host] = id }
      } else if let members = step["group"] {
        let group = try store.dispatch(Command("groupTabs", [try refs.resolve(members), ["pinned": false]])).result?.string
        refs.ids[step["as"]!.string!] = try #require(group)
      } else if let window = step["rowIn"]?.string {
        let row = store.state.windows[try refs.id(window)]?.tabIds.first { store.state.tabs[$0]?.pinnedAsRow == true }
        refs.ids[step["as"]!.string!] = try #require(row)
      } else if let hosts = step["tabs"]?.array?.compactMap(\.string), let window = step["in"]?.string {
        for host in hosts {
          refs.ids[host] = try #require(try store.dispatch(Command("newTab", [.string(try refs.id(window)), ["url": .string("https://\(host).com/")]])).result?.string)
        }
      } else if let call = step["call"]?.string {
        let commit = try store.dispatch(Command(call, try refs.resolve(step["args"] ?? .array([])).array ?? []))
        if let name = step["as"]?.string { refs.ids[name] = try #require(commit.result?.string) }
      } else if let window = step["toggle"]?.string {
        try store.dispatch(Command("togglePinnedRows", [.string(try refs.id(window))]))
      } else if let expect = step["expect"]?.object {
        for (window, want) in expect["rows"]?.object ?? [:] {
          #expect(try hosts(store, try refs.id(window), \.isPinnedRow) == want.array?.compactMap(\.string), "\(name): rows of \(window)")
        }
        for (window, want) in expect["list"]?.object ?? [:] {
          #expect(try hosts(store, try refs.id(window)) { !$0.pinned } == want.array?.compactMap(\.string), "\(name): list of \(window)")
        }
        for (group, want) in expect["groupTabs"]?.object ?? [:] {
          #expect(store.state.groups[try refs.id(group)]?.tabIds == (try refs.resolve(want)).array?.compactMap(\.string), "\(name): tabs of \(group)")
        }
        for (tab, want) in expect["pinned"]?.object ?? [:] {
          #expect(store.state.tabs[try refs.id(tab)]?.pinned == want.truthy, "\(name): \(tab) pinned")
        }
        for (tab, want) in expect["grouped"]?.object ?? [:] {
          #expect((Groups.innermostGroupOf(store.state.groups, try refs.id(tab)) != nil) == want.truthy, "\(name): \(tab) grouped")
        }
      } else {
        Issue.record("\(name): unknown step \(step)")
      }
    }
  }

  @Test func theSharedCasesRunAsInJavaScript() throws {
    let cases = try Self.cases()
    #expect(cases.count >= 15)
    for c in cases {
      try Self.run(c["steps"]?.array ?? [], try Self.freshStore(), c["name"]?.string ?? "?")
    }
  }

  @Test func oneMoveOutIsOneCommitAndOneRestoreUndoesAllOfIt() throws {
    let store = try Self.freshStore()
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://a.com/"]])).result?.string)
    var ids = [store.state.windows[window]!.tabIds[0]]
    for host in ["b", "c", "d"] {
      ids.append(try #require(try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://\(host).com/")]])).result?.string))
    }
    try store.dispatch(Command("activate", [.string(ids[1])]))
    try store.dispatch(Command("setSelection", [.string(window), [.string(ids[1]), .string(ids[2])]]))
    try store.dispatch(Command("togglePinnedRows", [.string(window)]))
    #expect(try Self.hosts(store, window, \.isPinnedRow) == ["b", "c"])

    let pinned = store.state.stateJSON
    try store.dispatch(Command("activate", [.string(ids[1])]))
    try store.dispatch(Command("setSelection", [.string(window), [.string(ids[1]), .string(ids[2])]]))
    let beforeMoveOut = store.deliveryCursor().committed
    try store.dispatch(Command("togglePinnedRows", [.string(window)]))
    #expect(store.deliveryCursor().committed == beforeMoveOut + 1, "the whole Move out is one commit")
    #expect(try Self.hosts(store, window) { !$0.pinned } == ["a", "b", "c", "d"])

    var restore: JSONObject = [:]
    for key in ["tabs", "windows", "groups"] { restore[key] = pinned[key] }
    try store.dispatch(Command("applyState", [.object(restore)]))
    #expect(try Self.hosts(store, window, \.isPinnedRow) == ["b", "c"], "one step brings both rows back")
    #expect(try Self.hosts(store, window) { !$0.pinned } == ["a", "d"])
  }

  @Test func inABatchMoveOutOfPinnedFromAnotherWindowStillRestoresTheFirstWindowsTab() throws {
    let store = try Self.freshStore()
    let w = try #require(try store.dispatch(Command("createWindow", [["url": "https://a.com/"]])).result?.string)
    var ids = [store.state.windows[w]!.tabIds[0]]
    for host in ["b", "c"] {
      ids.append(try #require(try store.dispatch(Command("newTab", [.string(w), ["url": .string("https://\(host).com/")]])).result?.string))
    }
    try store.dispatch(Command("activate", [.string(ids[1])]))
    try store.dispatch(Command("togglePinnedRows", [.string(w)]))
    let w2 = try #require(try store.dispatch(Command("createWindow", [["url": "https://other.com/"]])).result?.string)
    let copy = try #require(store.state.windows[w2]?.tabIds.first { store.state.tabs[$0]?.pinnedAsRow == true })
    try store.dispatch([Command("activate", [.string(copy)]), Command("setSelection", [.string(w2), []]), Command("togglePinnedRows", [.string(w2)])])
    #expect(store.state.tabs[ids[1]]?.pinned == false)
    #expect(try Self.hosts(store, w) { !$0.pinned } == ["a", "b", "c"])
    #expect(try Self.hosts(store, w2, \.isPinnedRow) == [])
  }

  @Test func theMenuCommandRunsOnTheMainWindowFromLittleSolaraAndLeavesAvailabilityToTheMenu() throws {
    let store = try Self.freshStore()
    let main = try #require(try store.dispatch(Command("createWindow", [["url": "https://a.com/"]])).result?.string)
    let small = try #require(try store.dispatch(Command("createWindow", [["url": "https://b.com/", "small": true]])).result?.string)
    #expect(WorkspaceMenuCommand.plan("togglePinnedRow", windowId: main, state: store.state)?.commands == [Command("togglePinnedRows", [.string(main)])])
    #expect(store.state.windows[small]?.isSmall == true)
    let redirected = WorkspaceMenuCommand.plan("togglePinnedRow", windowId: small, state: store.state)
    #expect(redirected?.commands == [Command("togglePinnedRows", [.string(main)])])
    #expect(redirected?.focusWindow == main)
    #expect(WorkspaceMenuCommand.available("togglePinnedRow", windowId: main, state: store.state) == nil)
  }

  @Test func theMenuCommandRoutesUtilityWindowsPeekAndNoWindowLikeJavaScript() throws {
    let empty = try Self.freshStore()
    #expect(WorkspaceMenuCommand.plan("togglePinnedRow", windowId: nil, state: empty.state) == WorkspaceMenuPlan())
    #expect(WorkspaceMenuCommand.plan("togglePinnedRow", windowId: "settings", state: empty.state) == WorkspaceMenuPlan())

    let store = try Self.freshStore()
    let main = try #require(try store.dispatch(Command("createWindow", [["url": "https://a.com/"]])).result?.string)
    try store.dispatch(Command("setFocusedWindow", [.string(main)]))
    let toggle = [Command("togglePinnedRows", [.string(main)])]
    for utility in ["settings", "import"] {
      let plan = WorkspaceMenuCommand.plan("togglePinnedRow", windowId: utility, state: store.state)
      #expect(plan?.commands == toggle, "\(utility)")
      #expect(plan?.focusWindow == nil, "\(utility)")
    }
    let source = try #require(store.state.windows[main]?.tabIds.first)
    try store.dispatch(Command("openPeek", [.string(source), "https://peek.com/"]))
    #expect(store.state.peeks[main] != nil)
    #expect(WorkspaceMenuCommand.plan("togglePinnedRow", windowId: main, state: store.state)?.commands == toggle)
  }
}
