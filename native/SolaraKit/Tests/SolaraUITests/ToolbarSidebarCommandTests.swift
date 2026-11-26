import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct ToolbarSidebarCommandTests {
  private func state() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["a", "b"]
    window.activeTabIds["default"] = "a"
    state.windows["w"] = window
    var other = BrowserWindow(id: "other", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    other.sidebarOpen = !window.sidebarOpen
    state.windows["other"] = other
    state.windowOrder = ["w", "other"]
    state.splits["s"] = SplitView(id: "s", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    for id in window.tabIds {
      state.tabs[id] = Tab(id: id, windowId: "w", profileId: "default", url: "https://example.com", now: 0)
    }
    return state
  }

  @Test func activePaneOnlyTogglesItsOwnSidebar() {
    #expect(ToolbarSidebarCommand.commands(click: ToolbarClick(id: "sidebar", kind: .press), windowId: "w", target: .pane("a"), state: state(), closing: []) == [Command("toggleSidebar", ["w"])])
  }

  @Test func inactivePaneActivatesBeforeToggling() {
    #expect(ToolbarSidebarCommand.commands(click: ToolbarClick(id: "sidebar", kind: .press), windowId: "w", target: .pane("b"), state: state(), closing: []) == [Command("activate", ["b"]), Command("toggleSidebar", ["w"])])
  }

  @Test func inactivePaneAndSidebarSettleTogether() throws {
    let initial = state()
    let store = makeUIStore(initial)
    let commands = try #require(ToolbarSidebarCommand.commands(click: ToolbarClick(id: "sidebar", kind: .press), windowId: "w", target: .pane("b"), state: initial, closing: []))
    try store.dispatch(commands, origin: .native)
    #expect(store.state.activeTabId("w") == "b")
    #expect(store.state.windows["w"]?.sidebarOpen == !initial.windows["w"]!.sidebarOpen)
    #expect(store.state.windows["other"]?.sidebarOpen == initial.windows["other"]?.sidebarOpen)
  }

  @Test func staleAndCrossWindowOrProfileTargetsDoNothing() {
    let click = ToolbarClick(id: "sidebar", kind: .press)
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "other", target: .pane("a"), state: state(), closing: []) == nil)
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "w", target: .pane("gone"), state: state(), closing: []) == nil)
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "w", target: .pane("a"), state: state(), closing: ["w"]) == nil)
    var changed = state()
    changed.tabs["a"]?.profileId = "other"
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "w", target: .pane("a"), state: changed, closing: []) == nil)
    changed = state()
    changed.tabs["a"]?.windowId = "other"
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "w", target: .pane("a"), state: changed, closing: []) == nil)
    changed = state()
    changed.splits["s"] = nil
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "w", target: .pane("b"), state: changed, closing: []) == nil)
    changed = state()
    changed.windows["w"]?.tabIds = ["a"]
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "w", target: .pane("b"), state: changed, closing: []) == nil)
  }

  @Test func addressRowCanToggleAWindowWithoutASelectedTab() {
    let click = ToolbarClick(id: "sidebar", kind: .press)
    let current = state()
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "other", target: .window, state: current, closing: []) == [Command("toggleSidebar", ["other"])])
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "other", target: .window, state: current, closing: ["other"]) == nil)
    #expect(ToolbarSidebarCommand.commands(click: click, windowId: "missing", target: .window, state: current, closing: []) == nil)
  }

  @Test func otherButtonsAreNotHandledAndSidebarKeepsClickKindBehavior() {
    #expect(ToolbarSidebarCommand.commands(click: ToolbarClick(id: "back", kind: .press), windowId: "w", target: .pane("a"), state: state(), closing: []) == nil)
    for kind: ToolbarClick.Kind in [.press, .menu, .middle, .submit, .cancel, .blur, .focus] {
      #expect(ToolbarSidebarCommand.commands(click: ToolbarClick(id: "sidebar", kind: kind), windowId: "w", target: .pane("a"), state: state(), closing: []) == [Command("toggleSidebar", ["w"])])
    }
  }
}
