import Foundation
import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct TabMenuPlanTests {
  static func cases() throws -> [JSONObject] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Cases/tab-menu.json")
    return try JSONValue.parse(Data(contentsOf: path))["cases"]?.array?.compactMap(\.object) ?? []
  }

  static func canonical(_ value: JSONValue) -> JSONValue {
    if let object = value.object {
      return .object(JSONObject(object.keys.sorted().map { ($0, canonical(object[$0]!)) }))
    }
    if let array = value.array { return .array(array.map(canonical)) }
    return value
  }

  @Test func sharedCasesMatchTheJavaScriptPlanner() throws {
    let cases = try Self.cases()
    #expect(cases.count >= 12)
    for fixture in cases {
      let state = try BrowserState(stateJSON: fixture["state"]?.object ?? [:])
      let calendar = fixture["context"]?["calendarItem"].map(TabMenuItem.init(json:))
      let got = TabMenuPlan.items(state, windowId: fixture["windowId"]?.string ?? "", tabId: fixture["tabId"]?.string ?? "", calendarItem: calendar)
      let actual = got.map { JSONValue.array($0.map(\.json)) } ?? .null
      let matches = Self.canonical(actual) == Self.canonical(fixture["items"] ?? .null)
      #expect(matches, "\(fixture["name"]?.string ?? "?")")
    }
  }

  @Test func sharedMultiCasesMatchTheJavaScriptPlanner() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Cases/multi-tab-menu.json")
    let cases = try #require(try JSONValue.parse(Data(contentsOf: path))["cases"]?.array)
    #expect(cases.count >= 12)
    for fixture in cases {
      let state = try BrowserState(stateJSON: fixture["state"]?.object ?? [:])
      let window = fixture["windowId"]?.string ?? ""
      let ids = fixture["ids"]?.array?.compactMap(\.string) ?? []
      let folders = (fixture["folders"]?.array ?? []).map(TabMenuItem.init(json:))
      let items = TabMenuPlan.multiItems(state, windowId: window, ids: ids, folders: folders)
      #expect(Self.canonical(.array(items.map(\.json))) == Self.canonical(fixture["items"] ?? .null), "\(fixture["name"]?.string ?? "?")")
      for (choice, expected) in fixture["commands"]?.object ?? [:] {
        let command = TabMenuPlan.multiCommand(choice, windowId: window, ids: ids, state: state)
        #expect(Self.canonical(command?.json ?? .null) == Self.canonical(expected), "\(choice)")
      }
    }
  }

  @Test(arguments: ["pin", "pinRows", "duplicate", "newGroup", "group", "ungroup", "window", "window:new"])
  func selectionChoicesCommitOnceClearSelectionAndRestore(_ choice: String) throws {
    let f = try Self.fixture()
    var picked = choice
    if choice == "group" || choice == "ungroup" {
      let id = try #require(try f.store.dispatch(Command("groupTabs", [[.string(f.ids[0])], ["pinned": false]])).result?.string)
      if choice == "group" { picked = "group:\(id)" }
    }
    if choice == "window" { picked = "window:\(f.otherWindow)" }
    let ids = JSONValue.array(f.ids.map(JSONValue.string))
    try f.store.dispatch(Command("setSelection", [.string(f.window), ids]))
    let before = Self.snapshot(f.store.state)
    let count = f.store.state.tabs.count
    let rev = f.store.deliveryCursor().committed
    let command = try #require(TabMenuPlan.multiCommand(picked, windowId: f.window, ids: f.ids, state: f.store.state))
    let commit = try f.store.dispatch(command, origin: .native)
    #expect(f.store.deliveryCursor().committed == rev + 1)
    #expect(commit.commands == [command])
    #expect(f.store.state.selection[f.window]?.ids.isEmpty != false)
    switch choice {
    case "duplicate":
      #expect(f.store.state.tabs.count == count + 3)
      for id in f.ids {
        #expect(f.store.state.tabs.values.filter { $0.url == f.store.state.tabs[id]?.url }.count == 2)
      }
    case "pin", "pinRows":
      #expect(f.ids.allSatisfy { f.store.state.tabs[$0]?.pinned == true })
      #expect(f.ids.allSatisfy { f.store.state.tabs[$0]?.isPinnedRow == (choice == "pinRows") })
    case "newGroup":
      let group = try #require(commit.result?.string)
      #expect(f.store.state.groups[group]?.tabIds == f.ids)
    case "group":
      #expect(f.store.state.groups[String(picked.dropFirst(6))]?.tabIds == f.ids)
    case "ungroup":
      #expect(f.ids.allSatisfy { Groups.innermostGroupOf(f.store.state.groups, $0) == nil })
    default:
      let target = try #require(commit.result?.string)
      #expect(f.ids.allSatisfy { f.store.state.tabs[$0]?.windowId == target })
      #expect(f.store.state.ui.focusedWindowId == target)
      #expect(f.store.state.activeTabId(target) == (choice == "window:new" ? f.ids.first : f.ids.last))
    }
    try f.store.dispatch(Command("applyState", [.object(before)]))
    #expect(Self.snapshot(f.store.state) == before)
  }

  @Test func selectionGroupExcludesTilesAndWindowMoveMatchesSwitchToTab() throws {
    let f = try Self.fixture()
    try f.store.dispatch(Command("pinTabs", [[.string(f.ids[0])], true, false]))
    let group = try #require(try f.store.dispatch(Command("tabMenuSelection", [.string(f.window), .array(f.ids.map(JSONValue.string)), "newGroup"])).result?.string)
    #expect(f.store.state.groups[group]?.tabIds == Array(f.ids.dropFirst()))
    let otherActive = try #require(f.store.state.activeTabId(f.otherWindow))
    try f.store.dispatch(Command("openPeek", [.string(otherActive), "https://peek.example/"]))
    let before = f.store.state
    let expected = makeStore(before)
    try expected.dispatch(Command("moveTabsToWindow", [.array(f.ids.map(JSONValue.string)), .string(f.otherWindow)]))
    let active = expected.state.windows[f.otherWindow]?.activeTabIds[before.tabs[f.ids[0]]!.profileId] ?? f.ids[0]
    try expected.dispatch(Command("activate", [.string(active)]))
    try expected.dispatch(Command("setFocusedWindow", [.string(f.otherWindow)]))
    try f.store.dispatch(Command("tabMenuSelection", [.string(f.window), .array(f.ids.map(JSONValue.string)), .string("window:\(f.otherWindow)")]))
    func normalized(_ state: BrowserState) -> JSONObject {
      var snapshot = Self.snapshot(state)
      var tabs = snapshot["tabs"]?.object ?? [:]
      for id in tabs.keys {
        var tab = tabs[id]?.object ?? [:]
        if var navigation = tab["navigation"]?.object {
          navigation["seq"] = 0
          tab["navigation"] = .object(navigation)
        }
        tabs[id] = .object(tab)
      }
      snapshot["tabs"] = .object(tabs)
      return snapshot
    }
    #expect(normalized(f.store.state) == normalized(expected.state))
  }

  struct Fixture {
    var store: Store
    var window: String
    var otherWindow: String
    var profile: String
    var ids: [String]
  }

  static func fixture() throws -> Fixture {
    let store = makeStore()
    try store.dispatch(Command("updateSettings", [["newTabOpens": "page", "newTabPosition": "bottom", "cmdClickCreatesTabGroup": false, "warnBeforeMovingTabsToProfile": false]]))
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result?.string)
    var ids = [try #require(store.state.activeTabId(window))]
    for url in ["https://b.example/", "https://c.example/"] {
      ids.append(try #require(try store.dispatch(Command("newTab", [.string(window), ["url": .string(url)]])).result?.string))
    }
    let other = try #require(try store.dispatch(Command("createWindow", [["url": "https://other.example/"]])).result?.string)
    let profile = try #require(try store.dispatch(Command("createProfile", [["name": "Work"]])).result?.string)
    try store.dispatch(Command("activate", [.string(ids[1])]))
    try store.dispatch(Command("setFocusedWindow", [.string(window)]))
    return Fixture(store: store, window: window, otherWindow: other, profile: profile, ids: ids)
  }

  static func snapshot(_ state: BrowserState) -> JSONObject {
    var result = state.stateJSON
    for key in ["live", "find", "selection", "selectionAnchors", "windowUi"] { result.removeValue(forKey: key) }
    return result
  }

  static func runAndRestore(_ choice: String, _ fixture: Fixture, check: (Commit) throws -> Void) throws {
    let store = fixture.store
    let before = snapshot(store.state)
    let rev = store.deliveryCursor().committed
    let command = try #require(TabMenuPlan.command(choice, windowId: fixture.window, tabId: fixture.ids[1], state: store.state))
    let commit = try store.dispatch(command, origin: .native)
    #expect(store.deliveryCursor().committed == rev + 1, "\(choice) is one commit")
    #expect(commit.commands == [command])
    try check(commit)
    try store.dispatch(Command("applyState", [.object(before)]), origin: .native)
    #expect(snapshot(store.state) == before, "one restore reverses \(choice)")
  }

  @Test(arguments: ["pin", "pinTile", "pinRow", "unpinMember"])
  func pinChoicesCommitOnceAndOneRestoreUndoesThem(_ choice: String) throws {
    let f = try Self.fixture()
    if choice == "unpinMember" {
      try f.store.dispatch(Command("groupTabs", [[.string(f.ids[1]), .string(f.ids[2])], ["pinned": true]]))
    }
    try Self.runAndRestore(choice, f) { _ in
      let tab = try #require(f.store.state.tabs[f.ids[1]])
      #expect(tab.pinned == (choice != "unpinMember"))
      #expect(tab.isPinnedRow == (choice == "pinRow"))
      #expect(Groups.innermostGroupOf(f.store.state.groups, tab.id) == nil)
    }
  }

  @Test(arguments: [false, true])
  func pinToggleUnpinsTilesAndRowsInOneRestorableCommit(_ row: Bool) throws {
    let f = try Self.fixture()
    let id = f.ids[1]
    try f.store.dispatch(Command("pinTabs", [[.string(id)], true, .bool(row)]))
    try Self.runAndRestore("pin", f) { _ in
      #expect(f.store.state.tabs[id]?.pinned == false)
      #expect(f.store.state.tabs[id]?.isPinnedRow == false)
    }
  }

  @Test func aSharedEngineProfileMoveSkipsTheWarningAndRestoresOnce() throws {
    let f = try Self.fixture()
    try f.store.dispatch(Command("updateSettings", [["warnBeforeMovingTabsToProfile": true]]))
    try f.store.dispatch(Command("updateProfile", [.string(f.profile), ["dataId": "default"]]))
    try Self.runAndRestore("profile:\(f.profile)", f) { _ in
      #expect(f.store.state.tabs[f.ids[1]]?.profileId == f.profile)
      #expect(f.store.state.windows[f.window]?.profileId == f.profile)
      #expect(f.store.state.activeTabId(f.window) == f.ids[1])
    }
  }

  @Test(arguments: ["newGroup", "group", "ungroupTab"])
  func groupChoicesCommitOnceAndOneRestoreUndoesThem(_ choice: String) throws {
    let f = try Self.fixture()
    var target: String?
    if choice == "group" {
      target = try #require(try f.store.dispatch(Command("groupTabs", [[.string(f.ids[0])], ["pinned": false]])).result?.string)
    } else if choice == "ungroupTab" {
      try f.store.dispatch(Command("groupTabs", [[.string(f.ids[1]), .string(f.ids[2])], ["pinned": false]]))
    }
    try Self.runAndRestore(target.map { "group:\($0)" } ?? choice, f) { commit in
      let group = Groups.innermostGroupOf(f.store.state.groups, f.ids[1])
      if choice == "ungroupTab" { #expect(group == nil) }
      else {
        #expect(group != nil)
        #expect(group?.tabIds.contains(f.ids[1]) == true)
        if let target { #expect(group?.id == target) }
        else { #expect(group?.id == commit.result?.string) }
      }
    }
  }

  @Test(arguments: ["window", "window:new", "profile"])
  func moveChoicesKeepTheirIdentitySelectTheirDestinationAndUndoOnce(_ choice: String) throws {
    let f = try Self.fixture()
    let id = f.ids[1]
    let before = try #require(f.store.state.tabs[id])
    let command = choice == "window" ? "window:\(f.otherWindow)" : choice == "profile" ? "profile:\(f.profile)" : choice
    try Self.runAndRestore(command, f) { commit in
      let moved = try #require(f.store.state.tabs[id])
      #expect(moved.id == before.id)
      #expect(moved.url == before.url)
      if choice == "profile" {
        #expect(moved.profileId == f.profile)
        #expect(moved.windowId == f.window)
        #expect(f.store.state.windows[f.window]?.profileId == f.profile)
        #expect(f.store.state.activeTabId(f.window) == id)
      } else {
        let destination = try #require(commit.result?.string)
        #expect(moved.windowId == destination)
        #expect(f.store.state.ui.focusedWindowId == destination)
        #expect(f.store.state.activeTabId(destination) == id)
        #expect(moved.navigation?.url == before.url)
        #expect(moved.navigation?.seq != before.navigation?.seq)
      }
    }
  }

  @Test(arguments: ["duplicate", "mute", "resetName", "resetIcon", "backToPin", "replacePin", "unsplit", "closeOthers", "closeAbove", "closeBelow"])
  func simpleChoicesCommitOnceAndOneRestoreUndoesThem(_ choice: String) throws {
    let f = try Self.fixture()
    let id = f.ids[1]
    if ["backToPin", "replacePin"].contains(choice) {
      try f.store.dispatch(Command("pinTabs", [[.string(id)], true, true]))
      try f.store.dispatch(Command("updateTab", [.string(id), ["pinnedUrl": "https://pin.example/"]]))
    }
    if choice == "resetName" { try f.store.dispatch(Command("updateTab", [.string(id), ["customTitle": "Mine"]])) }
    if choice == "resetIcon" { try f.store.dispatch(Command("updateTab", [.string(id), ["customIcon": "star"]])) }
    if choice == "unsplit" { try f.store.dispatch(Command("createSplit", [[.string(id), .string(f.ids[2])]])) }
    let tabs = f.store.state.tabs.count
    try Self.runAndRestore(choice, f) { _ in
      let state = f.store.state
      switch choice {
      case "duplicate": #expect(state.tabs.count == tabs + 1)
      case "mute": #expect(state.tabs[id]?.muted == true)
      case "resetName": #expect(state.tabs[id]?.customTitle == nil)
      case "resetIcon": #expect(state.tabs[id]?.customIcon == nil)
      case "backToPin": #expect(state.tabs[id]?.navigation?.url == "https://pin.example/")
      case "replacePin": #expect(state.tabs[id]?.pinnedUrl == "https://b.example/")
      case "unsplit": #expect(Splits.splitOf(state, id) == nil)
      case "closeOthers": #expect(state.tabs[f.ids[0]] == nil && state.tabs[f.ids[2]] == nil)
      case "closeAbove": #expect(state.tabs[f.ids[0]] == nil && state.tabs[f.ids[2]] != nil)
      case "closeBelow": #expect(state.tabs[f.ids[0]] != nil && state.tabs[f.ids[2]] == nil)
      default: Issue.record("unknown choice")
      }
    }
  }

  @Test(arguments: [false, true])
  func splitAndPlayingMovesUseExistingNavigationAndLiveNormalizationAndRestoreOnce(_ profile: Bool) throws {
    let f = try Self.fixture()
    let id = f.ids[1]
    try f.store.dispatch(Command("createSplit", [[.string(id), .string(f.ids[2])]]))
    var state = f.store.state
    state.live[id] = PageLiveFacts(playingAudio: true)
    let store = makeStore(state)
    let before = try #require(store.state.tabs[id])
    let saved = Self.snapshot(store.state)
    let choice = profile ? "profile:\(f.profile)" : "window:\(f.otherWindow)"
    let command = try #require(TabMenuPlan.command(choice, windowId: f.window, tabId: id, state: state))
    let rev = store.deliveryCursor().committed
    try store.dispatch(command)
    #expect(store.deliveryCursor().committed == rev + 1)
    #expect(Splits.splitOf(store.state, id) == nil)
    #expect(store.state.tabs[f.ids[2]]?.windowId == f.window)
    #expect(store.state.tabs[id]?.navigation?.url == before.url)
    #expect(store.state.tabs[id]?.navigation?.seq != before.navigation?.seq)
    #expect(store.state.live[id]?.playingAudio == true)
    try store.dispatch(Command("applyState", [.object(saved)]))
    #expect(Self.snapshot(store.state) == saved)
  }

  @Test func choicesNeedingJavaScriptUiKeepTheirFallback() throws {
    let f = try Self.fixture()
    try f.store.dispatch(Command("updateSettings", [["warnBeforeMovingTabsToProfile": true]]))
    for choice in ["copy", "share:via:service", "rename", "icon", "editPin", "bookmark", "engine", "cal:settings", "newFolder", "leaveFolder", "profile:new", "profile:\(f.profile)", "close"] {
      #expect(TabMenuPlan.command(choice, windowId: f.window, tabId: f.ids[1], state: f.store.state) == nil, "\(choice)")
    }
    try f.store.dispatch(Command("updateProfile", [.string(f.profile), ["dataId": "default"]]))
    #expect(TabMenuPlan.command("profile:\(f.profile)", windowId: f.window, tabId: f.ids[1], state: f.store.state)?.name == "moveTabToProfile")
  }
}
