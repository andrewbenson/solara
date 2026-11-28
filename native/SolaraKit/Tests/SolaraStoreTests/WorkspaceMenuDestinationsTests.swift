import SolaraModel
import SolaraStore
import Testing

@Suite struct WorkspaceMenuDestinationsTests {
  @Test func orderedProfilesAndVisibleDestinations() throws {
    var state = BrowserState()
    state.profiles["work"] = Profile(id: "work", name: "Work", color: "", icon: nil, createdAt: 0)
    state.profileOrder = ["work", "missing", "default"]
    state.windows["a"] = BrowserWindow(id: "a", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    state.windows["b"] = BrowserWindow(id: "b", profileId: "work", incognito: false, frame: nil, createdAt: 0)
    state.windows["retained"] = try BrowserWindow(json: ["id": "retained", "profileId": "work", "keptOnClose": true])
    state.windows["small"] = try BrowserWindow(json: ["id": "small", "profileId": "work", "kind": "small"])
    state.windows["private"] = try BrowserWindow(json: ["id": "private", "profileId": "incognito:private@work",
                                                       "incognito": true, "originalProfileId": "work"])
    state.windowOrder = ["retained", "b", "small", "missing", "private", "a"]
    let menu = WorkspaceMenuDestinations(state: state, windowId: "a", closing: [])
    #expect(menu.profiles.map(\.id) == ["work", "default"])
    #expect(menu.profiles.map(\.current) == [false, true])
    #expect(menu.windows.map(\.id) == ["b"])
    #expect(menu.windows.map(\.title) == ["Work — New Tab"])
    let privateMenu = WorkspaceMenuDestinations(state: state, windowId: "private", closing: [])
    #expect(privateMenu.windows.isEmpty)
    #expect(privateMenu.profiles.allSatisfy { !$0.current })
    #expect(privateMenu.bookmarkProfile == "work")
    let windowless = WorkspaceMenuDestinations(state: state, windowId: nil, closing: ["a"])
    #expect(windowless.windows.map(\.id) == ["b"])
    #expect(windowless.bookmarkProfile == state.settings.defaultProfileId)
  }

  @Test func emptyCatalog() {
    var state = BrowserState()
    state.profiles = Table()
    let menu = WorkspaceMenuDestinations(state: state, windowId: nil, closing: [])
    #expect(menu.profiles.isEmpty)
    #expect(menu.windows.isEmpty)
  }
}
