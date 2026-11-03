import SolaraModel
@testable import SolaraStore
import Testing

@Suite struct LastTabPinsTests {
  func windowWith(_ hosts: String...) throws -> (Store, String, [String]) {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow", [["url": .string("https://\(hosts[0]).com/")]])).result!.string!
    var ids = [store.state.windows[window]!.tabIds[0]]
    for host in hosts.dropFirst() {
      ids.append(try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://\(host).com/")]])).result!.string!)
    }
    return (store, window, ids)
  }

  func regular(_ store: Store, _ window: String) -> [String] {
    store.state.viewTabIds(window).filter { !store.state.inPinnedContainer($0) }
  }

  func closeLastTabTwice(_ store: Store, _ window: String) throws {
    try store.dispatch(Command("closeTab", [.string(regular(store, window)[0])]))
    #expect(store.state.windows[window] != nil)
    let blank = regular(store, window)[0]
    #expect(store.state.tabs[blank]?.url == "")
    try store.dispatch(Command("closeTab", [.string(blank)]))
  }

  @Test func closingTheNewTabLeftByTheLastTabKeepsAWindowThatHasASleepingPinnedTile() throws {
    let (store, window, ids) = try windowWith("pin", "last")
    try store.dispatch(Command("pinTabs", [[.string(ids[0])], true]))
    try store.dispatch(Command("closeTab", [.string(ids[0])]))
    #expect(store.state.tabs[ids[0]]?.unloaded == true)
    try closeLastTabTwice(store, window)
    #expect(store.state.windows[window] != nil)
    #expect(store.state.tabs[ids[0]]?.unloaded == true)
    #expect(store.state.tabs[ids[1]] == nil)
    #expect(regular(store, window).count == 1)
    #expect(regular(store, window).first.flatMap { store.state.tabs[$0]?.url } == "")
  }

  @Test func closingTheNewTabLeftByTheLastTabKeepsAWindowThatHasASleepingPinnedGroup() throws {
    let (store, window, ids) = try windowWith("member", "last")
    try store.dispatch(Command("groupTabs", [[.string(ids[0])], ["pinned": true, "name": "Pinned"]]))
    try store.dispatch(Command("closeTab", [.string(ids[0])]))
    #expect(store.state.tabs[ids[0]]?.unloaded == true)
    try closeLastTabTwice(store, window)
    #expect(store.state.windows[window] != nil)
    #expect(store.state.tabs[ids[0]]?.unloaded == true)
  }

  @Test func withoutPinsClosingTheNewTabLeftByTheLastTabStillClosesTheWindow() throws {
    let (store, window, _) = try windowWith("last")
    try closeLastTabTwice(store, window)
    #expect(store.state.windows[window] == nil)
  }
}
