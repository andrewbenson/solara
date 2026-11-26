import Testing
import SolaraModel
@testable import SolaraOmnibox

struct ExtensionSearchRefreshTests {
  @Test func debounceAndFirstRereadArePerProfile() {
    var refresh = ExtensionSearchRefresh()
    #expect(refresh.listChanged(profile: "") == [0.4, 3])
    #expect(refresh.listChanged(profile: "") == [0.4])
    #expect(refresh.listChanged(profile: "work") == [0.4, 3])
    refresh.invalidate()
    #expect(refresh.listChanged(profile: "") == [0.4, 3])
  }

  @Test func staleRepliesCannotCommit() {
    var refresh = ExtensionSearchRefresh()
    let first = refresh.begin(profile: "")
    let second = refresh.begin(profile: "")
    #expect(!refresh.current(first, profile: ""))
    #expect(refresh.current(second, profile: ""))
    let other = refresh.begin(profile: "work")
    #expect(refresh.current(second, profile: ""))
    #expect(refresh.current(other, profile: "work"))
    refresh.invalidate()
    #expect(!refresh.current(other, profile: "work"))
    #expect(!refresh.current(second, profile: ""))
  }

  @Test func changedListInvalidatesAnInFlightRead() {
    var refresh = ExtensionSearchRefresh()
    let request = refresh.begin(profile: "")
    _ = refresh.listChanged(profile: "")
    #expect(!refresh.current(request, profile: ""))
  }

  @Test func mergePreservesOtherProfilesAndNullResults() throws {
    let existing: JSONValue = [["profile": "work", "name": "Work"], ["profile": "", "name": "Old"]]
    #expect(ExtensionSearchRefresh.merge(profile: "", list: nil, current: existing) == nil)
    #expect(ExtensionSearchRefresh.merge(profile: "", list: .null, current: existing) == nil)
    #expect(ExtensionSearchRefresh.merge(profile: "", list: ["error": "offline"], current: existing) == nil)
    let empty = try #require(ExtensionSearchRefresh.merge(profile: "", list: [:], current: existing))
    #expect(empty == [["profile": "work", "name": "Work"]])
    #expect(ExtensionSearchRefresh.merge(profile: "", list: [:], current: empty) == nil)
  }

  @Test func usesChromeParserAndStoresOptionalSuggestionOnlyWhenPresent() throws {
    let list: JSONValue = ["engines": [
      ["extension": ["id": "ext", "name": "Search"], "url": "https://example.test/?q=%s{language}", "default": true],
      ["extension": ["id": "omni"], "url": "https://example.test/%s", "isOmniboxExtension": true]
    ]]
    let merged = try #require(ExtensionSearchRefresh.merge(profile: "", list: list, current: []))
    #expect(merged.array?.count == 1)
    let engine = try #require(merged.array?.first)
    #expect(engine["url"] == "https://example.test/?q=%s")
    #expect(engine["extensionId"] == "ext")
    #expect(engine["isDefault"] == true)
    #expect(engine["suggestUrl"] == nil)
    #expect(ExtensionSearchRefresh.merge(profile: "", list: list, current: merged) == nil)
  }
}
