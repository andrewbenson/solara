import Testing
import SolaraModel
import SolaraOmnibox
import SolaraStore
@testable import SolaraUI

struct ExtensionToolbarTests {
  @MainActor
  @Test func popupTransitionsRefreshToolbarWithStableCatalog() {
    let store = testStore()
    let presentation = ExtensionPresentation()
    let sources = NewTabSources()
    let rows: [JSONObject] = [["id": "a", "name": "Alpha", "enabled": true, "pinned": true]]
    let states: [Int: JSONValue] = [1: ["a": ["title": "Alpha", "enabled": true]]]
    var popup: String?
    presentation.trackToolbar(host: "host", window: "w", tab: "t", store: store, popup: popup)
    var buttons: JSONValue?
    func render(catalogChanged: Bool = false) {
      let changes = presentation.publish(store: store, lists: ["": rows], states: states, popup: { _ in popup }, sources: sources)
      #expect(changes.catalog == catalogChanged)
      if changes.toolbar { buttons = ExtensionToolbarProjection.make(rows: rows, states: states[1]?.object ?? [:], popup: popup,
        limit: 3, routes: [], webkit: false, accent: "")["buttons"] }
    }
    render(catalogChanged: true)
    #expect(buttons?.array?.first?["active"] == false)
    popup = "a"
    render()
    #expect(buttons?.array?.first?["active"] == true)
    popup = nil
    render()
    #expect(buttons?.array?.first?["active"] == false)
  }

  @MainActor
  @Test func sameTabEngineSwitchRefreshesEmptyToolbarInBothDirections() throws {
    let store = testStore()
    let presentation = ExtensionPresentation()
    let sources = NewTabSources()
    presentation.trackToolbar(host: "host", window: "w", tab: "t", store: store, popup: nil)
    var buttons: JSONValue?
    func render(catalogChanged: Bool = false) {
      let changes = presentation.publish(store: store, lists: [:], states: [:], popup: { _ in nil }, sources: sources)
      #expect(changes.catalog == catalogChanged)
      if changes.toolbar { buttons = ExtensionToolbarProjection.make(rows: [], states: [:], popup: nil,
        limit: 3, routes: [], webkit: store.pageEngine("t", in: store.state) == "webkit", accent: "")["buttons"] }
    }
    render(catalogChanged: true)
    #expect(buttons == [])
    for engine in ["webkit", "chromium"] {
      let commit = try store.dispatch(Command("updateTab", ["t", ["engine": .string(engine)]]), origin: .bridge)
      #expect(commit.state.activeTabId("w") == "t")
      render()
      #expect(buttons?.array?.compactMap { $0["id"]?.string } == (engine == "webkit" ? ["webkit"] : []))
    }
  }

  @MainActor
  @Test func alreadyLoadedProfilesFeedNewTabAfterProfileAndWindowChanges() throws {
    let store = testStore()
    let presentation = ExtensionPresentation()
    let sources = NewTabSources()
    let lists: [String: [JSONObject]] = [
      "": [["id": "a", "name": "Alpha", "enabled": true]],
      "work": [["id": "b", "name": "Beta", "enabled": true]],
    ]
    func publish() {
      _ = presentation.publish(store: store, lists: lists, states: [:], popup: { _ in nil }, sources: sources)
    }
    publish()
    #expect(sources.extensions("w").map(\.id) == ["a"])
    _ = try store.dispatch(Command("switchProfile", ["w", "work"]), origin: .bridge)
    publish()
    #expect(sources.extensions("w").map(\.id) == ["b"])
    let created = try store.dispatch(Command("createWindow", [["profileId": "work"]]), origin: .bridge)
    let newWindow = try #require(created.state.windowOrder.first { $0 != "w" })
    publish()
    #expect(sources.extensions(newWindow).map(\.id) == ["b"])
  }

