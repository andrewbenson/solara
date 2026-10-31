import Foundation
import SolaraModel
import SolaraPersistence
import SolaraStore
import Synchronization
import Testing

func liveInfrastructureWorkload(_ store: Store) throws -> [String] {
  var patches: [String] = []
  func run(_ command: Command) throws -> Commit {
    let commit = try store.dispatch(command)
    patches.append(commit.patch.json.text())
    return commit
  }
  let window = try #require(run(Command("createWindow", [["url": "https://first.example/"]])).result?.string)
  let first = try #require(store.state.windows[window]?.tabIds.first)
  _ = try run(Command("navigate", [.string(first), "https://second.example/path"]))
  _ = try run(Command("navigated", [.string(first), ["url": "https://second.example/path", "title": "Second page"]]))
  let second = try #require(run(Command("newTab", [.string(window), ["url": "https://third.example/"]])).result?.string)
  _ = try run(Command("activate", [.string(first)]))
  _ = try run(Command("updateTab", [.string(second), ["title": "Third page"]]))
  _ = try run(Command("closeTab", [.string(second)]))
  _ = try run(Command("updateSettings", [["appearance": "dark"]]))
  _ = try run(Command("setAppDark", [false]))
  return patches
}

func liveInfrastructureRowBytes(_ rows: WorkspaceRows) -> String {
  let tables: [JSONValue] = rows.tables.keys.sorted().map { name in
    let table = rows.tables[name]!
    let columns: [JSONValue] = table.columns.keys.sorted().map { id in
      let values: [JSONValue] = table.columns[id]!.keys.sorted().map { key in
        let value = table.columns[id]![key]!
        return [.string(key), value.text.map(JSONValue.string) ?? value.int.map { JSONValue($0) } ?? .null]
      }
      return [.string(id), .array(values)]
    }
    return [.string(name), JSONValue(table.ids), .array(table.payloads.keys.sorted().map { [.string($0), .string(table.payloads[$0]!)] }), .array(columns)]
  }
  let archives: [JSONValue] = rows.archives.keys.sorted().map { name in
    [.string(name), .array(rows.archives[name]!.map { [.string($0.id), .number($0.closedAt), .string($0.payload)] })]
  }
  let values: [JSONValue] = rows.values.keys.sorted().map { [.string($0), .string(rows.values[$0]!)] }
  return JSONValue.array([.array(tables), .array(archives), .array(values)]).text()
}

func liveInfrastructureBytes() throws -> JSONValue {
  let store = Store(memory: StoreMemory(ids: IdSource(launch: "step5a-head")), clock: { 1_000 })
  let patches = try liveInfrastructureWorkload(store)
  let document = store.sessionDocument()
  let marker: JSONValue = ["rev": JSONValue(store.rev), "at": 1_000, "scope": "everything"]
  return ["patches": JSONValue(patches), "state": .string(JSONValue.object(store.state.stateJSON).text()),
    "session": .string(document.json(marker: marker).text()), "rows": .string(liveInfrastructureRowBytes(WorkspaceRows(document)))]
}

