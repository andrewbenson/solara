import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct BrowserServiceCommandTests {
  private func state() -> BrowserState {
    var s = BrowserState(settings: Settings.hydrated(from: nil))
    var w = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    w.tabIds = ["a", "b"]
    w.activeTabIds["default"] = "a"
    s.windows["w"] = w
    s.windowOrder = ["w"]
    s.ui.focusOrder = ["w"]
    s.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: "https://a.example/", now: 0)
    s.tabs["b"] = Tab(id: "b", windowId: "w", profileId: "default", url: "", now: 1)
    return s
  }
  private func plan(_ command: String = "openFile", _ s: BrowserState? = nil, arg: String? = nil) throws -> BrowserServicePlan {
    try #require(BrowserServiceCommand.plan(command, arg: arg, windowId: "w", state: s ?? state(), closing: []))
  }
  @Test func cancelChangesNothingAndTwoFilesActivateTheLast() throws {
    let store = makeUIStore(state())
    let p = try plan()
    let before = store.state
    try BrowserServiceCommand.open([], plan: p, store: store)
    #expect(store.state == before)
    try BrowserServiceCommand.open(["file:///one.html", "file:///two.html"], plan: p, store: store)
    #expect(store.state.activeTab("w")?.url == "file:///two.html")
    #expect(store.state.tabs.values.filter { $0.url.hasPrefix("file:") }.count == 2)
  }
  @Test func noWindowOpensAllFilesInOneWindow() throws {
    let store = makeUIStore(BrowserState(settings: Settings.hydrated(from: nil)))
    let p = try #require(BrowserServiceCommand.plan("openFile", arg: nil, windowId: nil, state: store.state, closing: []))
    try BrowserServiceCommand.open(["file:///one.html", "file:///two.html"], plan: p, store: store)
    #expect(store.state.windows.count == 1)
    #expect(store.state.tabs.values.filter { $0.url.hasPrefix("file:") }.count == 2)
    #expect(store.state.activeTab(store.state.windowOrder[0])?.url == "file:///two.html")
  }
  @Test func smallExpandsAndPeekPromotesWithoutAPicker() throws {
    var s = state()
    s.windows["w"]?.kind = "small"
    s.windows["w"]?.tabIds = ["a"]
    s.tabs.remove(["b"])
    let small = makeUIStore(s)
    let expanded = try #require(BrowserServiceCommand.promote(try plan("openFile", s), store: small))
    #expect(small.state.windows[expanded]?.isSmall == false)
    #expect(small.state.tabs["a"]?.windowId == expanded)
    let store = makeUIStore(state())
    try store.dispatch(Command("openPeek", ["a", "https://peek.example/"]), origin: .native)
    #expect(try plan("openFile", store.state).route.kind == .peekPromote)
    #expect(try plan("autofill", store.state).tabId == store.state.peeks["w"]?.tabId)
    let peekId = store.state.peeks["w"]?.tabId
    _ = try BrowserServiceCommand.promote(try plan("openFile", store.state), store: store)
    #expect(store.state.peeks["w"] == nil)
    #expect(store.state.activeTabId("w") == peekId)
  }
  @Test func pickerReceiptRejectsChangedActivePageProfileAndClosedWindow() throws {
    let p = try plan()
    var s = state()
    s.windows["w"]?.activeTabIds["default"] = "b"
    #expect(!BrowserServiceCommand.current(p, state: s, closing: []))
    s = state(); s.tabs["a"]?.url = "https://new.example/"
    #expect(!BrowserServiceCommand.current(p, state: s, closing: []))
    s = state(); s.windows["w"]?.profileId = "other"
    #expect(!BrowserServiceCommand.current(p, state: s, closing: []))
    #expect(!BrowserServiceCommand.current(p, state: state(), closing: ["w"]))
    #expect(!BrowserServiceCommand.current(p, state: BrowserState(settings: Settings.hydrated(from: nil)), closing: []))
  }
  @Test func blankSmallClosesIntoAMainWindowAndStaleNoWindowIsRejected() throws {
    var s = state()
    s.windows["w"]?.kind = "small"
    s.windows["w"]?.tabIds = ["b"]
    s.windows["w"]?.activeTabIds["default"] = "b"
    s.tabs.remove(["a"])
    let store = makeUIStore(s)
    let target = try #require(BrowserServiceCommand.promote(try plan("openFile", s), store: store))
    #expect(store.state.windows["w"] == nil)
    #expect(store.state.windows[target]?.isSmall == false)
    let empty = BrowserState(settings: Settings.hydrated(from: nil))
    let noWindow = try #require(BrowserServiceCommand.plan("openFile", arg: nil, windowId: nil, state: empty, closing: []))
    #expect(!BrowserServiceCommand.current(noWindow, state: state(), closing: []))
  }
  @Test func pickerReceiptRejectsOwnershipLossAndPageReplacement() throws {
    let p = try plan()
    let receipt = BrowserServiceReceipt(plan: p, ownership: 7, identity: nil)
    #expect(receipt.accepts(ownership: 7, identity: nil, state: state(), closing: []))
    #expect(!receipt.accepts(ownership: 8, identity: nil, state: state(), closing: []))
    let replacement = PageIdentity(tabId: "a", registrationGeneration: 2, sessionGeneration: "replacement")
    #expect(!receipt.accepts(ownership: 7, identity: replacement, state: state(), closing: []))
    let live = BrowserServiceReceipt(plan: p, ownership: 7, identity: replacement)
    #expect(!live.accepts(ownership: 7, identity: nil, state: state(), closing: []))
  }
  @Test func autofillModeRefusalAndPrivateSettingsProfile() throws {
    let field = try plan("autofill")
    #expect(!field.passwords)
    #expect(BrowserServiceCommand.settingsPane(field, shown: true) == nil)
    #expect(BrowserServiceCommand.settingsPane(field, shown: false) == "autofill")
    var changed = state()
    changed.tabs["a"]?.url = "https://replaced.example/"
    #expect(!BrowserServiceCommand.current(field, state: changed, closing: []))
    var s = state()
    s.windows["w"]?.incognito = true
    s.windows["w"]?.originalProfileId = "default"
    s.windows["w"]?.profileId = "incognito:w@default"
    s.windows["w"]?.activeTabIds["incognito:w@default"] = "a"
    s.tabs["a"]?.profileId = "incognito:w@default"
    let privatePlan = try plan("autofill", s, arg: "passwords")
    #expect(privatePlan.settingsProfile == "default")
    #expect(BrowserServiceCommand.settingsPane(privatePlan, shown: false) == "passwords")
  }
}
