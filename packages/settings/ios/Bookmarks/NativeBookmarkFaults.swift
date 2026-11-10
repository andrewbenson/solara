#if DEBUG
import Foundation
import SolaraCore
import SolaraEngine
import SolaraModel
import SolaraShell

@MainActor
enum NativeBookmarkFaults {
  private static var engine: String?
  private static var dropID: String?
  private static var released = false
  private static var paused = false
  private static var generation = 0
  private static var phase = "idle"
  private static var operations: [BookmarkOperation] = []
  private static var result: BookmarkApplyResult?
  private static var reads = 0
  private static var applies = 0

  private static var enabled: Bool {
    !LaunchSwitches.shared.distribution && !LaunchSwitches.shared.safeMode && !DocumentStore.safeMode
      && ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"].map { !$0.isEmpty } == true
  }

  static func command(_ input: String) async throws -> String {
    guard enabled else { throw BookmarkWriterError.notOwned }
    let value = try JSONValue.parseBookmark(input)
    switch value["operation"]?.string {
    case "arm":
      guard engine == nil, let target = value["engine"]?.string else { throw BookmarkWriterError.invalidDocument("a single engine fault must be armed at a time") }
      generation += 1
      engine = target
      dropID = value["dropID"]?.string
      released = false
      paused = false
      operations = []
      result = nil
      phase = "armed"
    case "releasePush":
      released = true
    case "releaseAll":
      generation += 1
      engine = nil
      paused = false
      released = true
      phase = "idle"
    case "apply":
      guard let target = value["engine"]?.string, let ops = value["ops"]?.array else { throw BookmarkWriterError.invalidDocument("engine and operations are required") }
      return try await direct("ac_bookmarks_apply", engine: target, args: ["ops": .array(ops)]).bookmarkText()
    case "tree":
      guard let target = value["engine"]?.string else { throw BookmarkWriterError.invalidDocument("engine is required") }
      return try await direct("ac_bookmarks_tree", engine: target, args: [:]).bookmarkText()
    case "status", "documents":
      break
    default:
      throw BookmarkWriterError.invalidDocument("unknown bookmark fault operation")
    }
    var status: JSONObject = [
      "phase": .string(phase), "reads": .number(Double(reads)), "applies": .number(Double(applies)),
      "documents": .string(try DocumentStore.directoryURL().path),
      "operations": try JSONValue.parseBookmark(JSONEncoder().encode(operations)),
      "writerState": .string(NativeBookmarkOwner.ownershipState.phase.rawValue)
    ]
    if let result { status["result"] = try JSONValue.parseBookmark(JSONEncoder().encode(result)) }
    return JSONValue.object(status).bookmarkText()
  }

  static func beforeRead(engine target: String) async throws {
    guard enabled else { return }
    reads += 1
    guard engine == target, paused else { return }
    let ticket = generation
    try await wait(ticket: ticket) { !paused }
  }

  static func beforeApply(engine target: String, ops: [BookmarkOperation]) async throws {
    guard enabled else { return }
    applies += 1
    guard engine == target else { return }
    if paused {
      let ticket = generation
      try await wait(ticket: ticket) { !paused }
      return
    }
    guard phase == "armed" else { return }
    operations = ops
    phase = "held"
    let ticket = generation
    try await wait(ticket: ticket) { released }
    guard generation == ticket, engine == target else { return }
    if let dropID {
      let reply = try await direct("ac_bookmarks_apply", engine: target, args: ["ops": [["op": "remove", "id": .string(dropID)]]])
      guard reply["applied"] == 1, reply["skipped"] == 0 else { throw BookmarkWriterError.refused("the pre-batch removal did not apply") }
    }
    phase = "applying"
  }

  static func afterApply(engine target: String, result applied: BookmarkApplyResult) {
    guard enabled, engine == target, phase == "applying" else { return }
    result = applied
    paused = true
    phase = "completed"
  }

  private static func wait(ticket: Int, until ready: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 45
    while generation == ticket && !ready() {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw BookmarkWriterError.refused("the bookmark fault hold expired") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private static func direct(_ name: String, engine: String, args: JSONValue) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      SolaraCoreEngineBridge.call(name, profile: engine, args: args.text()) { text in
        do {
          let value = try JSONValue.parseBookmark(text)
          guard value.object != nil, value["error"] == nil else { throw BookmarkWriterError.refused(text) }
          continuation.resume(returning: value)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
#endif