@Suite struct LiveInfrastructureCompatibilityTests {
  @Test func workspacePersistenceMatches5aBytes() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Cases/step5a-head-bytes.json")
    let expected = try JSONValue.parse(Data(contentsOf: path))
    let actual = try liveInfrastructureBytes()
    for key in ["session", "rows"] {
      #expect(actual[key] == expected[key])
    }
  }

  @Test func persistedRowsAndSessionFileMatchHeadBytes() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Cases/step5a-head-bytes.json")
    let expected = try JSONValue.parse(Data(contentsOf: path))
    let store = Store(memory: StoreMemory(ids: IdSource(launch: "step5a-head")), clock: { 1_000 })
    _ = try liveInfrastructureWorkload(store)
    let folder = DataFolder(url: FileManager.default.temporaryDirectory.appending(path: "solara-step5a-\(UUID().uuidString)"))
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let persisted = PersistedState(settings: nil, downloads: [], workspace: WorkspaceRows())
    try SolaraDatabase.create(at: folder.database, writing: persisted, meta: [:])
    let database = try SolaraDatabase(url: folder.database)
    defer { try? database.close() }
    let writer = PersistenceWriter(store: store, database: database, folder: folder,
      persisted: persisted, clock: { 1_000 })
    defer { writer.freeze() }
    writer.markShadowDirty()
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    #expect(try Data(contentsOf: folder.session) == Data(try #require(expected["session"]?.string).utf8))
    let rows = try #require(database.load().workspace)
    #expect(liveInfrastructureRowBytes(rows) == expected["rows"]?.string)
    #expect(Set(store.state.live.keys) == Set(store.state.tabs.keys))
    #expect(store.state.live.values.allSatisfy { $0 == PageLiveFacts() })
  }

  @Test func wireAddsOnlyAuthoritativeLive() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Cases")
    let expected = try JSONValue.parse(Data(contentsOf: folder.appending(path: "step5b-wire-bytes.json")))
    let baseline = try JSONValue.parse(Data(contentsOf: folder.appending(path: "step5a-head-bytes.json")))
    let actual = try liveInfrastructureBytes()
    let patches = try #require(actual["patches"]?.array)
    let expectedPatches = try #require(expected["patches"]?.array)
    let baselinePatches = try #require(baseline["patches"]?.array)
    #expect(patches.count == expectedPatches.count)
    #expect(patches.count == baselinePatches.count)
    for index in patches.indices {
      let patch = try JSONValue.parse(Data(try #require(patches[index].string).utf8))
      #expect(patch.canonical == expectedPatches[index].canonical)
      var workspace = try #require(patch.object)
      workspace.removeValue(forKey: "live")
      let previous = try JSONValue.parse(Data(try #require(baselinePatches[index].string).utf8))
      #expect(JSONValue.object(workspace).canonical == previous.canonical)
    }
    let state = try JSONValue.parse(Data(try #require(actual["state"]?.string).utf8))
    #expect(state.canonical == expected["state"]?.canonical)
    var workspace = try #require(state.object)
    workspace.removeValue(forKey: "live")
    let previous = try JSONValue.parse(Data(try #require(baseline["state"]?.string).utf8))
    #expect(JSONValue.object(workspace).canonical == previous.canonical)
  }

  @Test func productionDefaultsNormalizeIdleWithoutInventingEngineFacts() throws {
    let store = Store()
    let window = try #require(store.dispatch(Command("createWindow")).result?.string)
    let tab = try #require(store.state.windows[window]?.tabIds.first)
    let seen = Mutex<[LiveChange]>([])
    let one = store.observeLive(tabId: tab) { change in seen.withLock { $0.append(change) } }
    let all = store.observeLive { change in seen.withLock { $0.append(change) } }
    defer {
      store.unsubscribe(one.token)
      store.unsubscribe(all.token)
    }
    #expect(one.baseline == PageLiveFacts())
    #expect(all.baseline == [tab: PageLiveFacts()])
    let listener = store.subscribe { commit in
      #expect(Set(commit.state.live.keys) == Set(commit.state.tabs.keys))
      #expect(commit.state.live.values.allSatisfy { $0 == PageLiveFacts() })
    }
    defer { store.unsubscribe(listener) }
    try store.dispatch(Command("navigate", [.string(tab), "https://observed.example/"]))
    try store.dispatch(Command("navigated", [.string(tab), ["url": "https://observed.example/", "title": "Observed"]]))
    #expect(seen.withLock { $0.isEmpty })
    _ = try liveInfrastructureWorkload(store)
    #expect(Set(store.state.live.keys) == Set(store.state.tabs.keys))
    #expect(store.state.live.values.allSatisfy { $0 == PageLiveFacts() })
    #expect(seen.withLock { !$0.isEmpty })
    #expect(seen.withLock { $0.allSatisfy { $0.previous == nil || $0.current == nil } })
    #expect(seen.withLock { $0.allSatisfy { $0.previous.map { $0 == PageLiveFacts() } ?? true } })
    #expect(seen.withLock { $0.allSatisfy { $0.current.map { $0 == PageLiveFacts() } ?? true } })
  }
}
