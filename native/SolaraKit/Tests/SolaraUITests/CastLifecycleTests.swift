import Testing
import SolaraUI

@MainActor
struct CastLifecycleTests {
  private let page = CastLifecycle.Page(tabID: "tab", windowID: "window", profile: "personal", browserID: 42, generation: 1)
  private let replacement = CastLifecycle.Page(tabID: "tab", windowID: "window", profile: "personal", browserID: 43, generation: 2)
  private let sink = CastLifecycle.Sink(id: "sink", name: "Living Room", icon: 0, state: "available", modes: 7, routeID: "", status: "", issue: "")

  @Test func togglingCancelsPendingOpenAndClosesOnce() {
    var cast = CastLifecycle()
    #expect(cast.toggle(page) == .show(42))
    #expect(cast.toggle(page) == nil)
    #expect(cast.receive(.init(id: 4, browserID: 42, open: true, sinks: [sink]), page: page) == [4])
    #expect(cast.dialogs.isEmpty)
    #expect(cast.toggle(page) == .show(42))
    #expect(cast.receive(.init(id: 5, browserID: 42, open: true), page: page).isEmpty)
    #expect(cast.toggle(page) == .close(5))
    #expect(cast.receive(.init(id: 5, browserID: 42, open: true), page: page).isEmpty)
    #expect(cast.dialogs.isEmpty)
  }

  @Test func repeatedTogglesUseTheLatestIntentUntilThePageIsLost() {
    var cast = CastLifecycle()
    _ = cast.toggle(page)
    _ = cast.toggle(page)
    _ = cast.toggle(page)
    #expect(cast.receive(.init(id: 4, browserID: 42, open: true), page: page).isEmpty)
    #expect(cast.toggle(page) == .close(4))
    _ = cast.toggle(page)
    _ = cast.prune { _ in nil }
    _ = cast.toggle(page)
    #expect(cast.receive(.init(id: 5, browserID: 42, open: true), page: page) == [5])
  }

  @Test func anOldTimeoutCannotClearTheNewOpen() throws {
    var cast = CastLifecycle()
    _ = cast.toggle(page)
    let expired = try #require(cast.pendingToken(for: page))
    cast.finishPending(page, token: expired)
    _ = cast.toggle(page)
    cast.finishPending(page, token: expired)
    #expect(cast.pendingToken(for: page) != nil)
  }

  @Test func replacementAndContextLossCloseOnlyTheOldDialog() {
    var cast = CastLifecycle()
    _ = cast.receive(.init(id: 4, browserID: 42, open: true), page: page)
    #expect(cast.prune { _ in replacement } == [4])
    #expect(cast.receive(.init(id: 5, browserID: 43, open: true), page: replacement).isEmpty)
    #expect(cast.receive(.init(id: 4, browserID: 42, open: false), page: nil).isEmpty)
    #expect(cast.dialogs["tab"]?.dialog.id == 5)
    let moved = CastLifecycle.Page(tabID: "tab", windowID: "other", profile: "personal", browserID: 43, generation: 2)
    #expect(cast.prune { _ in moved } == [5])
    #expect(cast.receive(.init(id: 5, browserID: 43, open: true), page: moved).isEmpty)
    #expect(cast.dialogs.isEmpty)
    _ = cast.receive(.init(id: 6, browserID: 43, open: true), page: moved)
    let switched = CastLifecycle.Page(tabID: "tab", windowID: "other", profile: "work", browserID: 43, generation: 2)
    #expect(cast.prune { _ in switched } == [6])
    _ = cast.receive(.init(id: 7, browserID: 43, open: true), page: switched)
    #expect(cast.prune { _ in nil } == [7])
  }

  @Test func profileWatchesAreDeduplicatedAndRouteUpdatesAreScoped() {
    var cast = CastLifecycle()
    #expect(cast.profilesToWatch(["personal", "work", "personal"]) == ["personal", "work"])
    #expect(cast.profilesToWatch(["work", "private"]) == ["private"])
    let route = CastLifecycle.Route(id: "route", sink: "Living Room")
    cast.receiveRoutes([route], profile: "work")
    #expect(cast.hasRoute("route", profile: "work"))
    #expect(!cast.hasRoute("route", profile: "personal"))
    cast.receiveRoutes([], profile: "work")
    #expect(!cast.hasRoute("route", profile: "work"))
    cast.receiveRoutes([route], profile: "private")
    cast.forgetProfile("private")
    let accepted = cast.receiveRoutes([route], profile: "private")
    #expect(!accepted)
    #expect(cast.profilesToWatch(["work", "private"]) == ["private"])
  }

  @Test func pickerActionsRequireCurrentDialogAndSink() throws {
    var cast = CastLifecycle()
    _ = cast.receive(.init(id: 4, browserID: 42, open: true, sinks: [sink]), page: page)
    let old = try #require(cast.dialogs["tab"]?.receipt)
    #expect(cast.start(old, sinkID: "sink") == .start(4, "sink", 1))
    cast.selectScreen(true, receipt: old)
    #expect(cast.start(old, sinkID: "sink") == .start(4, "sink", 4))
    _ = cast.receive(.init(id: 4, browserID: 42, open: true), page: page)
    #expect(cast.start(old, sinkID: "sink") == nil)
    #expect(cast.receive(.init(id: 5, browserID: 42, open: true, sinks: [sink]), page: page) == [4])
    let current = try #require(cast.dialogs["tab"]?.receipt)
    #expect(cast.dismiss(old) == nil)
    #expect(cast.start(old, sinkID: "sink") == nil)
    #expect(cast.start(current, sinkID: "sink") == .start(5, "sink", 1))
  }
}
