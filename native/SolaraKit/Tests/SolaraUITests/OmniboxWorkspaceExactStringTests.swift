import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing
@testable import SolaraUI

@Suite @MainActor struct OmniboxWorkspaceExactStringTests {
  fileprivate func state(_ value: String, field: String = "url") -> BrowserState {
    var state = BrowserState()
    state.windows["window"] = BrowserWindow(id: "window", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    var tab = Tab(id: field == "id" ? value : "tab", windowId: "window", profileId: "default", url: field == "url" ? value : "https://example.com/", now: 0)
    tab.title = field == "title" ? value : "Title"
    tab.favicon = field == "favicon" ? value : nil
    state.tabs[tab.id] = tab
    return state
  }

  private func units(_ rows: [TabRow]) -> [[[UInt16]?]] {
    rows.map { [Array($0.id.utf16), Array($0.url.utf16), Array($0.title.utf16), $0.favicon.map { Array($0.utf16) }] }
  }

  @Test(arguments: ["id", "url", "title", "favicon"])
  func perProfileTabDeduplicationPreservesRawStrings(field: String) {
    let initial = OmniboxWorkspaceSources(state("https://example.com/caf\u{e9}", field: field))
    let changed = OmniboxWorkspaceSources(state("https://example.com/cafe\u{301}", field: field))
    let sources = NewTabSources()
    sources.applyWorkspace(initial)
    let revision = sources.revision
    sources.applyWorkspace(initial)
    #expect(sources.revision == revision + 1)
    sources.applyWorkspace(changed)
    let expected = changed.profiles.first { $0.profileId == "default" }!.tabs
    #expect(units(sources.tabs("default")) == units(expected))
    #expect(sources.revision == revision + 3)
    #expect(initial != changed)
  }

  @Test(arguments: ["profileId", "engineProfile", "bookmarkEngineProfile"])
  func projectionEqualityPreservesRawProfileStrings(field: String) {
    func profile(_ value: String) -> OmniboxWorkspaceSources.Profile {
      OmniboxWorkspaceSources.Profile(profileId: field == "profileId" ? value : "default",
        engineProfile: field == "engineProfile" ? value : "default",
        bookmarkEngineProfile: field == "bookmarkEngineProfile" ? value : "default", tabs: [])
    }
    let initial = profile("caf\u{e9}")
    let changed = profile("cafe\u{301}")
    #expect(initial == initial)
    #expect(initial != changed)
  }

  @Test(arguments: ["engineProfile", "bookmarkEngineProfile"])
  func engineMappingDeduplicationPreservesRawStrings(field: String) {
    let sources = NewTabSources()
    let initial = "caf\u{e9}"
    let changed = "cafe\u{301}"
    sources.setEngineProfile(initial, bookmarkEngineProfile: initial, profileId: "default")
    let revision = sources.revision
    sources.setEngineProfile(initial, bookmarkEngineProfile: initial, profileId: "default")
    #expect(sources.revision == revision)
    let engineProfile = field == "engineProfile" ? changed : initial
    let bookmarkEngineProfile = field == "bookmarkEngineProfile" ? changed : initial
    sources.setEngineProfile(engineProfile, bookmarkEngineProfile: bookmarkEngineProfile, profileId: "default")
    let snapshot = sources.omniboxBenchSnapshot(profileId: "default")
    #expect(Array((snapshot["engineProfile"] as! String).utf16) == Array(engineProfile.utf16))
    #expect(Array((snapshot["bookmarkEngineProfile"] as! String).utf16) == Array(bookmarkEngineProfile.utf16))
    #expect(sources.revision > revision)
  }
}

extension OmniboxWorkspaceFeedTests {
  @Test func committedURLCodeUnitsReachFeedAndUnchangedProjectionSkipsPublication() async throws {
    let initial = OmniboxWorkspaceExactStringTests().state("https://example.com/caf\u{e9}")
    let changedURL = "https://example.com/cafe\u{301}"
    let store = Store(state: initial, checksInvariants: false)
    let sources = NewTabSources()
    var resolutions = 0
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { true }, ownershipGeneration: { 0 }, resolve: { resolutions += 1; return store })
    feed.reconcile()
    defer { feed.stop() }
    let revision = sources.revision
    let initialResolutions = resolutions
    let commit = try store.dispatch(Command("updateTab", [.string("tab"), .object(["url": .string(changedURL), "muted": .bool(true)])]))
    #expect(commit.rev > 0)
    #expect(Array(commit.state.tabs["tab"]!.url.utf16) == Array(changedURL.utf16))
    for _ in 0..<1000 {
      if resolutions > initialResolutions,
        sources.tabs("default").map({ Array($0.url.utf16) }) == [Array(changedURL.utf16)] { break }
      await Task.yield()
    }
    #expect(resolutions > initialResolutions)
    #expect(Array(sources.tabs("default")[0].url.utf16) == Array(changedURL.utf16))
    #expect(sources.revision > revision)
    feed.reconcile()
    let changedRevision = sources.revision
    feed.receive(state: commit.state, revision: commit.rev + 1, generation: feed.generation)
    #expect(sources.revision == changedRevision)
  }
}
