import Foundation
import CoreFoundation
import SolaraStore
import Synchronization

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

private final class TabMemoryDocuments: Sendable {
  let keys = Mutex<[String: Int]>([:])

  func invalidate(_ commit: Commit) -> Bool {
    let changed = Set(commit.changes.tabs.upserted + commit.changes.tabs.removed)
    return keys.withLock { keys in
      let before = keys.count
      keys = keys.filter { key, admitted in
        let parts = TabMemoryKey.parts(key)
        return commit.rev <= admitted || !changed.contains(parts.tabId) || commit.state.tabs[parts.tabId]?.url == parts.document
      }
      return keys.count != before
    }
  }
}

@MainActor
public final class TabMemoryCache {
  public typealias Query = @MainActor (_ tabIds: [String], _ reply: @escaping @MainActor ([String: TabMemoryReading]) -> Void) -> Void

  private typealias Work = @MainActor () -> Void

  private struct Pending {
    let id: UUID
    var answered: [@MainActor (String) -> Void]
  }

  private struct Reply {
    let id: UUID
    let reading: TabMemoryReading?
  }

  private struct Deferred {
    var answered: [@MainActor (String) -> Void] = []
    var reply: Reply?
  }

  public var query: Query?
  private var readings: [String: TabMemoryReading] = [:]
  private var pending: [String: Pending] = [:]
  private var recent: [String] = []
  private var deferred: [String: Deferred] = [:]
  private var scheduledDelivery: UUID?
  private var flushing = false
  private let capacity = 128
  private var observedStore: Store?
  private var storeListener: Int?
  private var documents = TabMemoryDocuments()
  private var observesDocuments = false

  public init() {}

  isolated deinit {
    if let storeListener { observedStore?.unsubscribe(storeListener) }
  }

  public func observeDocuments(in store: Store?) {
    guard !observesDocuments || observedStore !== store else { return }
    if let storeListener { observedStore?.unsubscribe(storeListener) }
    storeListener = nil
    documents = TabMemoryDocuments()
    observesDocuments = true
    observedStore = store
    clear()
    guard let store else { return }
    let documents = documents
    storeListener = store.subscribe { [weak self] commit in
      guard !commit.changes.tabs.isEmpty, documents.invalidate(commit) else { return }
      if Thread.isMainThread {
        MainActor.assumeIsolated { self?.removeInvalidated(documents) }
      } else {
        Task { @MainActor [weak self] in self?.removeInvalidated(documents) }
      }
    }
  }

  private func removeInvalidated(_ documents: TabMemoryDocuments) {
    guard self.documents === documents else { return }
    for key in recent where !documents.keys.withLock({ $0[key] != nil }) { discardInvalidated(key) }
  }

  private func documentMatches(_ key: String) -> Bool {
    guard observesDocuments else { return true }
    let parts = TabMemoryKey.parts(key)
    return observedStore?.state.tabs[parts.tabId]?.url == parts.document
  }

  private func isCurrent(_ key: String) -> Bool {
    documentMatches(key) && (!observesDocuments || documents.keys.withLock { $0[key] != nil })
  }

  public func row(_ tabId: String, sleeping: Bool) -> SidebarTabMemoryRow {
    guard query != nil, !sleeping else { return .absent }
    guard let store = observedStore else { return cachedRow(tabId) }
    return store.sequence {
      let cursor = store.deliveryCursor()
      guard cursor.committed == cursor.delivered else { return .unknown }
      return cachedRow(tabId)
    }
  }

  private func cachedRow(_ tabId: String) -> SidebarTabMemoryRow {
    guard isCurrent(tabId) else {
      discardInvalidated(tabId)
      return .unknown
    }
    guard let reading = readings[tabId] else { return .unknown }
    touch(tabId)
    return .bytes(reading.bytes)
  }

  private func scheduleDelivery(_ store: Store) {
    guard scheduledDelivery == nil else { return }
    let id = UUID()
    scheduledDelivery = id
    let documents = documents
    store.afterSequence { [weak self] in
      if Thread.isMainThread {
        MainActor.assumeIsolated { self?.resumeDelivery(documents, id: id) }
      } else {
        Task { @MainActor [weak self] in self?.resumeDelivery(documents, id: id) }
      }
    }
  }

