import Foundation
import SolaraModel
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct MediaStackTests {
  private func state(w1Profile: String = "p1") throws -> BrowserState {
    let json = #"""
    {"windows":{
      "w1":{"id":"w1","profileId":"\#(w1Profile)","tabIds":["a","b","c","d"],"activeTabIds":{"p1":"a","p2":"c"}},
      "w2":{"id":"w2","profileId":"p2","tabIds":["e"],"activeTabIds":{"p2":"e"}},
      "w3":{"id":"w3","profileId":"p1","incognito":true,"tabIds":["x","y"],"activeTabIds":{"p1":"x"}}},
     "windowOrder":["w1","w2","w3"],
     "tabs":{
      "a":{"id":"a","windowId":"w1","profileId":"p1","url":"https://a.test/"},
      "b":{"id":"b","windowId":"w1","profileId":"p1","url":"https://b.test/"},
      "c":{"id":"c","windowId":"w1","profileId":"p2","url":"https://c.test/"},
      "d":{"id":"d","windowId":"w1","profileId":"p2","url":"https://d.test/"},
      "e":{"id":"e","windowId":"w2","profileId":"p2","url":"https://e.test/"},
      "x":{"id":"x","windowId":"w3","profileId":"p1","url":"https://x.test/"},
      "y":{"id":"y","windowId":"w3","profileId":"p1","url":"https://y.test/"}}}
    """#
    return try BrowserState(stateJSON: JSONValue.parse(json).object ?? [:])
  }

  private func makeStore() -> NowPlayingStore {
    let store = NowPlayingStore()
    var tick = 0.0
    store.now = {
      tick += 1
      return tick
    }
    return store
  }

  private let playing = NowPlayingReport(title: "T", playbackState: "playing", controllable: true)
  private let paused = NowPlayingReport(title: "T", playbackState: "paused", controllable: true)

  @Test func theStackTakesEveryProfileMostRecentFirstAndHoldsThree() throws {
    let state = try state()
    let store = makeStore()
    for id in ["a", "c", "e", "b"] { store.report(tabId: id, playing) }
    let ids = MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId)
    #expect(ids == ["b", "e", "c"])
    let profiles = MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.profileId)
    #expect(profiles == ["p1", "p2", "p2"])
  }

  @Test func aVideoThatLosesThePictureInPicturePausesWithoutComingToTheFront() throws {
    let state = try state()
    let store = makeStore()
    for id in ["a", "c"] { store.report(tabId: id, playing) }
    store.holdOrder("a")
    store.touch("c")
    store.report(tabId: "a", paused)
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["c", "a"])
    store.report(tabId: "a", playing)
    store.report(tabId: "a", paused)
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["a", "c"])
  }

  @Test func aHeldOrderExpires() throws {
    let state = try state()
    let store = NowPlayingStore()
    var clock = 0.0
    store.now = { clock }
    store.report(tabId: "a", playing)
    clock = 10
    store.report(tabId: "c", playing)
    store.holdOrder("a")
    clock = 10 + NowPlayingStore.holdOrderMs + 1
    store.report(tabId: "a", paused)
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["a", "c"])
  }

  @Test func pausingOrTouchingMovesACardToTheFrontButShowingDoesNot() throws {
    let state = try state()
    let store = makeStore()
    for id in ["a", "c", "e"] { store.report(tabId: id, playing) }
    store.report(tabId: "a", paused)
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["a", "e", "c"])
    store.touch("c")
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["c", "a", "e"])
    store.report(tabId: "e", NowPlayingReport(title: "New title", playbackState: "playing", position: 9, controllable: true))
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["c", "a", "e"])
  }

  @Test func aRemovedCardStaysGoneUntilItsVideoPlaysAgain() throws {
    let state = try state()
    let store = makeStore()
    store.report(tabId: "a", playing)
    store.report(tabId: "c", playing)
    store.remove("a")
    store.report(tabId: "a", paused)
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["c"])
    store.report(tabId: "a", playing)
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["a", "c"])
  }

  @Test func privateMediaStaysInPrivateWindowsAndNormalMediaStaysOut() throws {
    let state = try state()
    let store = makeStore()
    store.report(tabId: "a", playing)
    store.report(tabId: "x", playing)
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).map(\.tabId) == ["a"])
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .incognito).map(\.tabId) == ["x"])
  }

  @Test func unplayedUncontrollableAndClosedTabsAreLeftOut() throws {
    let state = try state()
    let store = makeStore()
    store.report(tabId: "a", paused)
    store.report(tabId: "b", NowPlayingReport(playbackState: "playing", controllable: false))
    store.report(tabId: "gone", playing)
    store.report(tabId: "c", playing)
    store.report(tabId: "c", NowPlayingReport(playbackState: "none", controllable: true))
    #expect(MediaStack.entries(state: state, store: store.entries, kind: .normal).isEmpty)
    store.retain(tabIds: Set(state.tabs.keys))
    #expect(store.entries["gone"] == nil)
    store.report(tabId: "a", nil)
    #expect(store.entries["a"] == nil)
  }

  @Test func everyProfileShowsTheSameStackAndHidesItWhereTheFrontVideoIsOnScreen() throws {
    let personal = try state()
    let work = try state(w1Profile: "p2")
    let store = makeStore()
    for id in ["a", "c", "e"] { store.report(tabId: id, playing) }
    let shared = MediaStack.entries(state: personal, store: store.entries, kind: .normal)
    #expect(shared.map(\.tabId) == ["e", "c", "a"])
    #expect(MediaStack.watched(state: personal, windowId: "w1") == ["a"])
    #expect(MediaStack.visible(shared, state: personal, windowId: "w1").map(\.tabId) == ["e", "c", "a"])
    #expect(MediaStack.visible(shared, state: work, windowId: "w1").map(\.tabId) == ["e", "c", "a"])
    #expect(MediaStack.visible(shared, state: personal, windowId: "w2").isEmpty)
    #expect(MediaStack.entries(state: personal, store: store.entries, kind: .normal) == shared)
  }

  @Test func switchingProfilesNeverSwapsTheFrontCardItOnlyShowsOrHidesTheStack() throws {
    let personal = try state()
    let work = try state(w1Profile: "p2")
    let store = makeStore()
    for id in ["a", "e", "c"] { store.report(tabId: id, playing) }
    let shared = MediaStack.entries(state: personal, store: store.entries, kind: .normal)
    #expect(shared.map(\.tabId) == ["c", "e", "a"])
    #expect(MediaStack.visible(shared, state: work, windowId: "w1").isEmpty)
    let shown = MediaStack.visible(shared, state: personal, windowId: "w1")
    #expect(shown.map(\.tabId) == ["c", "e", "a"])
    #expect(shown.first?.tabId == shared.first?.tabId)
  }

  @Test func onlyWhatACardShowsPostsAChangeAndAtMostOncePerTurn() {
    let store = makeStore()
    var posts = 0
    let observer = NotificationCenter.default.addObserver(forName: NowPlayingStore.didChange, object: store, queue: nil) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    let spin = { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    store.report(tabId: "a", playing)
    store.report(tabId: "b", playing)
    store.remove("b")
    spin()
    #expect(posts == 1)
    store.report(tabId: "a", NowPlayingReport(title: "T", playbackState: "playing", position: 30, timestamp: 99, controllable: true))
    spin()
    #expect(posts == 1)
    #expect(store.entries["a"]?.report.position == 30)
    store.report(tabId: "a", NowPlayingReport(title: "Other", playbackState: "playing", position: 31, controllable: true))
    spin()
    #expect(posts == 2)
  }

  @Test func aReportParsesThePagePayload() {
    let report = NowPlayingReport(payload: ["state": ["title": "Song", "artist": "Band", "playbackState": "playing", "position": 12.5, "duration": 200,
      "playbackRate": 1, "timestamp": 1000, "hasVideo": true, "controllable": true, "actions": ["play", "pause"]]])
    #expect(report?.title == "Song" && report?.playing == true && report?.duration == 200 && report?.hasVideo == true)
    #expect(NowPlayingReport(payload: ["state": NSNull()]) == nil)
    #expect(NowPlayingReport(payload: ["state": ["playbackState": "weird"]])?.playbackState == "none")
    #expect(NowPlayingReport(playbackState: "paused", position: 199.9, duration: 200).ended)
    let json = try? JSONValue.parse(#"{"state":{"title":"Song","playbackState":"paused","position":3,"controllable":true,"actions":["play"]}}"#)
    let parsed = json.flatMap { NowPlayingReport(json: $0) }
    #expect(parsed?.title == "Song" && parsed?.playbackState == "paused" && parsed?.controllable == true && parsed?.actions == ["play"])
    #expect((try? JSONValue.parse(#"{"state":null}"#)).flatMap { NowPlayingReport(json: $0) } == nil)
  }
}
