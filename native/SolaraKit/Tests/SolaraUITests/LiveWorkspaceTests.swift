import Foundation
import SolaraLive
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
@Suite struct LiveWorkspaceTests {
  private func fixture() -> Store {
    Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "live")), checksInvariants: true, clock: { 1_000 })
  }

  private func makeWindow(_ store: Store, _ options: JSONValue = [:]) throws -> String {
    try #require(try store.dispatch(Command("createWindow", [options])).result?.string)
  }

  @Test func deletingAFolderClosesItsOpenTabsAndReconcilesGroupMembership() throws {
    let store = fixture()
    let window = try makeWindow(store)
    let other = try #require(store.state.activeTabId(window))
    func item(_ folder: String) throws -> String {
      let tab = try #require(try store.dispatch(Command("newTab", [.string(window), ["url": "https://example.test/"]])).result?.string)
      try store.dispatch(Command("updateTab", [.string(tab), ["liveItem": ["folderId": .string(folder), "itemId": .string(tab)]]]))
      return tab
    }
    let first = try item("delete")
    let second = try item("delete")
    let keep = try item("keep")
    let emptyGroup = try #require(try store.dispatch(Command("createGroup", [JSONValue([first])])).result?.string)
    let mixedGroup = try #require(try store.dispatch(Command("createGroup", [JSONValue([second, keep])])).result?.string)

    try LiveWorkspace.closeFolderTabs("delete", in: store)

    #expect(store.state.tabs[first] == nil && store.state.tabs[second] == nil)
    #expect(store.state.tabs[other] != nil && store.state.tabs[keep] != nil)
    #expect(store.state.groups[emptyGroup] == nil)
    #expect(store.state.groups[mixedGroup]?.tabIds == [keep])
  }

  @Test func liveLinksDetachWhenPinnedOrMissingTheirFolder() throws {
    let store = fixture()
    let window = try makeWindow(store)
    func open(_ folder: String, _ item: String) throws -> String {
      try #require(try store.dispatch(Command("openSidebarLiveItem", [
        .string(window), .string(folder), .string(item), "https://example.test/", true,
      ])).result?.string)
    }
    let pinned = try open("keep", "pinned")
    let orphan = try open("missing", "orphan")
    let retained = try open("keep", "retained")
    try store.dispatch(Command("togglePin", [.string(pinned)]))

    try LiveWorkspace.detachItemLinks(in: store, knownFolders: ["keep"])

    #expect(store.state.tabs[pinned]?.pinned == true)
    #expect(store.state.tabs[pinned]?.liveItem == nil)
    #expect(store.state.tabs[orphan]?.url == "https://example.test/")
    #expect(store.state.tabs[orphan]?.liveItem == nil)
    #expect(store.state.tabs[retained]?.liveItem?["folderId"]?.string == "keep")
  }

  @Test func openingAnItemReusesItsTabInTheSameWindowAndProfile() throws {
    let store = fixture()
    let window = try makeWindow(store)
    let other = try makeWindow(store)
    let initial = store.state.activeTabId(window)
    func open(_ target: String, _ folder: String = "folder", background: Bool) throws -> String {
      try #require(try store.dispatch(Command("openSidebarLiveItem", [
        .string(target), .string(folder), "item", "https://example.test/", .bool(background),
      ])).result?.string)
    }

    let first = try open(window, background: true)
    #expect(store.state.activeTabId(window) == initial)
    try store.dispatch(Command("updateTab", [.string(first), ["url": "https://example.test/navigated"]]))
    let again = try open(window, background: true)
    #expect(again == first)
    #expect(store.state.activeTabId(window) == initial)
    let shown = try open(window, background: false)
    #expect(shown == first)
    #expect(store.state.activeTabId(window) == first)
    #expect(store.state.tabs[first]?.url == "https://example.test/navigated")
    let separateWindow = try open(other, background: true)
    let separateFolder = try open(window, "another", background: true)
    #expect(separateWindow != first && separateFolder != first)
  }

  @Test func openingAnItemSkipsPinnedLinksAndPrivateWindows() throws {
    let store = fixture()
    let window = try makeWindow(store)
    let privateWindow = try makeWindow(store, ["incognito": true])
    func open(_ target: String) throws -> String? {
      try store.dispatch(Command("openSidebarLiveItem", [
        .string(target), "folder", "item", "https://example.test/", true,
      ])).result?.string
    }
    let pinned = try #require(try open(window))
    try store.dispatch(Command("togglePin", [.string(pinned)]))
    let opened = try #require(try open(window))
    #expect(opened != pinned)
    #expect(try open(privateWindow) == nil)
  }

  @Test func deactivationOnlyNudgesAStillOpenLiveItem() throws {
    let store = fixture()
    let window = try makeWindow(store)
    let first = try #require(store.state.activeTabId(window))
    let item = try #require(try store.dispatch(Command("openSidebarLiveItem", [
      .string(window), "folder", "item", "https://example.test/", false,
    ])).result?.string)
    let before = store.state
    try store.dispatch(Command("activate", [.string(first)]))

    #expect(LiveWorkspace.deactivatedFolders(from: before, to: store.state) == ["folder"])
    #expect(LiveWorkspace.deactivatedFolders(from: before, to: before).isEmpty)

    try store.dispatch(Command("closeTabs", [JSONValue([item])]))
    #expect(LiveWorkspace.deactivatedFolders(from: before, to: store.state).isEmpty)
  }

  @Test func signInDoesNotOpenAWindowWhenOnlyPrivateAndSmallWindowsExist() async throws {
    let store = fixture()
    _ = try makeWindow(store, ["incognito": true])
    _ = try makeWindow(store, ["small": true, "url": "https://example.test/"])
    let before = store.state.windowOrder
    let presenter = LiveBrowserAuth(store: { store }, focus: { _ in Issue.record("Unexpected focus") })
    await #expect(throws: LiveAuthError("Open a browser window first")) {
      try await presenter.authorize(url: "https://example.test/auth", redirectPrefix: GoogleAuth.redirect)
    }
    #expect(store.state.windowOrder == before)
  }

  @Test func closingTheSourceWindowCancelsEvenWithAnotherRegularWindow() async throws {
    let store = fixture()
    let other = try makeWindow(store)
    let target = try makeWindow(store)
    try store.dispatch(Command("setFocusedWindow", [.string(target)]))
    let presenter = LiveBrowserAuth(store: { store }, focus: { window in
      #expect(window == target)
      #expect(store.state.activeTab(window)?.url == "https://example.test/auth")
      _ = try? store.dispatch(Command("closeWindow", [.string(window)]))
    })
    await #expect(throws: LiveAuthError("Sign-in was cancelled")) {
      try await presenter.authorize(url: "https://example.test/auth", redirectPrefix: GoogleAuth.redirect)
    }
    #expect(store.state.windowOrder == [other])
  }

  @Test func signInUsesTheRegularWindowsOwnProfileAndOnlyAcceptsItsAuthTab() async throws {
    let store = fixture()
    let profile = try #require(try store.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result?.string)
    let regular = try makeWindow(store, ["profileId": .string(profile)])
    let existing = try #require(store.state.activeTabId(regular))
    let privateWindow = try makeWindow(store, ["incognito": true])
    try store.dispatch(Command("setFocusedWindow", [.string(privateWindow)]))
    let otherRedirect = GoogleAuth.redirect + "?code=not-the-auth-tab"
    let authRedirect = GoogleAuth.redirect + "?code=from-auth-tab"
    let presenter = LiveBrowserAuth(store: { store }, focus: { window in
      #expect(window == regular)
      guard let tab = store.state.activeTab(window) else {
        Issue.record("Sign-in tab missing")
        return
      }
      #expect(tab.profileId == profile)
      _ = try? store.dispatch(Command("updateTab", [.string(existing), ["url": .string(otherRedirect)]]))
      _ = try? store.dispatch(Command("updateTab", [.string(tab.id), ["url": .string(authRedirect)]]))
    }, timeout: .seconds(2))
    #expect(try await presenter.authorize(url: "https://example.test/auth", redirectPrefix: GoogleAuth.redirect) == authRedirect)
    #expect(store.state.tabs[existing]?.url == otherRedirect)
    #expect(store.state.windows[privateWindow]?.incognito == true)
  }

  @Test func timeoutClosesTheAuthTabAndLeavesTheSourceWindowOpen() async throws {
    let store = fixture()
    let target = try makeWindow(store)
    let presenter = LiveBrowserAuth(store: { store }, focus: { _ in }, timeout: .zero)
    await #expect(throws: LiveAuthError("Live authorization timed out")) {
      try await presenter.authorize(url: "https://example.test/auth", redirectPrefix: GoogleAuth.redirect)
    }
    #expect(store.state.windows[target] != nil)
    #expect(!store.state.tabs.values.contains { $0.url == "https://example.test/auth" })
  }

  @Test func cancellingTheCallerClosesTheAuthTab() async throws {
    let store = fixture()
    let target = try makeWindow(store)
    let opened = AsyncStream<Void>.makeStream()
    let presenter = LiveBrowserAuth(store: { store }, focus: { _ in opened.continuation.yield() })
    let request = Task { try await presenter.authorize(url: "https://example.test/auth", redirectPrefix: GoogleAuth.redirect) }
    for await _ in opened.stream { break }
    request.cancel()
    await #expect(throws: (any Error).self) { try await request.value }
    #expect(store.state.windows[target] != nil)
    #expect(!store.state.tabs.values.contains { $0.url == "https://example.test/auth" })
  }
}
