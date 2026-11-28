import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct BookmarkDesiredCommandParityTests {
  private func fixture() throws -> JSONValue {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("SolaraOmniboxTests/Fixtures/command-sources.json")
    return try JSONValue.parse(Data(contentsOf: path))
  }

  private func state(_ input: JSONValue) throws -> BrowserState {
    var s = BrowserState(settings: Settings(values: input["settings"]!.object!))
    s.profiles = Table()
    for (id, value) in input["profiles"]!.object! { s.profiles[id] = try Profile(json: value.object!) }
    s.profileOrder = input["profileOrder"]!.array!.compactMap(\.string)
    for (id, value) in input["windows"]!.object! { s.windows[id] = try BrowserWindow(json: value.object!) }
    for (id, value) in input["tabs"]!.object! { s.tabs[id] = try Tab(json: value.object!) }
    for (id, value) in input["groups"]!.object! { s.groups[id] = try TabGroup(json: value.object!) }
    for (id, value) in input["splits"]!.object! { s.splits[id] = try SplitView(json: value.object!) }
    return s
  }

  private func json(_ actions: [CommandAction]) -> JSONValue {
    .array(actions.map { action in
      var value: JSONObject = ["id": .string(action.id), "title": .string(action.title)]
      if let icon = action.icon { value["icon"] = .string(icon) }
      if let hint = action.hint { value["hint"] = .string(hint) }
      if let keywords = action.keywords { value["keywords"] = JSONValue(keywords) }
      return .object(value)
    })
  }

  @Test(.disabled("Tasks 3–7 must route native actions through coordinator desired membership; the committed-only reader produces both wrong bookmarkPage titles"), arguments: ["engine-empty-js-startup-cache", "engine-has-url-js-desired-remove"])
  func desiredStateBeatsCommittedTree(_ name: String) throws {
    let c = try #require(fixture()["cases"]?.array?.first { $0["name"] == .string(name) })
    let s = try state(c["input"]!)
    let windowId = try #require(c["windowId"]?.string)
    let shortcuts = capturedCommandShortcuts(c)
    let window = try #require(s.windows[windowId])
    let tab = try #require(s.tabs[window.activeTabIds[window.profileId] ?? ""])
    let committed = CommittedBookmarkStub(urls: c["engineBookmarkUrls"]!.array!.compactMap(\.string))
    let actions = OmniboxCommandSources.actions(state: s, windowId: windowId, bookmarked: committed.contains(tab.url), shortcuts: shortcuts)
    #expect(json(actions) == c["output"]!["actions"]!, "Complete desired actions for \(name): \(json(actions).text())")
  }

  @Test(arguments: ["engine-empty-js-empty", "engine-has-url-js-unchanged"])
  func committedControlsMatch(_ name: String) throws {
    let c = try #require(fixture()["cases"]?.array?.first { $0["name"] == .string(name) })
    let s = try state(c["input"]!)
    let windowId = try #require(c["windowId"]?.string)
    let window = try #require(s.windows[windowId])
    let tab = try #require(s.tabs[window.activeTabIds[window.profileId] ?? ""])
    let shortcuts = capturedCommandShortcuts(c)
    let committed = CommittedBookmarkStub(urls: c["engineBookmarkUrls"]!.array!.compactMap(\.string))
    let actions = OmniboxCommandSources.actions(state: s, windowId: windowId, bookmarked: committed.contains(tab.url), shortcuts: shortcuts)
    #expect(json(actions) == c["output"]!["actions"]!)
  }
}

private struct CommittedBookmarkStub {
  let urls: [String]

  func contains(_ url: String) -> Bool {
    !url.isEmpty && urls.contains { JSKey($0) == JSKey(url) }
  }
}
