import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct EngineCommandTests {
  @Test func followingAnotherPortChangesSite() {
    #expect(EngineCommand.differentSite(from: "http://example.test:8000/a", to: "http://example.test:9000/b"))
    #expect(!EngineCommand.differentSite(from: "http://example.test:8000/a", to: "http://example.test:8000/b"))
    #expect(!EngineCommand.differentSite(from: "HTTP://EXAMPLE.TEST:80/a", to: "http://example.test/b"))
    #expect(!EngineCommand.differentSite(from: "https://example.test:443/a", to: "https://example.test/b"))
    #expect(EngineCommand.differentSite(from: "http://example.test", to: "https://example.test"))
    #expect(!EngineCommand.differentSite(from: "file:///a", to: "file:///b"))
    #expect(EngineCommand.differentSite(from: "", to: "https://example.test"))
  }

  @Test func postedUnsavedWorkDecodesOnce() throws {
    #expect(PageValue.string("true").postedJSON?.bool == true)
    #expect(PageValue.string("false").postedJSON?.bool == false)
    #expect(PageValue.string("invalid").postedJSON == nil)
    #expect(PageValue.bool(true).postedJSON == nil)
    #expect(PageValue.string("{\"index\":2}").postedJSON?["index"]?.int == 2)
  }

  @Test(arguments: ["https://a.test/", "http://a.test/", "file:///fixture.html"])
  func supportedDestinations(_ url: String) {
    let tab = Tab(id: "a", windowId: "w", profileId: "default", url: url, now: 0)
    #expect(EngineCommand.plan(tab: tab, currentEngine: "chromium", destination: "webkit")?.engine == "webkit")
  }

  @Test(arguments: ["", "solara://history", "chrome://settings", "view-source:https://a.test/"])
  func unsupportedDestinationsStayHandled(_ url: String) {
    let tab = Tab(id: "a", windowId: "w", profileId: "default", url: url, now: 0)
    #expect(EngineCommand.plan(tab: tab, currentEngine: "chromium", destination: "webkit") == nil)
  }

  @Test func confirmationRequiresTheCapturedPageAndNavigation() throws {
    var tab = Tab(id: "a", windowId: "w", profileId: "default", url: "https://a.test/", now: 0)
    let plan = try #require(EngineCommand.plan(tab: tab, currentEngine: "webkit", destination: "chromium"))
    #expect(plan.current(tab: tab, engine: "webkit"))
    tab.navigation = Navigation(url: tab.url, seq: 2, userInitiated: true)
    #expect(!plan.current(tab: tab, engine: "webkit"))
    tab.navigation = nil
    tab.windowId = "other"
    #expect(!plan.current(tab: tab, engine: "webkit"))
    #expect(!plan.current(tab: tab, engine: "chromium"))
  }

  @Test func profileAndAdoptionChangesRejectThePlan() throws {
    var tab = Tab(id: "a", windowId: "w", profileId: "default", url: "https://a.test/", now: 0)
    let plan = try #require(EngineCommand.plan(tab: tab, currentEngine: "chromium", destination: "webkit"))
    tab.profileId = "other"
    #expect(!plan.current(tab: tab, engine: "chromium"))
    tab.profileId = "default"
    tab.adoptId = "replacement"
    #expect(!plan.current(tab: tab, engine: "chromium"))
  }

  @Test(arguments: [("default", true), ("incognito:w@default", false)])
  func sameEngineAndPrivateRulePolicy(profileId: String, canRemember: Bool) throws {
    let tab = Tab(id: "a", windowId: "w", profileId: profileId, url: "https://a.test/", now: 0)
    let plan = try #require(EngineCommand.plan(tab: tab, currentEngine: "webkit", destination: "webkit"))
    #expect(!plan.replacesPage)
    #expect(plan.canRemember == canRemember)
  }
}
