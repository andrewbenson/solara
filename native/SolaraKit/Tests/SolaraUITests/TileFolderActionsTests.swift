import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct TileFolderActionsTests {
  func foldered(members: Int = 3) throws -> (Store, String, [String], String) {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: true)
    let window = try store.dispatch(Command("createWindow")).result!.string!
    for i in 1...4 { try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://www.t\(i).example/")]])) }
    let tabs = store.state.windows[window]!.tabIds
    let folder = try store.dispatch(Command("newTileFolder", [JSONValue(Array(tabs.suffix(members)))])).result!.string!
    return (store, window, tabs, folder)
  }

  func ids(_ items: [TileFolderMenuItem]) -> [String] { items.map { $0.separator ? "-" : $0.id ?? "?" } }

  @Test func togglingTheOpenFolderClosesAndAnyOtherFolderOpens() throws {
    let (store, window, _, folder) = try foldered()
    var panel = TileFolderPanelState()
    let result101 = panel.toggle(windowId: window, folderId: folder)
    #expect(result101 == .open)
    panel.opened(windowId: window, folderId: folder, state: store.state)
    #expect(panel.folder(in: window) == folder)
    let result102 = panel.toggle(windowId: window, folderId: folder)
    #expect(result102 == .close)
    let result103 = panel.toggle(windowId: window, folderId: "tf-other")
    #expect(result103 == .open)
    let result104 = panel.toggle(windowId: "w-other", folderId: folder)
    #expect(result104 == .open)
    panel.opened(windowId: window, folderId: "tf-other", state: store.state)
    #expect(panel.open?.folderId == "tf-other")
    #expect(panel.folder(in: "w-other") == nil)
  }

  @Test func closingInAnotherWindowLeavesThePanelOpen() throws {
    let (store, window, _, folder) = try foldered()
    var panel = TileFolderPanelState()
    panel.opened(windowId: window, folderId: folder, state: store.state)
    let result1 = panel.close(in: "w-other")
    #expect(!result1)
    let result2 = panel.close(in: nil)
    #expect(!result2)
    let result3 = panel.close(in: window)
    #expect(result3)
    #expect(panel.open == nil)
    let result4 = panel.close()
    #expect(!result4)
  }

  @Test func theOpenPanelSurvivesUnrelatedCommits() throws {
    let (store, window, tabs, folder) = try foldered()
    var panel = TileFolderPanelState()
    panel.opened(windowId: window, folderId: folder, state: store.state)
    try store.dispatch(Command("updateTab", [.string(tabs[0]), ["customTitle": "Elsewhere"]]))
    let result5 = panel.check(store.state)
    #expect(!result5)
    #expect(panel.folder(in: window) == folder)
  }

  @Test func anActiveTabChangeClosesThePanel() throws {
    let (store, window, tabs, folder) = try foldered()
    try store.dispatch(Command("activate", [.string(tabs[0])]))
    var panel = TileFolderPanelState()
    panel.opened(windowId: window, folderId: folder, state: store.state)
    try store.dispatch(Command("activate", [.string(tabs[2])]))
    let result6 = panel.check(store.state)
    #expect(result6)
    #expect(panel.open == nil)
  }

  @Test func aProfileChangeOrAGoneWindowClosesThePanel() throws {
    let (store, window, _, folder) = try foldered()
    let active = store.state.activeTabId(window)
    var panel = TileFolderPanelState(open: TileFolderPanelSlot(windowId: window, folderId: folder, profileId: "p-elsewhere", activeTabId: active))
    let result7 = panel.check(store.state)
    #expect(result7)
    var gone = TileFolderPanelState(open: TileFolderPanelSlot(windowId: "w-gone", folderId: folder, profileId: nil, activeTabId: nil))
    let goneClosed = gone.check(store.state)
    #expect(goneClosed)
  }

  @Test func aFolderWithNoMembersLeftClosesThePanel() throws {
    let (store, window, _, folder) = try foldered()
    var panel = TileFolderPanelState()
    panel.opened(windowId: window, folderId: folder, state: store.state)
    try store.dispatch(Command("dissolveTileFolder", [.string(window), .string(folder)]))
    #expect(TileFolderPanel.members(store.state, windowId: window, folderId: folder).isEmpty)
    let result8 = panel.check(store.state)
    #expect(result8)
  }

  @Test func theFolderMenuListsTheJavaScriptRows() throws {
    let (store, window, _, folder) = try foldered()
    let items = TileFolderMenus.folderMenu(store.state, windowId: window, folderId: folder)
    #expect(ids(items) == ["rename", "remove", "-", "unpin"])
    #expect(items.map(\.title) == ["Rename Folder…", "Remove Folder", "", "Unpin 3 Tabs"])
    #expect(items.map(\.symbol) == ["character.cursor.ibeam", "folder.badge.minus", nil, "pin.slash"])
    #expect(TileFolderMenus.folderMenu(store.state, windowId: window, folderId: "tf-missing").isEmpty)
  }

  @Test func theUnpinTitleCountsLikePlural() {
    #expect(TileFolderMenus.unpinTitle(1) == "Unpin 1 Tab")
    #expect(TileFolderMenus.unpinTitle(2) == "Unpin 2 Tabs")
    #expect(TileFolderMenus.unpinTitle(0) == "Unpin 0 Tabs")
  }

  @Test func menuChoicesBecomeTheJavaScriptCommands() throws {
    let (store, window, tabs, folder) = try foldered()
    let members = TileFolderPanel.members(store.state, windowId: window, folderId: folder)
    #expect(members == Array(tabs.suffix(3)))
    #expect(TileFolderMenus.command(.remove, state: store.state, windowId: window, folderId: folder) == Command("dissolveTileFolder", [.string(window), .string(folder)]))
    let unpin = try #require(TileFolderMenus.command(.unpin, state: store.state, windowId: window, folderId: folder))
    #expect(unpin == Command("pinTabs", [JSONValue(members), false]))
    #expect(TileFolderMenus.command(.rename, state: store.state, windowId: window, folderId: folder) == nil)
    try store.dispatch(unpin)
    #expect(members.allSatisfy { store.state.tabs[$0]?.pinned == false })
    #expect(TileFolderMenus.folderMenu(store.state, windowId: window, folderId: folder).isEmpty)
  }

  @Test func renameNewAndLeaveSendTheJavaScriptCommands() throws {
    let (store, window, tabs, folder) = try foldered()
    #expect(TileFolderMenus.renameCommand(windowId: window, folderId: folder, name: "Work") == Command("renameTileFolder", [.string(window), .string(folder), "Work"]))
    #expect(TileFolderMenus.newFolderCommand(tabId: tabs[0]) == Command("newTileFolder", [[.string(tabs[0])]]))
    #expect(TileFolderMenus.leaveCommand(tabId: tabs[3]) == Command("leaveTileFolder", [[.string(tabs[3])]]))
    #expect(TileFolderPanel.label(store.state, windowId: window, folderId: folder) == "Folder")
    try store.dispatch(TileFolderMenus.renameCommand(windowId: window, folderId: folder, name: "  Work  "))
    #expect(TileFolderPanel.label(store.state, windowId: window, folderId: folder) == "Work")
    try store.dispatch(TileFolderMenus.leaveCommand(tabId: tabs[3]))
    #expect(!TileFolderPanel.members(store.state, windowId: window, folderId: folder).contains(tabs[3]))
  }

  @Test func choicesParseLikeTheJavaScriptBranches() {
    #expect(TileFolderMenuChoice("rename") == .rename)
    #expect(TileFolderMenuChoice("remove") == .remove)
    #expect(TileFolderMenuChoice("unpin") == .unpin)
    #expect(TileFolderMenuChoice("t:abc") == .tab("abc"))
    #expect(TileFolderMenuChoice("g:abc") == nil)
    #expect(TileFolderMenuChoice("bogus") == nil)
  }

  @Test func thePanelRequestMarksTheActiveMemberAndUsesTheTabTitle() throws {
    let (store, window, tabs, folder) = try foldered()
    try store.dispatch(Command("activate", [.string(tabs[2])]))
    let look = FolderPanelLook(dark: false, theme: ["panel": "#FFFFFF"], panelShadowOpacity: 0.18)
    let request = TileFolderPanel.request(store.state, windowId: window, folderId: folder, look: look)
    #expect(request.folderId == folder && request.label == "Folder" && !request.dark && request.theme == ["panel": "#FFFFFF"] && request.panelShadowOpacity == 0.18)
    #expect(request.members.map(\.tabId) == Array(tabs.suffix(3)))
    #expect(request.members.map(\.active) == [true, false, false])
    #expect(request.members.allSatisfy { !$0.title.isEmpty })
  }

  @Test func theStripTileFolderMenuListsMembersThenRename() throws {
    let (store, window, tabs, folder) = try foldered()
    try store.dispatch(Command("activate", [.string(tabs[2])]))
    let items = TileFolderMenus.stripTileFolder(store.state, windowId: window, folderId: folder)
    #expect(ids(items) == tabs.suffix(3).map { "t:\($0)" } + ["-", "rename"])
    #expect(items.prefix(3).map(\.checked) == [true, false, false])
    #expect(items.last?.title == "Rename Folder…" && items.last?.symbol == "character.cursor.ibeam")
    #expect(items[0].title == ScriptState.tabLabel(store.state.tabs[tabs[2]]!))
  }

  @Test func theStripGroupFolderMenuNestsInnerGroups() throws {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: true)
    let window = try store.dispatch(Command("createWindow")).result!.string!
    for i in 1..<4 { try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://t\(i).example/")]])) }
    let tabs = store.state.windows[window]!.tabIds
    let group = try store.dispatch(Command("createGroup", [JSONValue(Array(tabs.prefix(2))), ["name": "Work"]])).result!.string!
    let child = try store.dispatch(Command("newNestedGroup", [.string(group)])).result!.string!
    let active = store.state.activeTabId(window)
    let items = TileFolderMenus.stripGroupFolder(store.state, groupId: group, activeId: active)
    let nested = try #require(items.first { $0.id == "g:\(child)" })
    #expect(nested.symbol == "folder" && nested.title == SidebarQuery(store.state).groupLabel(child))
    #expect(nested.children.map(\.id) == (store.state.groups[child]?.tabIds ?? []).map { "t:\($0)" })
    #expect(items.contains { $0.id == "t:\(tabs[0])" })
    #expect(TileFolderMenus.stripGroupFolder(store.state, groupId: "g-missing", activeId: nil).isEmpty)
  }

  @Test func aPanelOpenClicksLikeAPlainClick() {
    #expect(TileFolderPanel.plainClick(windowId: "w", tabId: "t") == WorkspaceActionRouter.clickCommand(windowId: "w", tabId: "t", mods: SidebarClickMods([])))
  }

  @Test func tabTitlesFallBackLikeTheJavaScriptTabTitle() {
    #expect(TileFolderPanel.urlLabel("https://www.example.com/") == "example.com")
    #expect(TileFolderPanel.urlLabel("") == "")
  }

  @Test func theLookDecodesTheJavaScriptJSON() {
    let look = FolderPanelLook.decode(##"{"dark":true,"theme":{"panel":"#2A2A2A"},"panelShadowOpacity":0.5}"##)
    #expect(look == FolderPanelLook(dark: true, theme: ["panel": "#2A2A2A"], panelShadowOpacity: 0.5))
    #expect(FolderPanelLook.decode("nope") == nil)
  }
}
