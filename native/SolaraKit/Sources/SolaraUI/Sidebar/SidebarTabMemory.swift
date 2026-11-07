import Foundation
import CoreFoundation

public enum SidebarTabMemory {
  public static let highBytes: Double = 800 * 1024 * 1024

  public static func isHigh(_ bytes: Double) -> Bool { bytes.isFinite && bytes > highBytes }

  public static func text(_ bytes: Double?) -> String {
    guard let bytes, bytes.isFinite, bytes >= 0 else { return "Memory usage: —" }
    let value: String
    if bytes < 1024 * 1024 * 1024 {
      value = String(format: "%.0f MB", locale: Locale(identifier: "en_US_POSIX"), bytes / (1024 * 1024))
    } else {
      let gb = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), bytes / (1024 * 1024 * 1024))
      value = (gb.hasSuffix(".0") ? String(gb.dropLast(2)) : gb) + " GB"
    }
    return isHigh(bytes) ? "High memory usage · " + value : "Memory usage: " + value
  }
}

public enum SidebarTabMemoryRow: Equatable, Sendable {
  case absent, unknown, bytes(Double)
}

public struct TabMemoryReading: Equatable, Sendable {
  public var bytes: Double
  public var source: String
  public var at: Date

  public init(bytes: Double, source: String, at: Date) {
    self.bytes = bytes
    self.source = source
    self.at = at
  }
}

public enum TabMemoryReply: Equatable, Sendable {
  case unavailable
  case rows([Int: TabMemoryReading])

  public static func decode(_ json: [String: Any]) -> TabMemoryReply {
    guard !json.keys.contains("error"), let tabs = json["tabs"] as? [Any] else { return .unavailable }
    var readings: [Int: TabMemoryReading] = [:]
    for value in tabs {
      guard let row = value as? [String: Any],
        let tabId = integer(row["tabId"]),
        let bytes = number(row["bytes"]), bytes >= 0,
        let source = row["source"] as? String, source == "attribution" || source == "footprint",
        let at = number(row["at"])
      else { continue }
      readings[tabId] = TabMemoryReading(bytes: bytes, source: source, at: Date(timeIntervalSince1970: at / 1000))
    }
    return .rows(readings)
  }

  public static func decode(_ json: Any) -> TabMemoryReply {
    guard let json = json as? [String: Any] else { return .unavailable }
    return decode(json)
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let value = value as? NSNumber, number(value) != nil else { return nil }
    return value as? Int
  }

  private static func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
    return value.doubleValue
  }
}

public enum TabMemoryKey {
  public static func key(tabId: String, document: String) -> String { tabId + "\n" + document }

  public static func parts(_ key: String) -> (tabId: String, document: String) {
    guard let split = key.firstIndex(of: "\n") else { return (key, "") }
    return (String(key[..<split]), String(key[key.index(after: split)...]))
  }
}

public struct TabMemoryRequest: Sendable {
  private let asked: [String: (sessionId: Int, document: String)]

  public init(asked: [String: (sessionId: Int, document: String)]) {
    self.asked = asked
  }

  public var sessionIds: [Int] { Set(asked.values.map(\.sessionId)).sorted() }

  public func readings(_ rows: [Int: TabMemoryReading], currentDocument: (String) -> String?) -> [String: TabMemoryReading] {
    asked.reduce(into: [:]) { values, entry in
      guard currentDocument(entry.key) == entry.value.document, let reading = rows[entry.value.sessionId] else { return }
      values[entry.key] = reading
    }
  }
}

@MainActor
public final class TabMemoryCache {
  public typealias Query = @MainActor (_ tabIds: [String], _ reply: @escaping @MainActor ([String: TabMemoryReading]) -> Void) -> Void

  private struct Pending {
    let id: UUID
    var answered: [@MainActor (String) -> Void]
  }

  public var query: Query?
  private var readings: [String: TabMemoryReading] = [:]
  private var pending: [String: Pending] = [:]

  public init() {}

  public func row(_ tabId: String, sleeping: Bool) -> SidebarTabMemoryRow {
    guard query != nil, !sleeping else { return .absent }
    return readings[tabId].map { .bytes($0.bytes) } ?? .unknown
  }

  public func ask(_ tabId: String, answered: @escaping @MainActor (String) -> Void) {
    guard let query else { return }
    if pending[tabId] != nil {
      pending[tabId]?.answered.append(answered)
      return
    }
    let id = UUID()
    pending[tabId] = Pending(id: id, answered: [answered])
    query([tabId]) { [weak self] values in
      guard let self, let request = self.pending[tabId], request.id == id else { return }
      self.pending[tabId] = nil
      self.readings[tabId] = values[tabId]
      for answer in request.answered { answer(tabId) }
    }
  }

  public func forget(_ tabId: String) { readings[tabId] = nil }

  public func clear() {
    readings.removeAll()
    pending.removeAll()
  }
}
