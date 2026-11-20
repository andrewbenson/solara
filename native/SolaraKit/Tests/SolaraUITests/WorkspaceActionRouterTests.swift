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
}