  @MainActor
  @Test func retiredWindowsAndDetachClearExtensionsAndKeepCommands() throws {
    let store = testStore()
    let presentation = ExtensionPresentation()
    let sources = NewTabSources()
    let lists: [String: [JSONObject]] = ["": [["id": "a", "name": "Alpha", "enabled": true]]]
    let created = try store.dispatch(Command("createWindow", []), origin: .native)
    let other = try #require(created.state.windowOrder.first { $0 != "w" })
    for window in ["w", other] { sources.setActions([CommandAction(id: "reload", title: "Reload")], windowId: window) }
    func publish(_ store: Store?) {
      _ = presentation.publish(store: store, lists: lists, states: [:], popup: { _ in nil }, sources: sources)
    }
    publish(store)
    #expect(sources.extensions("w").map(\.id) == ["a"])
    #expect(sources.extensions(other).map(\.id) == ["a"])
    let beforeClose = sources.revision
    try store.dispatch(Command("closeWindow", [.string(other)]))
    publish(store)
    #expect(sources.extensions(other).isEmpty)
    #expect(sources.actions(other) != nil)
    #expect(sources.extensions("w").map(\.id) == ["a"])
    #expect(sources.revision > beforeClose)
    let beforeDetach = sources.revision
    publish(nil)
    #expect(sources.extensions("w").isEmpty)
    #expect(sources.actions("w") != nil)
    #expect(sources.revision > beforeDetach)
  }

  @MainActor
  @Test func actionChangesOnlyInvalidateToolbar() {
    let store = testStore()
    let presentation = ExtensionPresentation()
    let sources = NewTabSources()
    let lists: [String: [JSONObject]] = ["": [["id": "a", "name": "Alpha", "enabled": true]]]
    _ = presentation.publish(store: store, lists: lists, states: [:], popup: { _ in nil }, sources: sources)
    let changes = presentation.publish(store: store, lists: lists, states: [1: ["a": ["badgeText": "2"]]], popup: { _ in nil }, sources: sources)
    #expect(changes.toolbar)
    #expect(!changes.catalog)
    #expect(!changes.windows)
  }

  @MainActor
  @Test func menuReceiptRejectsProfileChangesAndRemoval() throws {
    let store = testStore()
    let captured = try #require(ExtensionPresentation.WindowContext(state: store.state, window: "w"))
    #expect(captured.matches(state: store.state))
    #expect(captured.engineProfile == "")
    var changed = store.state
    changed.profiles["work"]?.dataId = Settings.defaultProfileID
    changed.windows["w"]?.profileId = "work"
    #expect(OmniboxCommandSources.extensionProfile(state: changed, windowId: "w") == captured.engineProfile)
    #expect(!captured.matches(state: changed))

    changed = store.state
    changed.profiles[Settings.defaultProfileID]?.dataId = "new-engine"
    #expect(!captured.matches(state: changed))
    #expect(!ExtensionPresentation.WindowContext.profileExists(state: changed, engineProfile: captured.engineProfile))
    changed = store.state
    changed.profiles.remove([Settings.defaultProfileID])
    #expect(!captured.matches(state: changed))
    #expect(!ExtensionPresentation.WindowContext.profileExists(state: changed, engineProfile: captured.engineProfile))
    changed = store.state
    changed.windows.remove(["w"])
    #expect(!captured.matches(state: changed))
  }

  @MainActor
  @Test func littleSolaraPinUsesRegularNonClosingMainWindows() {
    var state = testStore().state
    let personal = state.settings.defaultProfileId
    var small = BrowserWindow(id: "small", profileId: "work", incognito: false, frame: nil, createdAt: 0)
    small.kind = "small"
    state.windows["small"] = small
    state.windows["private"] = BrowserWindow(id: "private", profileId: "work", incognito: true, frame: nil, createdAt: 0)
    state.windows["closing"] = BrowserWindow(id: "closing", profileId: "work", incognito: false, frame: nil, createdAt: 0)
    state.windowOrder = ["small", "private", "closing", "w"]
    state.ui.focusOrder = state.windowOrder
    #expect(state.windows["w"]?.profileId == personal)
    #expect(ExtensionPresentation.pinWindow(invoker: "small", state: state, closing: ["closing"]) == "w")
    #expect(ExtensionPresentation.pinWindow(invoker: "small", state: state, closing: []) == "closing")
    #expect(ExtensionPresentation.pinWindow(invoker: "small", state: state, closing: ["closing", "w"]) == nil)
  }

