import AppKit
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct ToolbarActionCommandTests {
  private func state(privateWindow: Bool = false, small: Bool = false) -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: privateWindow, frame: nil, createdAt: 0)
    if small { window.kind = "small" }
    window.tabIds = ["a", "b", "c"]
    window.activeTabIds["default"] = "a"
    state.windows["w"] = window
    state.splits["split"] = SplitView(id: "split", windowId: "w", tabIds: ["a", "b"], orientation: "horizontal", sizes: [0.5, 0.5])
    for id in window.tabIds {
      state.tabs[id] = Tab(id: id, windowId: "w", profileId: "default", url: "https://example.com/\(id)", now: 0)
    }
    return state
  }

  @Test func modifiersKeepHistoryDisposition() {
    for (kind, flags, expected) in [
      (ToolbarClick.Kind.press, NSEvent.ModifierFlags(), ToolbarActionCommand.HistoryDisposition.current),
      (.press, .option, .current),
      (.press, [.option, .shift], .current),
      (.press, .shift, .window),
      (.press, [.command, .option], .background),
      (.middle, [.option, .shift], .foreground),
    ] {
      #expect(ToolbarActionCommand.historyDisposition(ToolbarClick(id: "back", kind: kind, flags: flags)) == expected)
    }
  }

  @Test func reloadPlansOnlyOneEffect() {
    let command = ToolbarClick(id: "reload", kind: .press, flags: [.command, .shift])
    let shift = ToolbarClick(id: "reload", kind: .press, flags: .shift)
    let press = ToolbarClick(id: "reload", kind: .press)
    #expect(ToolbarActionCommand.reload(command, loading: true, ignoresCache: true) == .stop)
    #expect(ToolbarActionCommand.reload(command, loading: false, ignoresCache: true) == .duplicate)
    #expect(ToolbarActionCommand.reload(shift, loading: false, ignoresCache: false) == .forceReload)
    #expect(ToolbarActionCommand.reload(press, loading: false, ignoresCache: true) == .forceReload)
    #expect(ToolbarActionCommand.reload(press, loading: false, ignoresCache: false) == .reload)
  }

  @Test func onlyVisiblePaneCanActivate() {
    let state = state()
    #expect(ToolbarActionCommand.resolve(windowId: "w", tabId: "a", state: state, closing: [])?.activation == nil)
    #expect(ToolbarActionCommand.resolve(windowId: "w", tabId: "b", state: state, closing: [])?.activation == Command("activate", ["b"]))
    #expect(ToolbarActionCommand.resolve(windowId: "w", tabId: "c", state: state, closing: []) == nil)
    #expect(ToolbarActionCommand.resolve(windowId: "w", tabId: "a", state: state, closing: ["w"]) == nil)
  }

  @Test func peekTakesPrecedenceAndKeepsItsSelection() throws {
    var state = state()
    state.peeks["w"] = Peek(tabId: "c", sourceId: "a", sourcePage: "https://example.com/a", from: nil)
    let target = try #require(ToolbarActionCommand.resolve(windowId: "w", tabId: "c", state: state, closing: []))
    #expect(target.activation == nil)
    #expect(ToolbarActionCommand.resolve(windowId: "w", tabId: "a", state: state, closing: []) == nil)
    state.peeks["w"] = nil
    #expect(!target.isCurrent(in: state, closing: []))
  }

  @Test func privateAndLittleWindowsKeepTheirOwnIdentity() throws {
    var state = state(privateWindow: true, small: true)
    let target = try #require(ToolbarActionCommand.resolve(windowId: "w", tabId: "a", state: state, closing: []))
    #expect(target.isCurrent(in: state, closing: []))
    state.windows["w"]?.profileId = "other"
    #expect(!target.isCurrent(in: state, closing: []))
  }

  @Test func privateBookmarkUsesTheOriginalProfileAndTheClickedPage() throws {
    var state = state(privateWindow: true)
    state.profiles["work"] = Profile(id: "work", name: "Work", color: "blue", icon: nil, createdAt: 0)
    let privateProfile = Ids.incognitoProfileId(windowId: "w", originalProfileId: "work")
    state.windows["w"]?.profileId = privateProfile
    state.windows["w"]?.originalProfileId = "work"
    state.windows["w"]?.activeTabIds[privateProfile] = "a"
    state.tabs["a"]?.profileId = privateProfile
    let action = try #require(ToolbarActionCommand.resolve(windowId: "w", tabId: "a", state: state, closing: []))
    #expect(action.bookmarkProfile == "work")
    #expect(action.tab.url == "https://example.com/a")
    state.windows["w"]?.originalProfileId = "default"
    #expect(!action.isCurrent(in: state, closing: []))
  }

  @MainActor @Test func retiredSidebarButtonCannotDispatchToReplacementTab() throws {
    let initial = try #require(SidebarAddressBarState.decode("""
    {"palette":{"text":"#000","secondary":"#000","icon":"#000","iconDisabled":"#000",
     "hover":"#fff","pressed":"#fff","pill":"#fff","divider":"#000"},"accent":"#000",
     "look":{"resting":"#fff","stroke":"#000","hover":"#fff","placeholder":"#000","prompt":"Address"},
     "buttons":[{"id":"reload","icon":"arrow.clockwise"}],"extensions":[],"tabId":"a"}
    """))
    let bar = SidebarAddressBarView(frame: .zero)
    var presses = 0
    bar.onClick = { _ in presses += 1 }
    bar.update(initial)
    let generation = bar.bindingGeneration
    let retired = try #require(bar.subviews.compactMap { $0 as? ToolbarButtonView }.first).onClick
    var next = initial
    next.tabId = "b"
    bar.update(next)
    #expect(bar.bindingGeneration != generation)
    let click = ToolbarClick(id: "reload", kind: .press)
    retired(click)
    #expect(presses == 0)
    try #require(bar.subviews.compactMap { $0 as? ToolbarButtonView }.first).onClick(click)
    #expect(presses == 1)
  }

  @Test func historyReplyRequiresOriginalNavigationAndSelection() throws {
    var state = state()
    let url = "https://example.com/a"
    state.tabs["a"]?.navigation = Navigation(url: url, seq: 1)
    let target = try #require(ToolbarActionCommand.resolve(windowId: "w", tabId: "a", state: state, closing: []))
    state.tabs["a"]?.navigation = Navigation(url: url, seq: 2)
    #expect(!target.isCurrent(in: state, closing: []))
    state.tabs["a"]?.navigation = Navigation(url: url, seq: 1)
    state.windows["w"]?.activeTabIds["default"] = "b"
    #expect(!target.isCurrent(in: state, closing: []))
  }
}
