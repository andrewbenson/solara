import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct OmniboxCommandSourceParityTests {
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

  private func json(_ candidates: [ExtensionCandidate]) -> JSONValue {
    .array(candidates.map { ["id": .string($0.id), "title": .string($0.title), "icon": JSONValue($0.icon),
      "action": .bool($0.action), "options": .bool($0.options)] })
  }

  @Test func descriptorsMatchActualJavaScriptSources() throws {
    let cases = try #require(fixture()["cases"]?.array)
    #expect(cases.count > 30)
    for c in cases {
      let s = try state(c["input"]!)
      let windowId = c["windowId"]!.string!
      let shortcuts = capturedCommandShortcuts(c)
      let actions = OmniboxCommandSources.actions(state: s, windowId: windowId, bookmarked: c["bookmarked"]!.bool!, shortcuts: shortcuts)
      let actionsMatch = json(actions) == c["output"]!["actions"]!
      #expect(actionsMatch, "actions: \(c["name"]!)")
      let profile = OmniboxCommandSources.extensionProfile(state: s, windowId: windowId)
      let displayed = c["extensionLists"]?[profile]?.array ?? []
      let extensions = OmniboxCommandSources.extensions(state: s, windowId: windowId, displayed: displayed.compactMap(\.object))
      let extensionsMatch = json(extensions) == c["output"]!["extensions"]!
      #expect(extensionsMatch, "extensions: \(c["name"]!)")
    }
  }

  @Test func nativeLocaleComparisonMatchesRecordedRefreshOrder() throws {
    let root = try fixture()
    let c = try #require(root["cases"]?.array?.first { $0["name"]?.string == "extension-refresh-locale-sort" })
    let locale = Locale(identifier: root["environment"]!["locale"]!.string!)
    let sorted = c["rawExtensions"]!.array!.enumerated().sorted { a, b in
      let result = a.element["name"]!.string!.compare(b.element["name"]!.string!, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
      return result == .orderedSame ? a.offset < b.offset : result == .orderedAscending
    }.map(\.element)
    let expected = c["extensionLists"]![""]!.array!.compactMap { $0["id"]?.string }
    let orderMatches = JSONValue(sorted.compactMap { $0["id"]?.string }) == JSONValue(expected)
    #expect(orderMatches)
  }

}


func capturedCommandShortcuts(_ fixture: JSONValue) -> CommandShortcutSnapshot {
  let hints = fixture["output"]?["shortcutHints"]?.object?.compactMap { id, value in
    value.string.map { (JSKey(id), $0) }
  } ?? []
  return CommandShortcutSnapshot(resolvedHints: Dictionary(uniqueKeysWithValues: hints))
}
