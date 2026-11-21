import AppKit
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct WorkspaceActionRouterTests {
  func windowWithTabs(_ count: Int) throws -> (Store, String, [String]) {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: true)
    let window = try store.dispatch(Command("createWindow")).result!.string!
    for _ in 1..<count { try store.dispatch(Command("newTab", [.string(window)])) }
    return (store, window, store.state.windows[window]!.tabIds)
  }

  @Test func aPlainClickActivatesAnchorsAndClearsTheSelectionInOneCommit() throws {
    let (store, window, tabs) = try windowWithTabs(3)
    try store.dispatch(Command("setSelection", [.string(window), [.string(tabs[1]), .string(tabs[2])]]))
    let before = store.rev
    #expect(WorkspaceActionRouter.click(store, windowId: window, tabId: tabs[0], mods: SidebarClickMods([])))
    #expect(store.rev == before + 1)
    #expect(store.state.activeTabId(window) == tabs[0])
    #expect(store.state.stateJSON["selectionAnchors"] == [window: .string(tabs[0])])
    #expect(store.state.stateJSON["selection"] == [:])
  }

  @Test func modifierClicksSelectLikeTheJavaScriptPath() throws {
    let (store, window, tabs) = try windowWithTabs(4)
    try store.dispatch(Command("activate", [.string(tabs[0])]))
    #expect(WorkspaceActionRouter.click(store, windowId: window, tabId: tabs[2], mods: SidebarClickMods(.command)))
    #expect(store.state.stateJSON["selection"] == [window: [.string(tabs[0]), .string(tabs[2])]])
    #expect(store.state.activeTabId(window) == tabs[0])
    #expect(WorkspaceActionRouter.click(store, windowId: window, tabId: tabs[3], mods: SidebarClickMods(.shift)))
    #expect(store.state.stateJSON["selection"] == [window: [.string(tabs[2]), .string(tabs[3])]])
    #expect(store.state.stateJSON["selectionAnchors"] == [window: .string(tabs[2])])
  }

  @Test func theCommandMatchesTheOneJavaScriptSends() {
    let command = WorkspaceActionRouter.clickCommand(windowId: "w", tabId: "t", mods: SidebarClickMods([.option, .shift]))
    #expect(command.name == "clickTab")
    #expect(command.args == [.string("w"), .string("t"), ["metaKey": false, "shiftKey": true, "altKey": true]])
  }

  @Test func onlyAnOwnedWorkspaceRoutesNatively() throws {
    let (store, _, _) = try windowWithTabs(1)
    let owned = NativeStoreHandle.ownsWorkspace
    let resolve = NativeStoreHandle.resolve
    defer { NativeStoreHandle.ownsWorkspace = owned; NativeStoreHandle.resolve = resolve }
    NativeStoreHandle.resolve = { store }
    NativeStoreHandle.ownsWorkspace = false
    #expect(WorkspaceActionRouter.ownedStore == nil)
    NativeStoreHandle.ownsWorkspace = true
    #expect(WorkspaceActionRouter.ownedStore === store)
  }

  @Test func safeModeRoutesNativelyAndAFrozenStoreHandsOffAtOnce() throws {
    let (store, window, tabs) = try windowWithTabs(2)
    var safeConfig = StoreConfig()
    safeConfig.safeMode = true
    let safe = Store(state: store.state, config: safeConfig)
    let owns = NativeStoreHandle.ownsWorkspace
    let resolve = NativeStoreHandle.resolve
    defer {
      NativeStoreHandle.ownsWorkspace = owns
      NativeStoreHandle.resolve = resolve
      NativeStoreHandle.thawForTests()
    }
    NativeStoreHandle.ownsWorkspace = true
    NativeStoreHandle.resolve = { safe }
    #expect(WorkspaceActionRouter.ownedStore === safe)
    #expect(WorkspaceActionRouter.ownedClick(windowId: window, tabId: tabs[0], mods: SidebarClickMods([])))
    #expect(safe.state.activeTabId(window) == tabs[0])
    NativeStoreHandle.resolve = { store }
    NativeStoreHandle.markFrozen()
    #expect(WorkspaceActionRouter.ownedStore == nil)
    #expect(!WorkspaceActionRouter.ownedClick(windowId: window, tabId: tabs[1], mods: SidebarClickMods([])))
    #expect(store.state.activeTabId(window) != tabs[1])
  }

  @Test func withoutAnOwnedWorkspaceClicksAndClosesHandOffToJavaScriptUntouched() throws {
    let (store, window, tabs) = try windowWithTabs(3)
    let owned = NativeStoreHandle.ownsWorkspace
    let resolve = NativeStoreHandle.resolve
    defer { NativeStoreHandle.ownsWorkspace = owned; NativeStoreHandle.resolve = resolve }
    NativeStoreHandle.resolve = { store }
    NativeStoreHandle.ownsWorkspace = false
    let before = store.state
    let plain = SidebarClickMods([])
    let meta = SidebarClickMods(.command)
    #expect(!WorkspaceActionRouter.ownedClick(windowId: window, tabId: tabs[0], mods: plain))
    #expect(!WorkspaceActionRouter.ownedClick(windowId: window, tabId: tabs[1], mods: meta))
    #expect(WorkspaceActionRouter.ownedClose(tabId: tabs[1], middle: false) == nil)
    #expect(WorkspaceActionRouter.ownedClose(tabId: tabs[1], middle: true) == nil)
    #expect(store.state.stateJSON == before.stateJSON)
    NativeStoreHandle.ownsWorkspace = true
    let close = try #require(WorkspaceActionRouter.ownedClose(tabId: tabs[1], middle: false))
    #expect(close.store === store && close.route == WorkspaceActionRouter.closeRoute(store.state, tabId: tabs[1]))
    let middle = try #require(WorkspaceActionRouter.ownedClose(tabId: tabs[1], middle: true))
    #expect(middle.route == WorkspaceActionRouter.middleClickRoute(store.state, tabId: tabs[1]))
    #expect(WorkspaceActionRouter.ownedClick(windowId: window, tabId: tabs[0], mods: plain))
    #expect(store.state.activeTabId(window) == tabs[0])
  }

  @Test func closeRoutesUnloadAnOpenPinRemoveAClosedOneAndCloseListTabs() throws {
    let state = try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"w":{"id":"w","profileId":"p","tabIds":["tile","open","closed","a"],"activeTabIds":{"p":"open"}}},"windowOrder":["w"],"tabs":{"tile":{"id":"tile","windowId":"w","profileId":"p","url":"https://tile.example/","title":"Tile","pinned":true},"open":{"id":"open","windowId":"w","profileId":"p","url":"https://open.example/","title":"Open","pinned":true,"pinnedAsRow":true},"closed":{"id":"closed","windowId":"w","profileId":"p","url":"https://closed.example/","title":"Closed","pinned":true,"pinnedAsRow":true},"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"}}}"#).object ?? [:])
    #expect(SidebarQuery(state).closeKind("closed") == .removePin)
    #expect(WorkspaceActionRouter.closeRoute(state, tabId: "closed") == .removePinOrClose)
    #expect(SidebarQuery(state).closeKind("open") == .unload)
    #expect(WorkspaceActionRouter.closeRoute(state, tabId: "open") == .unload(["open"]))
    #expect(WorkspaceActionRouter.closeRoute(state, tabId: "a") == .removePinOrClose)
    #expect(WorkspaceActionRouter.middleClickRoute(state, tabId: "tile") == .close)
    #expect(WorkspaceActionRouter.middleClickRoute(state, tabId: "closed") == .removePinOrClose)
    #expect(WorkspaceActionRouter.middleClickRoute(state, tabId: "a") == .removePinOrClose)
    #expect(WorkspaceActionRouter.closeRoute(state, tabId: "missing") == .removePinOrClose)
    #expect(WorkspaceActionRouter.middleClickRoute(state, tabId: "missing") == .removePinOrClose)
  }

  func renameState(layout: String? = nil, sidebarOpen: Bool = true, active: String = "a") throws -> BrowserState {
    let window = #"{"id":"w","profileId":"p","tabIds":["tile","row","a","b","c"],"activeTabIds":{"p":"\#(active)"},"sidebarOpen":\#(sidebarOpen)\#(layout.map { #","tabLayout":"\#($0)""# } ?? "")}"#
    let json = #"{"windows":{"w":\#(window)},"windowOrder":["w"],"tabs":{"tile":{"id":"tile","windowId":"w","profileId":"p","url":"https://t.example/","title":"Tile","pinned":true},"row":{"id":"row","windowId":"w","profileId":"p","url":"https://r.example/","title":"Row","pinned":true,"pinnedAsRow":true},"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"},"b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","title":"B"},"c":{"id":"c","windowId":"w","profileId":"p","url":"https://c.example/","title":"C"}},"groups":{"outer":{"id":"outer","windowId":"w","profileId":"p","name":"Outer","collapsed":true,"pinned":false,"tabIds":["b"]},"inner":{"id":"inner","windowId":"w","profileId":"p","name":"Inner","collapsed":true,"pinned":false,"parentId":"outer","tabIds":["c"]}}}"#
    return try BrowserState(stateJSON: JSONValue.parse(json).object ?? [:])
  }

  @Test func renameRoutesFollowStartRename() throws {
    let s = try renameState()
    #expect(WorkspaceActionRouter.renameRoute(s, windowId: "w", kind: .tab, id: "tile") == .tileSheet)
    #expect(WorkspaceActionRouter.renameRoute(s, windowId: "w", kind: .tab, id: "row") == .inline(expand: []))
    #expect(WorkspaceActionRouter.renameRoute(s, windowId: "w", kind: .tab, id: "a") == .inline(expand: []))
    #expect(WorkspaceActionRouter.renameRoute(s, windowId: "w", kind: .tab, id: "c") == .inline(expand: ["inner", "outer"]))
    #expect(WorkspaceActionRouter.renameRoute(s, windowId: "w", kind: .group, id: "inner") == .inline(expand: []))
    #expect(WorkspaceActionRouter.renameRoute(s, windowId: "w", kind: .tab, id: "missing") == nil)
    #expect(WorkspaceActionRouter.renameRoute(s, windowId: "w", kind: .group, id: "missing") == nil)
    #expect(WorkspaceActionRouter.renameRoute(try renameState(layout: "top"), windowId: "w", kind: .group, id: "inner") == .groupSheet)
    #expect(WorkspaceActionRouter.renameRoute(try renameState(sidebarOpen: false), windowId: "w", kind: .group, id: "inner") == .groupSheet)
  }

  @Test func renameCommitsTrimAndClearAsCommitRenameDoes() throws {
    let s = try renameState()
    #expect(WorkspaceActionRouter.renameCommand(s, kind: .tab, id: "a", text: "  New  ") == Command("updateTab", [.string("a"), ["customTitle": .string("New")]]))
    #expect(WorkspaceActionRouter.renameCommand(s, kind: .tab, id: "a", text: "   ") == Command("updateTab", [.string("a"), ["customTitle": .null]]))
    #expect(WorkspaceActionRouter.renameCommand(s, kind: .tab, id: "a", text: " A ") == Command("updateTab", [.string("a"), ["customTitle": .null]]))
    #expect(WorkspaceActionRouter.renameCommand(s, kind: .group, id: "inner", text: " Work ") == Command("updateGroup", [.string("inner"), ["name": .string("Work")]]))
    #expect(WorkspaceActionRouter.renameCommand(s, kind: .tab, id: "missing", text: "x") == nil)
    #expect(WorkspaceActionRouter.renameKey(.group, "g:1") == "group:g:1")
    #expect(WorkspaceActionRouter.renameKind("group:g:1") == .group && WorkspaceActionRouter.renameId("group:g:1") == "g:1")
  }

  @Test func renameRoutesForTheActiveTabLayoutsAndEmptyLayouts() throws {
    let s = try renameState(active: "c")
    #expect(WorkspaceActionRouter.renameRoute(s, windowId: "w", kind: .tab, id: "c") == .inline(expand: []))
    var top = try renameState(layout: "top")
    #expect(!WorkspaceActionRouter.sidebarShows(top, windowId: "w"))
    top.settings = Settings.hydrated(from: ["tabLayout": .string("sidebar")])
    #expect(!WorkspaceActionRouter.sidebarShows(top, windowId: "w"))
    var side = try renameState(layout: "sidebar")
    side.settings = Settings.hydrated(from: ["tabLayout": .string("top")])
    #expect(WorkspaceActionRouter.sidebarShows(side, windowId: "w"))
    var empty = try renameState(layout: "")
    empty.settings = Settings.hydrated(from: ["tabLayout": .string("top")])
    #expect(!WorkspaceActionRouter.sidebarShows(empty, windowId: "w"))
    empty.settings = Settings.hydrated(from: ["tabLayout": .string("sidebar")])
    #expect(WorkspaceActionRouter.sidebarShows(empty, windowId: "w"))
    #expect(!WorkspaceActionRouter.sidebarShows(empty, windowId: "missing"))
  }

  @Test func theRenameRegistryEndsOnlyItsOwnTargetAndPrunesTheGone() throws {
    let s = try renameState()
    var registry = WorkspaceRenameRegistry()
    #expect(registry.set("w", "tab:a") == 1)
    #expect(registry.end("w", id: "b") == nil)
    #expect(registry.key("w") == "tab:a")
    #expect(registry.set("w", "tab:b") == 2)
    #expect(registry.key("w") == "tab:b")
    #expect(registry.end("w", id: "b") == 3)
    #expect(registry.key("w") == nil)
    #expect(registry.end("w", id: "b") == nil)
    #expect(registry.set("w", "tab:gone") == 4)
    #expect(registry.override("w", state: s) == .some(nil))
    #expect(registry.stale(s) == ["w"])
    #expect(registry.set("other", "group:inner") == 1)
    #expect(registry.stale(s) == ["other", "w"])
    #expect(registry.set("w", "group:inner") == 5)
    #expect(registry.override("w", state: s) == .some("group:inner"))
    #expect(registry.stale(s) == ["other"])
    #expect(registry.override("nobody", state: s) == .some(nil))
  }

  @Test func committingOnADeletedTargetChangesNothingAndUnownedHostsKeepJavaScriptState() throws {
    let s = try renameState()
    #expect(WorkspaceActionRouter.renameCommand(s, kind: .group, id: "deleted", text: "x") == nil)
    #expect(WorkspaceActionRouter.renameCommand(s, kind: .tab, id: "deleted", text: "x") == nil)
    let owned = NativeStoreHandle.ownsWorkspace
    defer { NativeStoreHandle.ownsWorkspace = owned }
    NativeStoreHandle.ownsWorkspace = false
    #expect(WorkspaceActionRouter.ownedStore == nil)
  }

  @Test func aSecondSheetOnAWindowIsDeclinedUntilTheFirstSettles() {
    var pending: Set<String> = []
    #expect(WorkspaceSheetGuard.claim(&pending, windowId: "w", closing: []))
    #expect(!WorkspaceSheetGuard.claim(&pending, windowId: "w", closing: []))
    #expect(WorkspaceSheetGuard.claim(&pending, windowId: "other", closing: []))
    pending.remove("w")
    #expect(WorkspaceSheetGuard.claim(&pending, windowId: "w", closing: []))
    #expect(!WorkspaceSheetGuard.claim(&pending, windowId: "closing", closing: ["closing"]))
    #expect(!pending.contains("closing"))
  }
}
