import SolaraEngine
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct BookmarkMenuCommandTests {
  private func state() -> BrowserState {
    var s = BrowserState(settings: Settings.hydrated(from: nil))
    var w = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    w.tabIds = ["a"]
    w.activeTabIds["default"] = "a"
    s.windows["w"] = w
    s.windowOrder = ["w"]
    s.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: "", now: 0)
    return s
  }

  private func snapshot(engine: String = "", url: String = "https://bookmark.example/", hasView: Bool = true) -> BookmarkWriterSnapshot {
    BookmarkWriterSnapshot(binding: BookmarkWriterBinding(engine: engine, generation: 1), revision: 1,
      ready: false, hasView: hasView, document: ["nodes": [
        "bar": ["kind": "folder", "children": ["same" ]],
        "same": ["kind": "url", "url": .string(url)],
      ]], facts: [:])
  }

  private func plan(_ arg: String = "same", _ s: BrowserState? = nil, _ view: BookmarkWriterSnapshot? = nil) -> BookmarkOpenPlan? {
    BookmarkMenuCommand.plan(command: "openBookmark", arg: arg, windowId: "w", state: s ?? state(), closing: [], snapshot: view ?? snapshot())
  }
  @Test func urlNavigatesABlankTargetFromAReadOnlyView() throws {
    let p = try #require(plan())
    #expect(p.urls == ["https://bookmark.example/"])
    #expect(p.tab?.id == "a")
    #expect(p.mode == "current")
  }
  @Test func foldersDeletedAndUnloadedCatalogsAreNoOps() {
    #expect(plan("bar") == nil)
    #expect(plan("deleted") == nil)
    #expect(plan("same", nil, snapshot(hasView: false)) == nil)
    #expect(plan("same", nil, snapshot(url: "")) == nil)
  }
  @Test func sameIdIsScopedToTheEngineAndPrivateOriginalProfile() throws {
    #expect(plan("same", nil, snapshot(engine: "other")) == nil)
    var other = state()
    other.profiles["work"] = Profile(id: "work", name: "Work", color: "blue", icon: nil, createdAt: 0)
    other.windows["w"]?.profileId = "work"
    other.windows["w"]?.activeTabIds["work"] = "a"
    other.tabs["a"]?.profileId = "work"
    #expect(try #require(plan("same", other, snapshot(engine: "work", url: "https://work.example/"))).urls == ["https://work.example/"])
    var s = state()
    s.windows["w"]?.incognito = true
    s.windows["w"]?.originalProfileId = "default"
    s.windows["w"]?.profileId = "incognito:w@default"
    s.windows["w"]?.activeTabIds["incognito:w@default"] = "a"
    s.tabs["a"]?.profileId = "incognito:w@default"
    #expect(try #require(plan("same", s)).engine == "")
    #expect(plan("same", s, snapshot(engine: "incognito:w@default")) == nil)
  }
  @Test func peekAndLittleSolaraUseTheirOwnTargets() throws {
    var s = state()
    s.windows["w"]?.kind = "small"
    #expect(try #require(plan("same", s)).tab?.id == "a")
    s.windows["w"]?.kind = nil
    let store = makeUIStore(s)
    try store.dispatch(Command("openPeek", ["a", "https://peek.example/"]), origin: .native)
    #expect(try #require(plan("same", store.state)).tab?.id == store.state.peeks["w"]?.tabId)
  }
  @Test func noWindowAndClosingWindowAreNoOps() {
    #expect(plan("same", BrowserState(settings: Settings.hydrated(from: nil))) == nil)
    #expect(BookmarkMenuCommand.plan(command: "openBookmark", arg: "same", windowId: "w", state: state(), closing: ["w"], snapshot: snapshot()) == nil)
  }
  @Test func confirmationReceiptRejectsChangedTargetAndCatalog() throws {
    let before = try #require(plan())
    var changed = state()
    changed.tabs["a"]?.url = "https://new.example/"
    #expect(plan("same", changed) != before)
    #expect(plan("same", nil, snapshot(url: "https://changed.example/")) != before)
    #expect(plan("same", nil, snapshot(engine: "other")) != before)
    let view = snapshot()
    let replaced = BookmarkWriterSnapshot(binding: BookmarkWriterBinding(engine: "", generation: 2), revision: view.revision,
      ready: false, hasView: true, document: view.document, facts: [:])
    #expect(plan("same", nil, replaced) != before)
  }
  @Test func folderOrderAndModesAreNative() throws {
    let p = try #require(BookmarkMenuCommand.plan(command: "openBookmarkItems", arg: #"{"id":"bar","mode":"tabs"}"#,
      windowId: "w", state: state(), closing: [], snapshot: snapshot()))
    #expect(p.urls == ["https://bookmark.example/"])
    #expect(p.mode == "tabs")
    for mode in ["background", "foreground", "window", "incognito", "split"] {
      let p = BookmarkMenuCommand.plan(command: "openBookmarkItems", arg: "{\"id\":\"same\",\"mode\":\"\(mode)\"}",
        windowId: "w", state: state(), closing: [], snapshot: snapshot())
      #expect(p?.mode == mode)
    }
  }
}
