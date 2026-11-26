import Foundation
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized) struct MediaSessionLifetimeTests {
  private let playing: JSONValue = ["state": ["playbackState": "playing", "controllable": true, "hasVideo": true]]
  private let paused: JSONValue = ["state": ["playbackState": "paused", "controllable": true, "hasVideo": true]]

  @Test(arguments: [PageHost.pooled, .reactNative])
  func retiringPageClearsSession(host: PageHost) throws {
    let fixture = try IssuerFixture(host: host)
    let issuer = fixture.issuer
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.report.playing == true)
    issuer.retire(fixture.binding)
    #expect(NowPlayingStore.shared.entries[fixture.id] == nil)
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: paused)
    #expect(NowPlayingStore.shared.entries[fixture.id] == nil)
  }

  @Test func mediaEventsDoNotRequireDeliveryToJavaScript() throws {
    let fixture = try IssuerFixture()
    defer { fixture.issuer.retire(fixture.binding) }
    #expect(fixture.issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing) == nil)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.report.playing == true)
    #expect(fixture.issuer.reserveEvent(fixture.binding, name: "onPictureInPicture", payload: ["kind": "document", "active": true]) == nil)
  }

  @Test func replacementFencesThePreviousPageAndOwnsNewReports() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    let issuer = fixture.issuer
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    let nextOwner = IssuerProducer()
    let next = try #require(issuer.attach(tabId: fixture.id, engine: .chromium, host: .pooled,
      owner: nextOwner, context: fixture.binding.context, perform: nextOwner.perform))
    defer { issuer.retire(next) }
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    #expect(NowPlayingStore.shared.entries[fixture.id] == nil)
    _ = issuer.reserveEvent(next, name: "onNowPlaying", payload: playing)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.report.playing == true)
    issuer.endMedia()
    _ = issuer.reserveEvent(next, name: "onNowPlaying", payload: playing)
    #expect(NowPlayingStore.shared.entries[fixture.id] == nil)
  }

  @Test func samePhysicalPageKeepsItsDismissalAcrossHostHandoff() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    let issuer = fixture.issuer
    let physical = NSObject()
    issuer.associateNativePage(fixture.binding, page: physical)
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    _ = issuer.reserveEvent(fixture.binding, name: "onPictureInPicture", payload: ["kind": "video", "active": true])
    NowPlayingStore.shared.remove(fixture.id)
    let nextOwner = IssuerProducer()
    let next = try #require(issuer.attach(tabId: fixture.id, engine: .chromium, host: .pooled,
      owner: nextOwner, context: fixture.binding.context, perform: nextOwner.perform))
    defer { issuer.retire(next) }
    #expect(NowPlayingStore.shared.protectionReason(tabId: fixture.id, pinned: false) == nil)
    issuer.associateNativePage(next, page: physical)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.removed == true)
    #expect(NowPlayingStore.shared.protectionReason(tabId: fixture.id, pinned: false) == "picture in picture")
  }

  @Test func windowMoveKeepsMediaOnTheRetainedPage() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    let issuer = fixture.issuer
    let physical = NSObject()
    issuer.associateNativePage(fixture.binding, page: physical)
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    _ = issuer.reserveEvent(fixture.binding, name: "onPictureInPicture", payload: ["kind": "video", "active": true])
    let destination = try #require(try fixture.store.dispatch(Command("createWindow", [])).result?.string)
    try fixture.store.dispatch(Command("moveTabsToWindow", [[.string(fixture.id)], .string(destination)]))
    issuer.pruneMedia()
    var context = fixture.binding.context
    context.navigationSeq = fixture.store.state.tabs[fixture.id]?.navigation.flatMap { Int(exactly: $0.seq) }
    #expect(context.navigationSeq != fixture.binding.context.navigationSeq)
    let owner = IssuerProducer()
    let next = try #require(issuer.attach(tabId: fixture.id, engine: .chromium, host: .pooled,
      owner: owner, context: context, perform: owner.perform))
    defer { issuer.retire(next) }
    issuer.associateNativePage(next, page: physical)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.report.playing == true)
    #expect(NowPlayingStore.shared.pictureInPicture[fixture.id] == "video")
  }

  @Test func aNewHostEndReportSupersedesTheHandoffSnapshot() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    let issuer = fixture.issuer
    let physical = NSObject()
    issuer.associateNativePage(fixture.binding, page: physical)
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    _ = issuer.reserveEvent(fixture.binding, name: "onPictureInPicture", payload: ["kind": "video", "active": true])
    let owner = IssuerProducer()
    let next = try #require(issuer.attach(tabId: fixture.id, engine: .chromium, host: .pooled,
      owner: owner, context: fixture.binding.context, perform: owner.perform))
    defer { issuer.retire(next) }
    _ = issuer.reserveEvent(next, name: "onNowPlaying", payload: ["state": .null])
    _ = issuer.reserveEvent(next, name: "onMediaAccess", payload: ["microphone": true])
    issuer.associateNativePage(next, page: physical)
    #expect(NowPlayingStore.shared.entries[fixture.id] == nil)
    #expect(NowPlayingStore.shared.pictureInPicture[fixture.id] == "video")
    #expect(NowPlayingStore.shared.capture[fixture.id] == .camera)
  }

  @Test func anEndedWorkspaceCannotClearItsSuccessorsMedia() throws {
    let fixture = try IssuerFixture()
    fixture.issuer.endMedia()
    let nextIssuer = PageIssuer(store: fixture.store, registry: PageRegistry())
    let owner = IssuerProducer()
    let next = try #require(nextIssuer.attach(tabId: fixture.id, engine: .chromium, host: .pooled,
      owner: owner, context: fixture.binding.context, perform: owner.perform))
    defer { nextIssuer.retire(next) }
    _ = nextIssuer.reserveEvent(next, name: "onNowPlaying", payload: playing)
    fixture.issuer.endMedia()
    #expect(NowPlayingStore.shared.entries[fixture.id]?.report.playing == true)
    _ = nextIssuer.reserveEvent(next, name: "onNowPlaying", payload: playing)
    fixture.issuer.retire(fixture.binding)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.report.playing == true)
  }

  @Test func replacingThePhysicalPageClearsMediaOnTheExistingBinding() throws {
    let fixture = try IssuerFixture()
    let issuer = fixture.issuer
    let original = NSObject()
    let replacement = NSObject()
    issuer.associateNativePage(fixture.binding, page: original)
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    _ = issuer.reserveEvent(fixture.binding, name: "onPictureInPicture", payload: ["kind": "video", "active": true])
    issuer.associateNativePage(fixture.binding, page: replacement)
    #expect(NowPlayingStore.shared.entries[fixture.id] == nil)
    #expect(NowPlayingStore.shared.pictureInPicture[fixture.id] == nil)
    _ = issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: paused)
    let owner = IssuerProducer()
    let next = try #require(issuer.attach(tabId: fixture.id, engine: .chromium, host: .reactNative,
      owner: owner, context: fixture.binding.context, perform: owner.perform))
    defer { issuer.retire(next) }
    issuer.associateNativePage(next, page: replacement)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.report.playbackState == "paused")
    #expect(NowPlayingStore.shared.pictureInPicture[fixture.id] == nil)
  }

  @Test func closePausesOnceAndLeavesTheSelectedTabAlone() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    defer { fixture.issuer.retire(fixture.binding) }
    let window = try #require(fixture.store.state.tabs[fixture.id]?.windowId)
    let different = try #require(try fixture.store.dispatch(Command("newTab", [.string(window), ["url": "https://different.test/"]])).result?.string)
    _ = try fixture.store.dispatch(Command("activate", [.string(different)]))
    _ = fixture.issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    fixture.issuer.dismissMedia(tabId: fixture.id, identity: fixture.binding.identity)
    fixture.issuer.dismissMedia(tabId: fixture.id, identity: fixture.binding.identity)
    #expect(fixture.producer.commands == [.mediaCommand("pause", 0)])
    #expect(fixture.store.state.activeTabId(window) == different)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.removed == true)
    _ = fixture.issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: paused)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.removed == true)
    _ = fixture.issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: ["state": .null])
    #expect(NowPlayingStore.shared.entries[fixture.id] == nil)
    _ = fixture.issuer.reserveEvent(fixture.binding, name: "onNowPlaying", payload: playing)
    #expect(NowPlayingStore.shared.entries[fixture.id]?.removed == false)
  }

  @Test func pictureInPictureExitRequiresAConsumedPress() throws {
    let fixture = try IssuerFixture()
    defer { fixture.issuer.retire(fixture.binding) }
    let issuer = fixture.issuer
    let id = fixture.id
    let identity = fixture.binding.identity
    _ = issuer.reserveEvent(fixture.binding, name: "onPictureInPicture", payload: ["kind": "document", "active": true])
    issuer.toggleMediaPictureInPicture(tabId: id, identity: identity, clickAt: 0)
    #expect(fixture.producer.commands.isEmpty)
    fixture.producer.invoke = { _, finish in finish(.success(.bool(false))) }
    issuer.toggleMediaPictureInPicture(tabId: id, identity: identity, clickAt: 10)
    #expect(fixture.producer.commands == [.takeControlPress(10, 0)])
    fixture.producer.invoke = { command, finish in
      finish(.success(command == .takeControlPress(11, 0) ? .bool(true) : .null))
    }
    issuer.toggleMediaPictureInPicture(tabId: id, identity: identity, clickAt: 11)
    #expect(fixture.producer.commands == [.takeControlPress(10, 0), .takeControlPress(11, 0),
      .executeJavaScript("window.documentPictureInPicture?.window?.close()")])
  }

  @Test func sharedOrderingAndPrivateVisibilitySurvivePictureInPictureAndDismissal() throws {
    let json = """
      {"windows":{"a":{"id":"a","profileId":"p","tabIds":["x"],"activeTabIds":{"p":"x"}},
        "b":{"id":"b","profileId":"q","tabIds":["y"],"activeTabIds":{"q":"y"}},
        "c":{"id":"c","profileId":"p","incognito":true,"tabIds":["z"],"activeTabIds":{"p":"z"}}},
        "tabs":{"x":{"id":"x","windowId":"a","profileId":"p","url":"https://x.test/"},
        "y":{"id":"y","windowId":"b","profileId":"q","url":"https://y.test/"},
        "z":{"id":"z","windowId":"c","profileId":"p","url":"https://z.test/"}}}
      """
    let state = try BrowserState(stateJSON: JSONValue.parse(json).object ?? [:])
    let media = NowPlayingStore()
    var time = 0.0
    media.now = { time += 1; return time }
    for id in ["x", "y", "z"] { media.report(tabId: id, NowPlayingReport(json: playing)) }
    media.setPictureInPicture(tabId: "x", kind: "video", active: true)
    #expect(MediaStack.entries(state: state, store: media.entries, kind: .normal).map(\.tabId) == ["x", "y"])
    #expect(MediaStack.entries(state: state, store: media.entries, kind: .incognito).map(\.tabId) == ["z"])
    media.remove("x")
    #expect(MediaStack.entries(state: state, store: media.entries, kind: .normal).map(\.tabId) == ["y"])
  }
}
