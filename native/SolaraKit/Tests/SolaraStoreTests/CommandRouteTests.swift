import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite struct CommandRouteTests {
  private static func fixture() throws -> JSONObject {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Cases/command-routes.json")
    return try #require(JSONValue.parse(try Data(contentsOf: path)).object)
  }

  private static func names(_ value: JSONValue?) -> Set<String> { Set(value?.array?.compactMap(\.string) ?? []) }

  @Test func theSharedSetsMatchTheJavaScriptCatalog() throws {
    let fixture = try Self.fixture()
    #expect(Self.names(fixture["littleSolaraPageCommands"]) == CommandRoute.littleSolaraPageCommands)
    #expect(Self.names(fixture["littleSolaraCommands"]) == CommandRoute.littleSolaraCommands)
    #expect(Self.names(fixture["windowLevelCommands"]) == CommandRoute.windowLevelCommands)
    #expect(Self.names(fixture["invokerCommands"]) == CommandRoute.invokerCommands)
    #expect(Self.names(fixture["utilityWindowIds"]) == CommandRoute.utilityWindowIds)
  }

  @Test func everyRecordedCaseRoutesLikeJavaScript() throws {
    let cases = try #require(Self.fixture()["cases"]?.array)
    #expect(cases.count >= 20)
    for entry in cases {
      let c = try #require(entry.object)
      let name = c["name"]?.string ?? "?"
      let state = try BrowserState(stateJSON: try #require(c["state"]?.object))
      let route = CommandRoute.resolve(try #require(c["command"]?.string), windowId: c["windowId"]?.string, state: state,
        closing: Self.names(c["closing"]))
      #expect(route.json == c["route"], "\(name)")
    }
  }

  @Test func anEmptyPeekTabIdInAHandMadeStateIsNoTab() throws {
    let cases = try #require(Self.fixture()["cases"]?.array)
    let c = try #require(cases.compactMap(\.object).first { $0["name"]?.string == "Peek openFile promotes the Peek" })
    let roles = try #require(c["roles"]?.object)
    let w = try #require(roles["w"]?.string)
    var json = try #require(c["state"]?.object)
    var peeks = try #require(json["peeks"]?.object)
    var peek = try #require(peeks[w]?.object)
    peek["tabId"] = .string("")
    peeks[w] = .object(peek)
    json["peeks"] = .object(peeks)
    let state = try BrowserState(stateJSON: json)
    #expect(CommandRoute.resolve("reload", windowId: w, state: state, closing: []) == CommandRoute(.main, windowId: w, tabId: roles["a"]?.string))
    #expect(CommandRoute.resolve("openFile", windowId: w, state: state, closing: []) == CommandRoute(.peekPromote, windowId: w))
    #expect(CommandRoute.resolve("closeTab", windowId: w, state: state, closing: []) == CommandRoute(.peekDismiss, windowId: w))
  }

  @Test(arguments: [
    "a redirect prefers a main window on the small window's profile",
    "an empty active tab id is no tab",
  ])
  func emptyIdsRouteLikeJavaScript(name: String) throws {
    let cases = try #require(Self.fixture()["cases"]?.array)
    let c = try #require(cases.compactMap(\.object).first { $0["name"]?.string == name })
    let state = try BrowserState(stateJSON: try #require(c["state"]?.object))
    let route = CommandRoute.resolve(try #require(c["command"]?.string), windowId: c["windowId"]?.string, state: state, closing: Self.names(c["closing"]))
    #expect(route.json == c["route"])
  }

  @Test func theFixtureNamesItsRecorder() throws {
    let provenance = try #require(Self.fixture()["provenance"]?.object)
    #expect(provenance["recorder"]?.string == "apps/browser/scripts/native/record-command-routes.mjs")
    #expect(provenance["revision"]?.string?.isEmpty == false)
  }

  @Test func everyKindIsCovered() throws {
    let cases = try #require(Self.fixture()["cases"]?.array)
    let kinds = Set(cases.compactMap { $0.object?["route"]?.object?["kind"]?.string })
    #expect(kinds == Set(["utilityClose", "settingsSearch", "littleSolara", "peekPromote", "peekCloseFind", "peekDismiss", "window", "invoker", "noWindow", "main"]))
  }
}
