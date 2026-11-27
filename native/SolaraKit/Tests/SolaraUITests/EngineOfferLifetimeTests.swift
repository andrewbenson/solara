import SolaraModel
import Testing
@testable import SolaraUI

@Suite struct EngineOfferLifetimeTests {
  @Test func rememberedChoiceUsesCanonicalOrigin() {
    #expect(EngineCommand.site("https://WWW.Example.com:443/video") == "https://www.example.com")
    #expect(EngineCommand.site("file:///movie") == nil)
  }

  @Test func anOfferCannotFollowAReplacementDocumentOrProfile() {
    var tab = Tab(id: "a", windowId: "window", profileId: "default", url: "https://example.com/movie", now: 0)
    let identity = PageIdentity(tabId: tab.id, registrationGeneration: 1, sessionGeneration: "page")
    let shown = PageActionScope(identity: identity, documentRevision: 1, tab: tab)
    #expect(shown != PageActionScope(identity: identity, documentRevision: 2, tab: tab))
    let replaced = PageIdentity(tabId: tab.id, registrationGeneration: 2, sessionGeneration: "replacement")
    #expect(shown != PageActionScope(identity: replaced, documentRevision: 1, tab: tab))
    tab.profileId = "other"
    #expect(shown != PageActionScope(identity: identity, documentRevision: 1, tab: tab))
  }

  @Test func followThrottleExpiresAfterTenSeconds() {
    var throttle = EngineOfferThrottle()
    let allowed0 = throttle.begin(tabId: "a", now: 2)
    #expect(allowed0)
    let allowed1 = throttle.begin(tabId: "a", now: 11)
    #expect(!allowed1)
    let allowed2 = throttle.begin(tabId: "b", now: 11)
    #expect(allowed2)
    let allowed3 = throttle.begin(tabId: "a", now: 12)
    #expect(allowed3)
    throttle.remove(tabId: "a")
    let allowed4 = throttle.begin(tabId: "a", now: 13)
    #expect(allowed4)
  }
}
