import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite struct HeldNeutralityTests {
  static func transcript(origin: Origin, fromSync: Bool = false) throws -> String {
    final class Log: @unchecked Sendable {
      let lock = NSLock()
      var lines: [String] = []
      func add(_ line: String) { lock.withLock { lines.append(line) } }
    }
    @Sendable func workspacePatch(_ patch: Patch) -> String {
      var object = patch.json.object ?? [:]
      object.removeValue(forKey: "live")
      return JSONValue.object(object).canonical
    }
    let log = Log()
    let store = Store(memory: StoreMemory(ids: IdSource(launch: "neutral")), checksInvariants: true, clock: { 1_793_016_000_000 })
    store.subscribe { commit in log.add("first \(commit.rev) \(commit.origin) \(workspacePatch(commit.patch)) \(JSONValue.array(commit.effects.map(\.json)).canonical)") }
    final class Once: @unchecked Sendable { var fired = false }
    let once = Once()
    store.subscribe { [weak store] commit in
      log.add("second \(commit.rev)")
      guard !once.fired, commit.commands.first?.name == "createGroup", let store else { return }
      once.fired = true
      let follow = try? store.dispatch(Command("setPlayingAudio", [["t-follow"]]), origin: origin, fromSync: fromSync)
      log.add("follow-up \(follow?.rev ?? -1)")
    }
    try store.dispatch(Command("createWindow", [["url": "https://a.example/"]]), origin: origin)
    let window = store.state.windowOrder[0]
    let steps: [Command] = [
      Command("beginTransaction"),
      Command("newTab", [.string(window), ["url": "https://b.example/"]]),
      Command("updateSettings", [["searchEngine": "bing"]]),
      Command("newTab", [.string(window), ["url": "https://c.example/"]]),
      Command("createGroup", [JSONValue(store.state.windows[window]!.tabIds), ["name": "G"]]),
      Command("endTransaction"),
      Command("togglePin", [.string(store.state.windows[window]!.tabIds[0])]),
    ]
    for command in steps {
      let commit = try store.dispatch(command, origin: origin, fromSync: fromSync)
      log.add("returned \(command.name) \(commit.rev) \(commit.changes.isEmpty) \(workspacePatch(commit.patch))")
    }
    return log.lines.joined(separator: "\n")
  }

  @Test func withNoTokenAndNoSyncOriginAHeldTransactionCommitsAndDeliversExactlyAsBefore() throws {
    let golden = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Cases/held-transaction-at-head.txt"), encoding: .utf8)
    let currentSchema = golden.replacingOccurrences(of: "\"ui\":{", with: "\"ui\":{\"appDark\":true,")
      .replacingOccurrences(of: #"{"type":"closePanel","windowId":"w-neutral-1"}"#, with: "")
    let halves = currentSchema.components(separatedBy: "\n=====\n")
    try #require(halves.count == 2)
    #expect(try Self.transcript(origin: .native) == halves[0], "a native user's transaction is byte for byte as before")
    #expect(try Self.transcript(origin: .bridge) == halves[1], "so is a bridged one")
    #expect(try Self.transcript(origin: .bridge, fromSync: true) == halves[1], "with the switch off, a sync token changes nothing")
  }
}
