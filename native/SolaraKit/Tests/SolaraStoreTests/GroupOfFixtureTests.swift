import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite struct GroupOfFixtureTests {
  @Test func innermostGroupOfMatchesTheFixtureJavaScriptIsCheckedAgainst() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Cases/group-of.json")
    let fixture = try JSONValue.parse(Data(contentsOf: url))
    let state = try BrowserState(stateJSON: ["groups": fixture["groups"]!])
    for (tabId, groupId) in fixture["expected"]?.object ?? [:] {
      #expect(Groups.innermostGroupOf(state.groups, tabId)?.id == groupId.string, "\(tabId)")
    }
  }
}
