import SolaraModel
import SolaraOmnibox
import Testing
@testable import SolaraUI

@Suite struct ToolbarPageIdentityTests {
  private func state(_ url: String) -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: url, now: 0)
    return state
  }

  @Test func blankHasNoPageOrHost() throws {
    let identity = try #require(ToolbarPageIdentity.resolve(windowId: "w", tabId: "a", state: state("")))
    #expect(!identity.hasPage)
    #expect(identity.host == "")
  }

  @Test func labelsMatchTheExistingStrip() throws {
    for (url, host) in [("file:///Users/test/page.html", "File"), ("https://www.example.com:8443/path", "example.com:8443"), ("https://www.example.com/path", "example.com"), ("about:blank", "about:blank"), (AppScheme.value + "://settings", AppScheme.value + "://settings")] {
      let identity = try #require(ToolbarPageIdentity.resolve(windowId: "w", tabId: "a", state: state(url)))
      #expect(identity.hasPage)
      #expect(identity.host == host)
    }
  }

  @Test func navigationUsesTheCurrentPageRatherThanStyleFeedText() throws {
    var current = state("https://before.example/path")
    #expect(ToolbarPageIdentity.resolve(windowId: "w", tabId: "a", state: current)?.host == "before.example")
    current.tabs["a"]?.url = "https://after.example/path"
    #expect(ToolbarPageIdentity.resolve(windowId: "w", tabId: "a", state: current)?.host == "after.example")
  }

  @Test func missingAndMovedTabsHaveNoIdentity() {
    #expect(ToolbarPageIdentity.resolve(windowId: "other", tabId: "a", state: state("https://example.com")) == nil)
    #expect(ToolbarPageIdentity.resolve(windowId: "w", tabId: "gone", state: state("https://example.com")) == nil)
  }
}
