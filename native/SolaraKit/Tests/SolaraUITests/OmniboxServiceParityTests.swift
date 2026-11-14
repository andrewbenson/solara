import CryptoKit
import Foundation
import SolaraEngine
import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
private final class ServiceParityClient: EngineClient {
  let history: [EngineHistoryRow]
  let tree: EngineBookmarkTree

  init(_ source: JSONValue) throws {
    history = source["engineHistory"]!.array!.map {
      EngineHistoryRow(url: $0["url"]!.string!, title: $0["title"]!.string!, visits: $0["visits"]!.int!,
        visitTimes: $0["visitTimes"]!.array!.map { $0.number! })
    }
    tree = try JSONDecoder().decode(EngineBookmarkTree.self, from: Data(source["bookmarkTree"]!.text().utf8))
  }

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {}
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { history }
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) {}
  func watchBookmarks(engineProfile: String) async throws {}
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree { tree }
}

private struct ServiceParityFixture {
  let sourceData: Data
  let queriesData: Data
  let source: JSONValue
  let queries: JSONValue
  let golden: JSONValue

  init() throws {
    let directory = ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_FIXTURES"].map { URL(fileURLWithPath: $0) }
      ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SolaraOmniboxTests/Fixtures")
    sourceData = try Data(contentsOf: directory.appendingPathComponent("service-source.json"))
    source = try JSONValue.parse(sourceData)
    queriesData = try Data(contentsOf: directory.appendingPathComponent("service-queries.json"))
    queries = try JSONValue.parse(queriesData)
    golden = try JSONValue.parse(Data(contentsOf: directory.appendingPathComponent("service-golden.json")))
  }

  var now: Double { source["now"]!.number! }
  var contexts: [JSONValue] { queries["contexts"]!.array! }
  var cases: [JSONValue] { queries["queries"]!.array! }
  var expected: [JSONValue] { golden["results"]!.array! }

  func context(_ query: JSONValue) -> JSONValue {
    contexts.first { $0["id"] == query["context"] }!
  }

  func settings(_ context: JSONValue) -> Settings {
    var values = source["settings"]!.object!
    values["commandBarPreference"] = context["preference"]!
    return Settings(values: values)
  }

  @MainActor func sources(_ catalog: LibraryCatalog, workspaceTabs: Bool = false) -> NewTabSources {
    let sources = NewTabSources()
    sources.useHistoryCatalog(catalog)
    sources.useBookmarkCatalog(catalog)
    let icons = Dictionary(uniqueKeysWithValues: source["bookmarkIcons"]!.object!.map { ($0.key, $0.value.string!) })
    let tabs = source["tabs"]!.array!.map {
      TabRow(id: $0["id"]!.string!, url: $0["url"]!.string!, title: $0["title"]!.string!, favicon: $0["favicon"]?.string)
    }
    for profile in source["profiles"]!.array! {
      let id = profile["id"]!.string!
      let bookmarkEngine = profile["bookmarkEngineProfile"]!.string!
      sources.setBookmarkIcons(icons, engineProfile: bookmarkEngine, profileId: id)
      sources.setEngineProfile(profile["engineProfile"]!.string!, bookmarkEngineProfile: bookmarkEngine, profileId: id)
      if workspaceTabs {
        var state = BrowserState()
        state.profiles[id] = Profile(id: id, name: id, color: "blue", icon: nil, createdAt: now)
        let window = BrowserWindow(id: "fixture-window", profileId: id, incognito: false, frame: nil, createdAt: now)
        state.windows[window.id] = window
        for row in tabs {
          var tab = Tab(id: row.id, windowId: window.id, profileId: id, url: row.url, now: now)
          tab.title = row.title
          tab.favicon = row.favicon
          state.tabs[tab.id] = tab
        }
        let store = Store(state: state)
        let projected = OmniboxWorkspaceSources(store.snapshot.state).profiles.first { $0.profileId == id }!
        sources.setTabs(projected.tabs, profileId: id)
      } else {
        sources.setTabs(tabs, profileId: id)
      }
    }
    let actions = source["actions"]!.array!.map {
      CommandAction(id: $0["id"]!.string!, title: $0["title"]!.string!, keywords: $0["keywords"]?.array?.map { $0.string! },
        icon: $0["icon"]?.string, hint: $0["hint"]?.string)
    }
    let extensions = source["extensions"]!.array!.map {
      ExtensionCandidate(id: $0["id"]!.string!, title: $0["title"]!.string!, icon: $0["icon"]?.string,
        action: $0["action"]!.bool!, options: $0["options"]!.bool!)
    }
    for context in contexts {
      let window = context["windowId"]!.string!
      sources.setActions(actions, windowId: window)
      sources.setExtensions(extensions, windowId: window)
    }
    return sources
  }

