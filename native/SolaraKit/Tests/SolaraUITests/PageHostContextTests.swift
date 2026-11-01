import Foundation
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct PageHostContextTests {
  @Test func cachedOverlayRetainsRevisionBeforeAttachment() {
    let cached: JSONValue = ["navigationSeq": 0, "contextRevision": 12, "wasNewTab": true,
      "newTabShownUrl": "https://page.example/", "appDark": true]
    let context = PageHostContext.initial(navigationSeq: 0, wasNewTab: false, cached: cached)
    #expect(context.contextRevision == 12)
    #expect(context.wasNewTab)
    #expect(context.newTabShownUrl == "https://page.example/")
  }

  @Test func staleCachedNavigationCannotSeedAnotherRequest() {
    let cached: JSONValue = ["navigationSeq": 3, "contextRevision": 12, "wasNewTab": true,
      "newTabShownUrl": "https://old.example/"]
    let context = PageHostContext.initial(navigationSeq: 4, wasNewTab: false, cached: cached)
    #expect(context.navigationSeq == 4)
    #expect(context.contextRevision == 0)
    #expect(!context.wasNewTab)
    #expect(context.newTabShownUrl == nil)
  }

  @Test func explicitNullContextSurvivesAppearanceProps() {
    let cached: JSONValue = ["navigationSeq": nil, "contextRevision": 13, "wasNewTab": true,
      "newTabShownUrl": nil, "appDark": false, "appearance": "dark"]
    let context = PageHostContext.initial(navigationSeq: nil, wasNewTab: false, cached: cached)
    #expect(context.navigationSeq == nil)
    #expect(context.contextRevision == 13)
    #expect(context.wasNewTab)
    #expect(context.newTabShownUrl == nil)
  }

  @Test func malformedCachedContextNeverBecomesAuthority() {
    let invalid: [JSONValue] = [
      ["navigationSeq": 0, "contextRevision": -1, "wasNewTab": true, "newTabShownUrl": "overlay"],
      ["navigationSeq": 0, "contextRevision": 1.5, "wasNewTab": true, "newTabShownUrl": "overlay"],
      ["navigationSeq": 0, "contextRevision": .number(.infinity), "wasNewTab": true, "newTabShownUrl": "overlay"],
      ["navigationSeq": 0, "contextRevision": 9_007_199_254_740_992, "wasNewTab": true, "newTabShownUrl": "overlay"],
      ["navigationSeq": -1, "contextRevision": 1, "wasNewTab": true, "newTabShownUrl": "overlay"],
      ["navigationSeq": 0, "contextRevision": 1, "wasNewTab": "true", "newTabShownUrl": "overlay"],
      ["navigationSeq": 0, "contextRevision": 1, "wasNewTab": true, "newTabShownUrl": 4],
      ["navigationSeq": 0, "contextRevision": 1, "wasNewTab": true],
    ]
    for value in invalid {
      #expect(PageHostContext(json: value) == nil)
      let context = PageHostContext.initial(navigationSeq: 0, wasNewTab: false, cached: value)
      #expect(context.contextRevision == 0)
      #expect(context.newTabShownUrl == nil)
    }
  }
}

@MainActor
@Suite struct PageHostInitialContextTests {
  @Test func cachedOverlayReachesFirstNativeIssueOnBothEngines() throws {
    for engine in [PageEngine.chromium, .webKit] {
      let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: false)
      let creation = try store.dispatch(Command("createWindow", [["url": "https://page.example/"]]))
      let window = try #require(creation.result?.string)
      let first = store.state.windows[window]?.tabIds.first
      let id = try #require(first)
      if engine == .webKit { try store.dispatch(Command("updateTab", [.string(id), ["engine": "webkit"]])) }
      let sequence = store.state.tabs[id]?.navigation.flatMap { Int(exactly: $0.seq) }
      let cached: JSONValue = ["navigationSeq": sequence.map { JSONValue($0) } ?? .null,
        "contextRevision": 12, "wasNewTab": true, "newTabShownUrl": "https://page.example/"]
      let context = PageHostContext.initial(navigationSeq: sequence, wasNewTab: false, cached: cached)
      let owner = NSObject()
      let issuer = PageIssuer(store: store, registry: PageRegistry())
      let attached = issuer.attach(tabId: id, engine: engine, host: .pooled, owner: owner,
        context: context, perform: { _, finish in finish(.success(.null)) })
      let binding = try #require(attached)
      let reported = issuer.report(binding, report: ["type": "ready", "browserId": 3])
      #expect(reported)
      let candidate = issuer.preview(binding)
      let prepared = try #require(candidate)
      #expect(prepared.guardValue.contextRevision == 12)
      #expect(prepared.actions.array?.first?["type"]?.string == "clearNewTabShown")
      let accepted = issuer.follow(binding)
      #expect(accepted)
      let shown = binding.context.newTabShownUrl
      #expect(shown == nil)
    }
  }
}
