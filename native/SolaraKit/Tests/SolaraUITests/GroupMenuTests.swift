import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct GroupMenuTests {
  func grouped(members: Int = 2) throws -> (Store, String, [String], String) {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: true)
    let window = try store.dispatch(Command("createWindow")).result!.string!
    for i in 1..<4 { try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://t\(i).example/")]])) }
    let tabs = store.state.windows[window]!.tabIds
    let group = try store.dispatch(Command("createGroup", [JSONValue(Array(tabs.prefix(members))), ["name": "Work"]])).result!.string!
    return (store, window, tabs, group)
  }

  func ids(_ items: [GroupMenuItem]) -> [String] { items.map { $0.separator ? "-" : $0.id ?? "?" } }

  @Test func aRootGroupListsTheJavaScriptRowsInOrder() throws {
    let (store, _, _, group) = try grouped()
    let items = GroupMenu.items(store.state, groupId: group, newTabShortcut: "⌥⌘T")
    #expect(ids(items) == ["rename", "icon", "color", "-", "newTab", "nest", "pin", "duplicate", "collapse", "-", "copy", "copyMd", "-", "ungroup", "bookmarkBar", "close", "delete"])
    #expect(items.first { $0.id == "icon" }?.title == "Add Icon…")
    #expect(items.first { $0.id == "pin" }?.title == "Pin Group")
    #expect(items.first { $0.id == "collapse" }?.title == "Collapse Group")
    let newTab = items.first { $0.id == "newTab" }
    #expect(newTab?.key == "t" && newTab?.modifiers == ["option", "command"])
  }

  @Test func theColorSubmenuMatchesJavaScript() throws {
    let (store, _, _, group) = try grouped()
    let colors = GroupMenu.items(store.state, groupId: group).first { $0.id == "color" }?.children ?? []
    #expect(ids(colors) == ["color:none", "color:", "color:", "-", "color:grey", "color:blue", "color:red", "color:yellow", "color:green", "color:pink", "color:purple", "color:cyan", "color:orange"])
    #expect(colors[1].checked && colors[1].swatch == "#0000004D" && colors[1].swatchDark == "#FFFFFF4D")
    #expect(colors[2].title == "Match Site Color" && !colors[2].enabled)
    #expect(colors[4].title == "Grey" && colors[4].swatch == "#8E8E93")
  }

  @Test func aNestedPinnedCollapsedColouredGroupChangesItsRows() throws {
    let (store, _, _, group) = try grouped()
    let child = try store.dispatch(Command("newNestedGroup", [.string(group)])).result!.string!
    try store.dispatch(Command("updateGroup", [.string(child), ["collapsed": true, "color": "red", "icon": "symbol:star"]]))
    let items = GroupMenu.items(store.state, groupId: child)
    #expect(!ids(items).contains("pin"))
    #expect(items.first { $0.id == "collapse" }?.title == "Expand Group")
    #expect(items.first { $0.id == "icon" }?.title == "Change Icon…")
    #expect(items.first { $0.id == "color" }?.children.first { $0.id == "color:red" }?.checked == true)
    try store.dispatch(Command("moveGroup", [.string(group), ["pinned": true]]))
    #expect(GroupMenu.items(store.state, groupId: group).first { $0.id == "pin" }?.title == "Unpin Group")
  }

  @Test func theNoIconSentinelReadsAsNoIcon() throws {
    let (store, _, _, group) = try grouped()
    try store.dispatch(Command("updateGroup", [.string(group), ["icon": .string(SidebarIconPickerMetrics.noGroupIcon)]]))
    #expect(GroupMenu.items(store.state, groupId: group).first { $0.id == "icon" }?.title == "Add Icon…")
  }

  @Test func nearestColorMatchesTheJavaScriptTable() {
    #expect(GroupMenu.nearestColor("#4C8DF6") == "blue")
    #expect(GroupMenu.nearestColor("rgb(229, 83, 75)") == "red")
    #expect(GroupMenu.nearestColor("  #3fb06cff") == "green")
    #expect(GroupMenu.nearestColor("#808080") == nil)
    #expect(GroupMenu.nearestColor("#050505") == nil)
    #expect(GroupMenu.nearestColor("#FAFAFF") == nil)
    #expect(GroupMenu.nearestColor("teal") == nil)
  }

  @Test func shortcutHintsBecomeMenuKeysLikeJavaScript() {
    #expect(GroupMenu.menuKey("⌥⌘T")! == ("t", ["option", "command"]))
    #expect(GroupMenu.menuKey("⌘↩")! == ("\r", ["command"]))
    #expect(GroupMenu.menuKey("⌥F5")! == ("\u{F708}", ["option"]))
    #expect(GroupMenu.menuKey("⌘Space")! == (" ", ["command"]))
    #expect(GroupMenu.menuKey("🌐F") == nil)
    #expect(GroupMenu.menuKey("⌘") == nil)
  }

  @Test func choicesParseLikeTheJavaScriptBranches() {
    #expect(GroupMenuChoice("color:") == .color(nil))
    #expect(GroupMenuChoice("color:none") == .color("none"))
    #expect(GroupMenuChoice("copyMd") == .copy(markdown: true))
    #expect(GroupMenuChoice("bogus") == nil)
  }

  @Test func storeCommandsMatchWhatJavaScriptSent() throws {
    let (store, _, _, group) = try grouped()
    let state = store.state
    #expect(GroupMenu.command(.color(nil), groupId: group, state: state) == Command("updateGroup", [.string(group), ["color": .null]]))
    #expect(GroupMenu.command(.pin, groupId: group, state: state) == Command("moveGroup", [.string(group), ["pinned": true]]))
    #expect(GroupMenu.command(.collapse, groupId: group, state: state) == GroupActions.collapse(group, true))
    #expect(GroupMenu.command(.rename, groupId: group, state: state) == nil)
  }

  @Test func copiedLinksAreTheJavaScriptText() throws {
    let (store, _, tabs, _) = try grouped()
    let urls = [tabs[1], tabs[2]].map { store.state.tabs[$0]!.url }
    #expect(Set(urls).isSubset(of: ["https://t1.example/", "https://t2.example/", "https://t3.example/"]))
    #expect(GroupMenu.copiedText(store.state, ids: [tabs[1], tabs[2]], markdown: false) == urls.joined(separator: "\n"))
    let md = GroupMenu.copiedText(store.state, ids: [tabs[1], tabs[2]], markdown: true) ?? ""
    #expect(md.hasPrefix("- [") && md.contains("\n- ["))
    #expect(GroupMenu.copiedText(store.state, ids: [], markdown: false) == nil)
    #expect(GroupMenu.urlLabel("https://www.example.com/") == "example.com")
  }
}