  @MainActor func options(_ query: JSONValue, _ sources: NewTabSources) -> SuggestOptions {
    let context = context(query)
    let scope = context["scope"].flatMap { value -> SearchScope? in
      guard !value.isNull else { return nil }
      return SearchScope(kind: SearchScopeKind(rawValue: value["kind"]!.string!)!, name: value["name"]!.string!,
        host: value["host"]!.string!, url: value["url"]!.string!, engineId: value["engineId"]?.string)
    }
    let text = query["text"]!.string!
    let window = context["windowId"]!.string!
    let url = context["currentUrl"]!.string!
    return SuggestOptions(limit: 8, now: now, engine: defaultSearchEngine(settings(context)),
      preference: SearchPreference(rawValue: context["preference"]!.string!)!, remote: context["remote"]?.array?.map { $0.string! } ?? [],
      actions: sources.actions(window), extensions: sources.extensions(window), currentTabId: context["tabId"]!.string!,
      currentUrl: url.isEmpty ? nil : url, scope: scope, preventInline: context["preventInline"]!.bool!,
      bangs: scope == nil && jsTrim(text).contains("!") ? BundledBangs.table : nil)
  }
}

private func serviceObject(_ pairs: [(String, JSONValue?)]) -> JSONValue {
  .object(JSONObject(pairs.compactMap { key, value in value.map { (key, $0) } }))
}

private func serviceJSON(_ row: SolaraOmnibox.Suggestion) -> JSONValue {
  switch row {
  case .page(let url, let title, let favicon, let tabId, let bookmarked, let visited):
    serviceObject([("kind", "page"), ("url", .string(url)), ("title", .string(title)), ("favicon", JSONValue(favicon)),
      ("tabId", tabId.map(JSONValue.string)), ("bookmarked", bookmarked ? true : nil), ("visited", visited ? true : nil)])
  case .search(let query, let url, let engine, let suggested, let bang):
    serviceObject([("kind", "search"), ("query", .string(query)), ("url", .string(url)), ("engine", .string(engine)),
      ("suggested", suggested ? true : nil), ("bang", bang ? true : nil)])
  case .calc(let expression, let value, let url):
    serviceObject([("kind", "calc"), ("expression", .string(expression)), ("value", .string(value)), ("url", .string(url))])
  case .action(let id, let title, let icon, let hint):
    serviceObject([("kind", "action"), ("id", .string(id)), ("title", .string(title)),
      ("icon", icon.map(JSONValue.string)), ("hint", hint.map(JSONValue.string))])
  case .create(let id, let title, let url, let site):
    serviceObject([("kind", "create"), ("id", .string(id)), ("title", .string(title)), ("url", .string(url)), ("site", .string(site))])
  case .extension(let id, let title, let icon, let open):
    serviceObject([("kind", "extension"), ("id", .string(id)), ("title", .string(title)),
      ("icon", JSONValue(icon)), ("open", .string(open.rawValue))])
  }
}

private func serviceEqual(_ actual: JSONValue, _ expected: JSONValue) -> Bool {
  switch (actual, expected) {
  case (.object(let a), .object(let b)):
    a.count == b.count && a.allSatisfy { key, value in b[key].map { serviceEqual(value, $0) } ?? false }
  case (.array(let a), .array(let b)):
    a.count == b.count && zip(a, b).allSatisfy { serviceEqual($0, $1) }
  default:
    actual == expected
  }
}

private func serviceResult(_ result: SuggestionResult) -> JSONValue {
  ["items": .array(result.items.map(serviceJSON)), "completion": .string(result.completion)]
}

