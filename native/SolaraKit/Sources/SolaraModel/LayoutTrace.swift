#if DEBUG || SOLARA_PERF_TRACE
import Foundation
import os
import Synchronization

public enum LayoutTrace {
  public struct Token: Sendable {
    let stage: StaticString
    let detail: String
    let id: OSSignpostID
  }

  private struct Entry: Sendable {
    let stage: String
    let detail: String
    let phase: String
    let at: Double
    let id: UInt64
  }

  public static let enabled = ProcessInfo.processInfo.environment["SOLARA_LAYOUT_TRACE"] == "1"
  private static let log = OSLog(subsystem: "network.benson.solara.layout", category: .pointsOfInterest)
  private static let entries = Mutex<[Entry]>([])

  public static func begin(_ stage: StaticString, _ detail: String = "") -> Token? {
    guard enabled else { return nil }
    let token = Token(stage: stage, detail: detail, id: OSSignpostID(log: log))
    os_signpost(.begin, log: log, name: stage, signpostID: token.id, "%{public}@", detail as NSString)
    append(stage, detail, "begin", token.id.rawValue)
    return token
  }

  public static func end(_ token: Token?) {
    guard let token else { return }
    append(token.stage, token.detail, "end", token.id.rawValue)
    os_signpost(.end, log: log, name: token.stage, signpostID: token.id)
  }

  public static func event(_ stage: StaticString, _ detail: String = "") {
    guard enabled else { return }
    os_signpost(.event, log: log, name: stage, "%{public}@", detail as NSString)
    append(stage, detail, "event", 0)
  }

  private static func append(_ stage: StaticString, _ detail: String, _ phase: String, _ id: UInt64) {
    let entry = Entry(stage: String(describing: stage), detail: detail, phase: phase, at: Date().timeIntervalSince1970 * 1000, id: id)
    entries.withLock {
      if $0.count >= 32768 { $0.removeFirst(16384) }
      $0.append(entry)
    }
  }

  public static func take(reset: Bool) -> String {
    let snapshot = entries.withLock { entries in
      let snapshot = entries
      if reset { entries.removeAll(keepingCapacity: true) }
      return snapshot
    }
    let rows = snapshot.map { ["stage": $0.stage, "detail": $0.detail, "phase": $0.phase, "at": $0.at, "id": String($0.id)] as [String: Any] }
    guard let data = try? JSONSerialization.data(withJSONObject: rows), let json = String(data: data, encoding: .utf8) else { return "[]" }
    return json
  }
}
#endif
