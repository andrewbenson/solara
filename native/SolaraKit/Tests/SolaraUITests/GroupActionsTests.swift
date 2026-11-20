import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct GroupActionsTests {
  func grouped(tabs count: Int = 4, members: Int = 2, name: String = "Work") throws -> (Store, String, [String], String) {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: true)
    let window = try store.dispatch(Command("createWindow")).result!.string!
    for i in 1..<count { try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://t\(i).example/")]])) }
    let tabs = store.state.windows[window]!.tabIds
    let group = try store.dispatch(Command("createGroup", [JSONValue(Array(tabs.prefix(members))), ["name": .string(name)]])).result!.string!
    return (store, window, tabs, group)
  }

  @Test func closingAnUnpinnedGroupAsksFirstWithTheJavaScriptWording() throws {
    let (store, window, _, group) = try grouped()
    #expect(GroupActions.close(store.state, groupId: group) == .close(confirm: GroupActions.CloseConfirm(
      title: "Close “Work”?", message: "Its 2 tabs close with it. History › Recently Closed Groups brings it back.",
      confirmTitle: "Close Group", suppression: "Don’t ask me again", windowId: window)))
  }

  @Test func oneTabIsSingularAndTheWarningCanBeOff() throws {
    let (store, _, _, group) = try grouped(members: 1)
    guard case .close(let confirm?) = GroupActions.close(store.state, groupId: group) else { Issue.record("no confirm"); return }
    #expect(confirm.message.hasPrefix("Its 1 tab close"))
    try store.dispatch(Command("updateSettings", [["warnBeforeClosingTabGroup": false]]))
    #expect(GroupActions.close(store.state, groupId: group) == .close(confirm: nil))
  }

  @Test func aMissingWarningSettingStillAsks() throws {
    let (store, _, _, group) = try grouped()
    var state = store.state
    state.settings["warnBeforeClosingTabGroup"] = nil
    #expect(state.settings["warnBeforeClosingTabGroup"] == nil)
    guard case .close(let confirm?) = GroupActions.close(state, groupId: group) else { Issue.record("no confirm without the setting"); return }
    #expect(confirm.confirmTitle == "Close Group")
  }

  @Test func aMissingGroupDoesNothing() throws {
    let (store, _, _, _) = try grouped()
    #expect(GroupActions.close(store.state, groupId: "gone") == .nothing)
    #expect(GroupActions.tuckTarget(store.state, windowId: "gone", groupId: "gone") == nil)
  }

  @Test func tuckPicksTheMostRecentlyActiveTabOutsideTheGroup() throws {
    let (store, window, tabs, group) = try grouped(tabs: 4, members: 2)
    try store.dispatch(Command("activate", [.string(tabs[3])]))
    try store.dispatch(Command("activate", [.string(tabs[2])]))
    try store.dispatch(Command("activate", [.string(tabs[0])]))
    #expect(GroupActions.tuckTarget(store.state, windowId: window, groupId: group) == tabs[2])
  }

  @Test func tuckSkipsTabsOfAnotherProfile() throws {
    let (store, window, tabs, group) = try grouped(tabs: 3, members: 1)
    let other = try store.dispatch(Command("createProfile", [["name": "Other", "color": "blue"]])).result!.string!
    try store.dispatch(Command("activate", [.string(tabs[2])]))
    let foreign = try store.dispatch(Command("newTab", [.string(window), ["url": "https://o.example/", "profileId": .string(other), "background": true]])).result!.string!
    try store.dispatch(Command("activate", [.string(tabs[0])]))
    #expect(store.state.tabs[foreign]?.profileId == other)
    #expect(store.state.groups[group]?.profileId != other)
    let target = GroupActions.tuckTarget(store.state, windowId: window, groupId: group)
    #expect(target != nil && target != foreign)
    #expect(target.map { store.state.tabs[$0]?.profileId } == store.state.groups[group]?.profileId)
  }

  @Test func aPinnedGroupUnloadsItsOpenMembersInsteadOfClosing() throws {
    let (store, _, tabs, group) = try grouped(tabs: 3, members: 2)
    try store.dispatch(Command("updateGroup", [.string(group), ["pinned": true]]))
    guard store.state.groups[group]?.pinned == true else { Issue.record("group did not pin"); return }
    let query = SidebarQuery(store.state)
    let expected = Array(tabs.prefix(2)).flatMap { query.openPages($0) }
    let decision = GroupActions.close(store.state, groupId: group)
    #expect(!expected.isEmpty)
    #expect(decision == .unload(expected))
  }

  @Test func incognitoWindowsDropTheRecentlyClosedHint() throws {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: true)
    let window = try store.dispatch(Command("createWindow", [["incognito": true]])).result!.string!
    try store.dispatch(Command("newTab", [.string(window)]))
    let ids = store.state.windows[window]!.tabIds
    let group = try store.dispatch(Command("createGroup", [JSONValue(ids), ["name": "Private"]])).result!.string!
    guard case .close(let confirm?) = GroupActions.close(store.state, groupId: group) else { Issue.record("no confirm"); return }
    #expect(confirm.message == "Its \(ids.count) tabs close with it.")
  }

  @Test func collapseIsTheUpdateGroupJavaScriptSent() {
    #expect(GroupActions.collapse("g", true) == Command("updateGroup", [.string("g"), ["collapsed": .bool(true)]]))
  }
}