@Suite @MainActor
struct OmniboxServiceParityTests {
  @Test(arguments: [false, true]) func catalogProjectionAndEveryOrderedAnswerMatchNodeFreshAndWarm(workspaceTabs: Bool) async throws {
    let fixture = try ServiceParityFixture()
    let manifest = try #require(fixture.golden["manifest"])
    let sourceHash = SHA256.hash(data: fixture.sourceData).map { String(format: "%02x", $0) }.joined()
    let queriesHash = SHA256.hash(data: fixture.queriesData).map { String(format: "%02x", $0) }.joined()
    #expect(manifest["sourceHash"]?.string == sourceHash)
    #expect(manifest["queriesHash"]?.string == queriesHash)
    #expect(manifest["queryCount"]?.int == fixture.cases.count)
    #expect(manifest["limit"]?.int == 8)
    #expect(manifest["now"]?.number == fixture.now)
    let texts = Set(fixture.cases.map { $0["text"]!.string! })
    #expect(texts.count >= 240)
    let defaults = fixture.cases.filter { $0["context"]?.string == "default" }
    #expect(Set(defaults.map { $0["text"]!.string! }).count >= 200)
    #expect(fixture.expected.count == fixture.cases.count)
    let client = try ServiceParityClient(fixture.source)
    let catalog = LibraryCatalog(client: client, bookmarkSelection: { false })
    await catalog.start(engineProfiles: fixture.source["profiles"]!.array!.map { $0["engineProfile"]!.string! })
    let warm = fixture.sources(catalog, workspaceTabs: workspaceTabs)
    for profile in fixture.source["profiles"]!.array! {
      let id = profile["id"]!.string!
      let history: JSONValue = .array(warm.history(id).map {
        ["url": .string($0.url), "title": .string($0.title), "favicon": JSONValue($0.favicon),
          "visits": .number($0.visits), "lastVisit": .number($0.lastVisit)]
      })
      let bookmarks: JSONValue = .array(warm.bookmarks(id).map {
        ["url": .string($0.url), "title": .string($0.title), "favicon": JSONValue($0.favicon)]
      })
      let tabs: JSONValue = .array(warm.tabs(id).map {
        ["id": .string($0.id), "url": .string($0.url), "title": .string($0.title), "favicon": JSONValue($0.favicon)]
      })
      #expect(serviceEqual(history, fixture.source["history"]!), "history projection \(id): \(history.text())")
      #expect(serviceEqual(bookmarks, fixture.source["bookmarks"]!), "bookmark projection \(id): \(bookmarks.text())")
      #expect(serviceEqual(tabs, fixture.source["tabs"]!), "tab table order \(id): \(tabs.text())")
      #expect(warm.preparedIndex(id))
    }
    for (query, expected) in zip(fixture.cases, fixture.expected) {
      await Task.yield()
      #expect(query["text"] == expected["text"] && query["context"] == expected["context"])
      let text = query["text"]!.string!
      let profile = fixture.context(query)["profileId"]!.string!
      let answer: JSONValue = ["items": expected["items"]!, "completion": expected["completion"]!]
      for (state, sources) in [("fresh", fixture.sources(catalog, workspaceTabs: workspaceTabs)), ("warm", warm)] {
        let result = sources.suggestNow(SuggestRequest(profileId: profile, typed: text, tabs: sources.tabs(profile), options: fixture.options(query, sources)))
        let actual = serviceResult(result)
        #expect(result.items.count <= 8)
        #expect(serviceEqual(actual, answer), "\(state) \(query.text()): Swift=\(actual.text()) Node=\(answer.text())")
      }
    }
  }

  @Test func modelUsesInjectedClockForTheRecordedAnswer() async throws {
    let fixture = try ServiceParityFixture()
    let query = try #require(fixture.cases.first { $0["context"]?.string == "default" && $0["text"]?.string == "g" })
    let expected = try #require(fixture.expected.first { $0["context"] == query["context"] && $0["text"] == query["text"] })
    let context = fixture.context(query)
    let catalog = LibraryCatalog(client: try ServiceParityClient(fixture.source), bookmarkSelection: { false })
    await catalog.start(engineProfiles: fixture.source["profiles"]!.array!.map { $0["engineProfile"]!.string! })
    let sources = fixture.sources(catalog)
    var clockReads = 0
    let model = HeroBarModel(windowId: context["windowId"]!.string!, tabId: context["tabId"]!.string!,
      profileId: context["profileId"]!.string!, incognito: false, settings: { fixture.settings(context) }, sources: sources,
      variant: .panel, currentUrl: context["currentUrl"]!.string!, now: { clockReads += 1; return fixture.now })
    model.textChanged("g", edit: nil)
    #expect(clockReads == 1)
    let answer: JSONValue = ["items": expected["items"]!, "completion": expected["completion"]!]
    #expect(serviceEqual(serviceResult(model.result), answer), "Swift=\(serviceResult(model.result).text()) Node=\(answer.text())")
    #expect(model.shown == expected["completion"]!.string!)
  }
}
