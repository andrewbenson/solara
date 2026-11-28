import SolaraModel
import SolaraStore
import SolaraUI
import Testing

@Suite struct TabRevealTests {
  private func fixture() throws -> (Store, String, String, String) {
    let store = Store(state: BrowserState())
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://source.test/"]])).result?.string)
    let source = try #require(store.state.activeTabId(window))
    let target = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://target.test/", "background": true]])).result?.string)
    return (store, window, source, target)
  }

  @Test func aSelectedLiveTabCanRevealBeforePresentationCatchesUp() throws {
    let (store, window, source, target) = try fixture()
    let before = store.state
    try store.dispatch(Command("activate", [.string(target)]))
    #expect(TabReveal.transition(windowId: window, before: before, after: store.state, sharing: false,
      runtime: { _ in nil }, scrolledDown: { _ in false }) == .tab(target))
    #expect(TabReveal.transition(windowId: window, before: before, after: store.state, sharing: true,
      runtime: { _ in nil }, scrolledDown: { _ in false }) == .drop(source))
    var covered = PageRuntimeState()
    covered.newTabShown = true
    #expect(TabReveal.transition(windowId: window, before: before, after: store.state, sharing: false,
      runtime: { $0 == target ? covered : nil }, scrolledDown: { _ in false }) == .drop(source))
  }

  @Test func dismissingPeekLeavesSourceSelectedAndDoesNotRevealAnotherPage() throws {
    let (store, window, source, _) = try fixture()
    try store.dispatch(Command("openPeek", [.string(source), "https://peek.test/"]))
    let before = store.state
    try store.dispatch(Command("closePeek", [.string(window)]))
    #expect(store.state.activeTabId(window) == source)
    #expect(store.state.peeks[window] == nil)
    #expect(TabReveal.transition(windowId: window, before: before, after: store.state, sharing: false,
      runtime: { _ in nil }, scrolledDown: { _ in false }) == nil)
  }
}
