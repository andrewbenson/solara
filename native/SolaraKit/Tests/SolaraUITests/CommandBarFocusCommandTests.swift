import AppKit
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct CommandBarFocusCommandTests {
  private func fixture(_ url: String = "https://example.com/") -> BrowserState {
    var s = BrowserState(settings: Settings.hydrated(from: nil))
    var w = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    w.tabIds = ["a"]
    w.activeTabIds["default"] = "a"
    s.windows["w"] = w
    s.windowOrder = ["w"]
    s.ui.focusedWindowId = "w"
    s.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: url, now: 0)
    return s
  }

  @Test func pageAndSmallWindowUsePanelWithURL() throws {
    var s = fixture()
    #expect(try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: [])).destination == .panel)
    s.windows["w"]?.kind = "small"
    let p = try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: []))
    #expect(p.destination == .panel && p.text == "https://example.com/")
  }

  @Test func developerAndPrivateOriginalProfile() throws {
    var s = fixture("http://localhost:8080/")
    #expect(try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: [])).destination == .developer)
    s.windows["w"]?.incognito = true
    s.windows["w"]?.profileId = "incognito:w@default"
    s.windows["w"]?.activeTabIds["incognito:w@default"] = "a"
    s.tabs["a"]?.profileId = "incognito:w@default"
    #expect(try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: [])).destination == .developer)
    s.settings["developerMode"] = ["default": ["on": [], "off": ["localhost"]]]
    #expect(try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: [])).destination == .panel)
  }

  @MainActor
  @Test func developerFocusAllowsTheIncomingPageToTakeFocusFromTheWindow() throws {
    let developer = try #require(CommandBarFocusCommand.plan(windowId: "w", state: fixture("http://localhost:8080/"), closing: []))
    let panel = try #require(CommandBarFocusCommand.plan(windowId: "w", state: fixture(), closing: []))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
    let content = try #require(window.contentView)
    let page = NSView()
    let renderer = NSView()
    let sibling = NSTextField()
    content.addSubview(page)
    content.addSubview(sibling)
    page.addSubview(renderer)
    #expect(developer.allowsPageHandoff(from: ObjectIdentifier(window), to: renderer, page: page, in: window))
    #expect(!developer.allowsPageHandoff(from: ObjectIdentifier(window), to: sibling, page: page, in: window))
    #expect(!developer.allowsPageHandoff(from: ObjectIdentifier(sibling), to: renderer, page: page, in: window))
    #expect(!developer.allowsPageHandoff(from: ObjectIdentifier(window), to: renderer, page: NSView(), in: window))
    #expect(!panel.allowsPageHandoff(from: ObjectIdentifier(window), to: renderer, page: page, in: window))
  }

  @Test func blankSplitPaneUsesThePanel() throws {
    var s = fixture("")
    s.tabs["b"] = Tab(id: "b", windowId: "w", profileId: "default", url: "https://example.com/", now: 0)
    s.windows["w"]?.tabIds = ["a", "b"]
    s.splits["s"] = SplitView(id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    for placement in ["centred", "toolbar"] {
      s.settings["commandBarPlacement"] = .string(placement)
      let p = try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: []))
      #expect(p.destination == .panel)
      #expect(p.commands.first?.name == "openPanel")
    }
  }

  @Test func blankPoliciesAndSidebarPlacement() throws {
    var s = fixture("")
    s.settings["newTabOpens"] = "commandBar"
    let p = try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: []))
    #expect(p.destination == .newTab)
    #expect(p.commands.first?.args.last == .object(["kind": "into", "tabId": "a"]))
    s.settings["newTabOpens"] = "page"
    s.settings["addressBar"] = "toolbar"
    #expect(try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: [])).destination == .hero)
    s.settings["addressBar"] = "sidebar"
    s.settings["commandBarPlacement"] = "field"
    #expect(try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: [])).destination == .sidebar)
    s.settings["commandBarPlacement"] = "centred"
    #expect(try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: [])).destination == .hero)
  }

  @Test func utilityRoutesToBrowserAndClosedOrMissingTargetsRefuse() {
    let s = fixture()
    #expect(CommandBarFocusCommand.plan(windowId: "settings", state: s, closing: [])?.windowId == "w")
    #expect(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: ["w"]) == nil)
    #expect(CommandBarFocusCommand.plan(windowId: "missing", state: s, closing: [])?.windowId == "w")
    #expect(CommandBarFocusCommand.plan(windowId: nil, state: BrowserState(), closing: []) == nil)
  }

  @Test func peekKeepsUnderlyingTargetAndHeroClosesPanel() throws {
    let store = makeUIStore(fixture())
    try store.dispatch(Command("openPeek", ["a", "https://peek.example/"]), origin: .native)
    #expect(CommandBarFocusCommand.plan(windowId: "w", state: store.state, closing: [])?.tabId == "a")
    let blank = makeUIStore(fixture(""))
    try blank.dispatch(Command("openPanel", ["w", "retained"]), origin: .native)
    let p = try #require(CommandBarFocusCommand.plan(windowId: "w", state: blank.state, closing: []))
    #expect(p.destination == .hero)
    try blank.dispatch(p.commands, origin: .native)
    #expect(blank.state.windowUi["w"]?.panelOpen == false)
    #expect(p.isCurrent(state: blank.state, closing: [], gateLive: true))
  }

  @Test func mountDeadlineSecondShortcutAndOwnershipLossRefuse() throws {
    let s = fixture()
    let p = try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: []))
    let receipt = CommandBarFocusReceipt(plan: p, request: -1, ownership: 7, deadline: 10)
    #expect(receipt.allows(request: -1, ownership: 7, now: 9, gateLive: true, state: s, closing: []))
    #expect(!receipt.allows(request: -1, ownership: 7, now: 10, gateLive: true, state: s, closing: []))
    #expect(!receipt.allows(request: -2, ownership: 7, now: 9, gateLive: true, state: s, closing: []))
    #expect(!receipt.allows(request: -1, ownership: 8, now: 9, gateLive: true, state: s, closing: []))
    #expect(!receipt.allows(request: -1, ownership: 7, now: 9, gateLive: false, state: s, closing: []))
  }

  @Test func readinessNeverSurvivesATargetOrGateChange() throws {
    let s = fixture()
    let p = try #require(CommandBarFocusCommand.plan(windowId: "w", state: s, closing: []))
    #expect(p.isCurrent(state: s, closing: [], gateLive: true))
    #expect(!p.isCurrent(state: s, closing: [], gateLive: false))
    var changed = s
    changed.tabs["a"]?.url = "https://replacement.example/"
    #expect(!p.isCurrent(state: changed, closing: [], gateLive: true))
    changed = s
    changed.windows["w"]?.profileId = "other"
    #expect(!p.isCurrent(state: changed, closing: [], gateLive: true))
    changed = s
    changed.windows["w"]?.activeTabIds["default"] = "gone"
    #expect(!p.isCurrent(state: changed, closing: [], gateLive: true))
    #expect(!p.isCurrent(state: s, closing: ["w"], gateLive: true))
  }
}