  private func resumeDelivery(_ documents: TabMemoryDocuments, id: UUID) {
    guard self.documents === documents, scheduledDelivery == id else { return }
    scheduledDelivery = nil
    flushDeferred()
  }

  private func flushDeferred() {
    guard !flushing, !deferred.isEmpty else { return }
    flushing = true
    let work: [Work]
    if let store = observedStore {
      work = store.sequence {
        let cursor = store.deliveryCursor()
        guard cursor.committed == cursor.delivered else {
          scheduleDelivery(store)
          return []
        }
        return takeDeferred()
      }
    } else {
      work = takeDeferred()
    }
    flushing = false
    for perform in work { perform() }
    if !deferred.isEmpty, scheduledDelivery == nil { flushDeferred() }
  }

  private func takeDeferred() -> [Work] {
    let batch = deferred
    deferred.removeAll()
    var work: [Work] = []
    for key in recent {
      guard let action = batch[key] else { continue }
      for answer in action.answered {
        if let query = askAfterDelivery(key, answered: answer) { work.append(query) }
      }
      if let reply = action.reply, let answer = accept(key, reply: reply) { work.append(answer) }
    }
    return work
  }

  public func ask(_ tabId: String, answered: @escaping @MainActor (String) -> Void) {
    guard query != nil else { return }
    touch(tabId)
    deferred[tabId, default: Deferred()].answered.append(answered)
    flushDeferred()
  }

  private func askAfterDelivery(_ tabId: String, answered: @escaping @MainActor (String) -> Void) -> Work? {
    guard let query, documentMatches(tabId) else {
      forget(tabId)
      return nil
    }
    if observesDocuments {
      let existed: Bool? = documents.keys.withLock { keys in
        let parts = TabMemoryKey.parts(tabId)
        guard let snapshot = observedStore?.committedSnapshot, snapshot.state.tabs[parts.tabId]?.url == parts.document else { return nil }
        guard keys[tabId] == nil else { return true }
        keys[tabId] = snapshot.rev
        return false
      }
      guard let existed else {
        forget(tabId)
        return nil
      }
      if !existed { retire(tabId) }
    }
    let tab = TabMemoryKey.parts(tabId).tabId
    for key in recent where key != tabId && TabMemoryKey.parts(key).tabId == tab { forget(key) }
    touch(tabId)
    if pending[tabId] != nil {
      pending[tabId]?.answered.append(answered)
      return nil
    }
    let id = UUID()
    pending[tabId] = Pending(id: id, answered: [answered])
    return { [weak self] in
      guard self?.pending[tabId]?.id == id else { return }
      query([tabId]) { [weak self] values in
        guard let self, self.pending[tabId]?.id == id else { return }
        self.deferred[tabId, default: Deferred()].reply = Reply(id: id, reading: values[tabId])
        self.flushDeferred()
      }
    }
  }

  private func accept(_ tabId: String, reply: Reply) -> Work? {
    guard let request = pending[tabId], request.id == reply.id else { return nil }
    guard isCurrent(tabId) else {
      forget(tabId)
      return nil
    }
    pending[tabId] = nil
    readings[tabId] = reply.reading
    if reply.reading == nil { forget(tabId) }
    return { for answer in request.answered { answer(tabId) } }
  }

  private func touch(_ tabId: String) {
    recent.removeAll { $0 == tabId }
    recent.append(tabId)
    while recent.count > capacity { forget(recent[0]) }
  }

  private func discardInvalidated(_ tabId: String) {
    let answered = deferred[tabId]?.answered ?? []
    forget(tabId)
    guard !answered.isEmpty else { return }
    touch(tabId)
    deferred[tabId] = Deferred(answered: answered, reply: nil)
  }

  private func retire(_ tabId: String) {
    readings[tabId] = nil
    pending[tabId] = nil
    deferred[tabId] = nil
    recent.removeAll { $0 == tabId }
  }

  public func forget(_ tabId: String) {
    documents.keys.withLock { $0.removeValue(forKey: tabId) }
    retire(tabId)
  }

  public func clear() {
    readings.removeAll()
    pending.removeAll()
    deferred.removeAll()
    scheduledDelivery = nil
    recent.removeAll()
    documents.keys.withLock { $0.removeAll() }
  }
}
