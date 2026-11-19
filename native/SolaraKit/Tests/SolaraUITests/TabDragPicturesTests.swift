import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func pictureState(active: String = "a", url: String = "https://a.example/", split: Bool = false, incognito: Bool = false, tabs: [String] = ["a", "b", "c"]) throws -> BrowserState {
  let tabJSON = tabs.map { id in
    let address = id == "a" ? url : id == "c" ? "" : "https://\(id).example/"
    return #""\#(id)": {"id": "\#(id)", "windowId": "w1", "profileId": "p", "url": "\#(address)", "title": "\#(id == "c" ? "" : id.uppercased())", "favicon": "https://\#(id).example/icon.png"}"#
  }.joined(separator: ",")
  let splits = split ? #", "splits": {"s1": {"id": "s1", "windowId": "w1", "tabIds": ["a", "b"], "orientation": "horizontal", "sizes": [0.5, 0.5]}}"# : ""
  let text = #"""
    {"windows": {"w1": {"id": "w1", "profileId": "p", "incognito": \#(incognito), "tabIds": \#(tabs), "activeTabIds": {"p": "\#(active)"}}},
     "windowOrder": ["w1"], "tabs": {\#(tabJSON)}\#(splits)}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private let none: @Sendable (String) -> Bool = { _ in false }

@MainActor
@Suite struct TabDragPicturesTests {
  @Test func theDraggedActiveTabIsCapturedLiveWithItsPlaceholderBehind() throws {
    let plan = TabDragPagePlan.make(try pictureState(), windowId: "w1", draggedTabId: "a", hasPicture: none)
    #expect(plan.liveTabId == "a")
    #expect(plan.fallback == .placeholder(title: "A", favicon: "https://a.example/icon.png"))
  }

  @Test func withNoDraggedTabTheActiveTabIsShown() throws {
    let plan = TabDragPagePlan.make(try pictureState(), windowId: "w1", draggedTabId: nil, hasPicture: none)
    #expect(plan.liveTabId == "a")
  }

  @Test func aBackgroundTabUsesItsLastPictureThenAPlaceholder() throws {
    let state = try pictureState()
    #expect(TabDragPagePlan.make(state, windowId: "w1", draggedTabId: "b", hasPicture: { $0 == "b" }) == TabDragPagePlan(liveTabId: nil, fallback: .picture(tabId: "b")))
    #expect(TabDragPagePlan.make(state, windowId: "w1", draggedTabId: "b", hasPicture: none).fallback == .placeholder(title: "B", favicon: "https://b.example/icon.png"))
  }

  @Test func aSplitPaneOfTheActiveTabIsOnScreen() throws {
    #expect(TabDragPagePlan.make(try pictureState(split: true), windowId: "w1", draggedTabId: "b", hasPicture: none).liveTabId == "b")
  }

  @Test func anOnScreenBlankTabHasNoFallback() throws {
    let plan = TabDragPagePlan.make(try pictureState(active: "c"), windowId: "w1", draggedTabId: "c", hasPicture: { _ in true })
    #expect(plan == TabDragPagePlan(liveTabId: "c", fallback: .none))
  }

  @Test func anOffScreenBlankTabTitlesItselfNewTab() throws {
    let plan = TabDragPagePlan.make(try pictureState(), windowId: "w1", draggedTabId: "c", hasPicture: none)
    #expect(plan.fallback == .placeholder(title: "New Tab", favicon: "https://c.example/icon.png"))
  }

  @Test func picturesSettleBeforeTheyAreTakenAndOnlyForTheStillActiveTab() throws {
    let pictures = TabDragPictures()
    var queued: [(TimeInterval, @MainActor () -> Void)] = []
    var captured: [String] = []
    var state = try pictureState()
    pictures.current = { state }
    pictures.after = { delay, work in queued.append((delay, work)) }
    pictures.capture = { id, done in
      captured.append(id)
      done(PagePicture(data: id, frame: [0, 0, 1, 1]))
    }
    let before = state
    state = try pictureState(active: "b")
    pictures.changed(from: before, to: state, windows: true, tabs: false)
    #expect(queued.map(\.0) == [TabDragPictures.settle])
    let switched = state
    state = try pictureState(active: "a")
    pictures.changed(from: switched, to: state, windows: true, tabs: false)
    for (_, work) in queued { work() }
    #expect(captured == ["a"])
    #expect(pictures.picture("a")?.data == "a")
    #expect(pictures.picture("b") == nil)
  }

  @Test func unchangedTablesAndPrivateWindowsSchedulesNothing() throws {
    let pictures = TabDragPictures()
    var queued = 0
    pictures.after = { _, _ in queued += 1 }
    let state = try pictureState()
    pictures.changed(from: state, to: try pictureState(active: "b"), windows: false, tabs: false)
    pictures.changed(from: state, to: try pictureState(active: "b", incognito: true), windows: true, tabs: false)
    pictures.changed(from: state, to: state, windows: true, tabs: true)
    #expect(queued == 0)
  }

  @Test func aNavigationOfTheActiveTabRetakesItsPicture() throws {
    let pictures = TabDragPictures()
    var queued = 0
    pictures.after = { _, _ in queued += 1 }
    pictures.changed(from: try pictureState(), to: try pictureState(url: "https://a.example/next"), windows: false, tabs: true)
    #expect(queued == 1)
  }

  @Test func closedTabsForgetTheirPicturesAndOnlyFortyAreKept() throws {
    let ids = (0..<45).map { "t\($0)" }
    let pictures = TabDragPictures()
    var state = try pictureState(tabs: ["a", "b", "c"] + ids)
    pictures.current = { state }
    pictures.after = { _, work in work() }
    pictures.capture = { id, done in done(PagePicture(data: id, frame: [0, 0, 1, 1])) }
    var previous = state
    for id in ids {
      state = try pictureState(active: id, tabs: ["a", "b", "c"] + ids)
      pictures.changed(from: previous, to: state, windows: true, tabs: false)
      previous = state
    }
    #expect(pictures.remembered == Array(ids.suffix(TabDragPictures.keep)))
    state = try pictureState(active: "a", tabs: ["a", "b", "c"] + ids.filter { $0 != "t44" })
    pictures.changed(from: previous, to: state, windows: true, tabs: true)
    #expect(pictures.picture("t44") == nil)
  }
}

@MainActor
@Suite struct TabDragPicturesResetTests {
  @Test func aStoreSwapForgetsPicturesAndCancelsPendingCaptures() throws {
    let pictures = TabDragPictures()
    var queued: [@MainActor () -> Void] = []
    var captured: [String] = []
    let state = try pictureState()
    pictures.current = { state }
    pictures.after = { _, work in queued.append(work) }
    pictures.capture = { id, done in
      captured.append(id)
      done(PagePicture(data: id, frame: [0, 0, 1, 1]))
    }
    pictures.changed(from: try pictureState(active: "b"), to: state, windows: true, tabs: false)
    for work in queued { work() }
    queued.removeAll()
    #expect(pictures.picture("a") != nil)
    pictures.changed(from: try pictureState(active: "b"), to: state, windows: true, tabs: true)
    pictures.reset()
    for work in queued { work() }
    #expect(captured == ["a"])
    #expect(pictures.picture("a") == nil)
    #expect(pictures.remembered.isEmpty)
  }
}
