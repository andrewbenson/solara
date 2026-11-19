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
}