  @MainActor
  @Test func settingsProfileChangesOnlyWhenTheFocusedProfileChanges() throws {
    let store = testStore()
    let profile = ExtensionPresentation.focusedProfile(in: store.state)
    let background = try store.dispatch(Command("updateTab", ["t", ["title": "Updated"]]), origin: .engine)
    #expect(ExtensionPresentation.focusedProfileChange(background, from: profile) == nil)
    let switched = try store.dispatch(Command("switchProfile", ["w", "work"]), origin: .native)
    #expect(ExtensionPresentation.focusedProfileChange(switched, from: profile) == "work")
    let created = try store.dispatch(Command("createWindow", [["profileId": .string(profile)]]), origin: .native)
    let other = try #require(created.state.windowOrder.first { $0 != "w" })
    _ = try store.dispatch(Command("setFocusedWindow", ["w"]), origin: .native)
    let focused = try store.dispatch(Command("setFocusedWindow", [.string(other)]), origin: .native)
    #expect(ExtensionPresentation.focusedProfileChange(focused, from: "work") == profile)
  }

  private func testStore() -> Store {
    var state = BrowserState()
    let profile = state.settings.defaultProfileId
    state.profiles["work"] = Profile(id: "work", name: "Work", color: "blue", icon: nil, createdAt: 0)
    state.profileOrder.append("work")
    var window = BrowserWindow(id: "w", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["t"]
    window.activeTabIds[profile] = "t"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.tabs["t"] = Tab(id: "t", windowId: "w", profileId: profile, url: "https://example.test", now: 0)
    return Store(state: state, checksInvariants: false)
  }

  @Test func overflowReservesCastSlotAndRetainsBadgeContrastAndPopup() {
    let rows: [JSONObject] = [["id": "a", "name": "Alpha", "pinned": true], ["id": "b", "name": "Beta", "pinned": true]]
    let states: JSONObject = ["a": ["badgeText": "2", "badgeColor": "#FFFFFF", "title": "Page title", "enabled": false]]
    let full = ExtensionToolbarProjection.make(rows: rows, states: states, popup: "a", limit: 5, routes: [], webkit: false, accent: "red")
    #expect(full["width"] == 64)
    #expect(full["buttons"]?.array?.first?["badge"]?["textColor"] == "#000000")
    #expect(full["buttons"]?.array?.first?["dimmed"] == true)
    #expect(full["buttons"]?.array?.first?["active"] == true)
    let tight = ExtensionToolbarProjection.make(rows: rows, states: states, popup: nil, limit: 2, routes: [["sink": "TV"]], webkit: false, accent: "red")
    #expect(tight["buttons"]?.array?.compactMap { $0["id"]?.string } == ["ext-cast", "ext-overflow"])
    #expect(tight["width"] == 64)
  }

  @Test func webkitReplacesAllExtensionsIncludingCast() {
    let result = ExtensionToolbarProjection.make(rows: [["pinned": true]], states: [:], popup: nil, limit: 0, routes: [["sink": "TV"]], webkit: true, accent: "red")
    #expect(result["width"] == 84)
    #expect(result["buttons"]?.array?.count == 1)
    #expect(result["buttons"]?.array?.first?["info"]?["actionId"] == "webkit:openInChromium")
  }

  @Test func menusPreserveLabelsEligibilityAndManagedRemoval() {
    let row: JSONObject = ["id": "a", "name": "Alpha", "enabled": true, "pinned": true, "optionsUrl": "options", "sidePanel": "panel", "mayModify": false]
    let menu = ExtensionToolbarProjection.menu(row, panelOpen: true)
    #expect(menu.first { $0["id"] == "options" }?["enabled"] == true)
    #expect(menu.first { $0["id"] == "sidePanel" }?["title"] == "Close Side Panel")
    #expect(menu.first { $0["id"] == "pin" }?["title"] == "Unpin from Toolbar")
    #expect(menu.first { $0["id"] == "remove" }?["enabled"] == false)
    let disabled = ExtensionToolbarProjection.menu(["name": "Disabled", "enabled": false], panelOpen: false)
    #expect(!disabled.contains { $0["id"] == "sidePanel" })
    #expect(disabled.first { $0["id"] == "options" }?["enabled"] == false)
    let overflow = ExtensionToolbarProjection.overflow([row])
    #expect(overflow.first?["id"] == "open:a")
    #expect(overflow.suffix(3).compactMap { $0["id"]?.string } == ["pin", "manage", "add"])
  }
}
