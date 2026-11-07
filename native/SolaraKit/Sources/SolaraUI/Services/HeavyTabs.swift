import AppKit
import Foundation

public enum HeavyTabReason: String, Sendable, Equatable {
  case memory
  case cpu

  public var tooltip: String {
    switch self {
    case .memory: "This tab is using a lot of memory"
    case .cpu: "This tab is using a lot of CPU"
    }
  }
}

public struct TabCPUSample: Equatable, Sendable {
  public var cpuMs: Double
  public var elapsedMs: Double
  public var measurementId: String

  public init(cpuMs: Double, elapsedMs: Double, measurementId: String) {
    self.cpuMs = cpuMs
    self.elapsedMs = elapsedMs
    self.measurementId = measurementId
  }
}

public enum TabCPUReply {
  public static func decode(_ json: [String: Any]) -> [Int: TabCPUSample]? {
    guard json["error"] == nil, let rows = json["tabs"] as? [Any] else { return nil }
    var out: [Int: TabCPUSample] = [:]
    for row in rows {
      guard let row = row as? [String: Any], let id = integer(row["tabId"]), let cpu = number(row["cpuMs"]), cpu >= 0,
        let elapsed = number(row["elapsedMs"]), elapsed >= 0, let measurement = row["measurementId"] as? String, !measurement.isEmpty,
        row["source"] as? String == "attribution", number(row["at"]) != nil
      else { continue }
      out[id] = TabCPUSample(cpuMs: cpu, elapsedMs: elapsed, measurementId: measurement)
    }
    return out
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let value = value as? NSNumber, let whole = number(value), whole.rounded() == whole, abs(whole) <= Double(Int32.max) else { return nil }
    return Int(whole)
  }

  private static func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
    return value.doubleValue
  }
}

public struct HeavyTabPolicy: Sendable {
  public static let intervalMs: Double = 15_000
  public static let memoryEvery = 4
  public static let cpuPercent: Double = 50
  public static let cpuIntervals = 4
  public static let memoryIntervals = 2
  public static let clearIntervals = 2
  public static let staleIntervalMs: Double = 45_000

  private struct Tab: Sendable {
    var baseline: TabCPUSample?
    var cpuHigh = 0
    var cpuLow = 0
    var cpuHeavy = false
    var memoryHigh = 0
    var memoryLow = 0
    var memoryHeavy = false
  }

  private var tabs: [String: Tab] = [:]

  public init() {}

  public var heavy: [String: HeavyTabReason] {
    tabs.reduce(into: [:]) { out, entry in
      if entry.value.memoryHeavy { out[entry.key] = .memory } else if entry.value.cpuHeavy { out[entry.key] = .cpu }
    }
  }

  public mutating func ingest(_ tabId: String, cpu: TabCPUSample?, memoryBytes: Double?) {
    ingest(tabId, cpu: cpu, memory: .sampled(memoryBytes))
  }

  public enum Memory: Sendable {
    case skipped
    case sampled(Double?)
  }

  public mutating func ingest(_ tabId: String, cpu: TabCPUSample?, memory: Memory) {
    var tab = tabs[tabId] ?? Tab()
    Self.cpu(&tab, cpu)
    if case .sampled(let bytes) = memory { Self.memory(&tab, bytes) }
    tabs[tabId] = tab
  }

  public mutating func retain(_ tabIds: Set<String>) {
    tabs = tabs.filter { tabIds.contains($0.key) }
  }

  private static func cpu(_ tab: inout Tab, _ sample: TabCPUSample?) {
    guard let sample else {
      tab.baseline = nil
      resetCPU(&tab)
      return
    }
    guard let base = tab.baseline, base.measurementId == sample.measurementId, sample.cpuMs >= base.cpuMs else {
      tab.baseline = sample
      resetCPU(&tab)
      return
    }
    let interval = sample.elapsedMs - base.elapsedMs
    guard interval > 0 else { return }
    tab.baseline = sample
    guard interval <= staleIntervalMs else {
      tab.cpuHigh = 0
      tab.cpuLow = 0
      return
    }
    let percent = 100 * (sample.cpuMs - base.cpuMs) / interval
    if percent > cpuPercent {
      tab.cpuHigh += 1
      tab.cpuLow = 0
      if tab.cpuHigh >= cpuIntervals { tab.cpuHeavy = true }
    } else {
      tab.cpuLow += 1
      tab.cpuHigh = 0
      if tab.cpuLow >= clearIntervals { tab.cpuHeavy = false }
    }
  }

  private static func resetCPU(_ tab: inout Tab) {
    tab.cpuHigh = 0
    tab.cpuLow = 0
    tab.cpuHeavy = false
  }

  private static func memory(_ tab: inout Tab, _ bytes: Double?) {
    guard let bytes else {
      tab.memoryHigh = 0
      tab.memoryLow = 0
      tab.memoryHeavy = false
      return
    }
    if SidebarTabMemory.isHigh(bytes) {
      tab.memoryHigh += 1
      tab.memoryLow = 0
      if tab.memoryHigh >= memoryIntervals { tab.memoryHeavy = true }
    } else {
      tab.memoryLow += 1
      tab.memoryHigh = 0
      if tab.memoryLow >= clearIntervals { tab.memoryHeavy = false }
    }
  }
}

public struct HeavyTabSamples: Sendable {
  public var cpu: [String: TabCPUSample]
  public var memoryBytes: [String: Double]?

  public init(cpu: [String: TabCPUSample], memoryBytes: [String: Double]?) {
    self.cpu = cpu
    self.memoryBytes = memoryBytes
  }
}

@MainActor
public enum HeavyTabs {
  public static let changed = Notification.Name("SolaraHeavyTabsChanged")
  public private(set) static var current: [String: HeavyTabReason] = [:]
  public static var sleep: (@MainActor (String) async -> Bool)?

  static func publish(_ next: [String: HeavyTabReason]) {
    guard next != current else { return }
    current = next
    NotificationCenter.default.post(name: changed, object: nil)
  }
}

@MainActor
public final class HeavyTabMonitor {
  public typealias Sample = @MainActor (_ tabIds: [String], _ memory: Bool, _ reply: @escaping @MainActor (HeavyTabSamples?) -> Void) -> Void
  public typealias Candidates = @MainActor () -> [String]
  public typealias Schedule = @MainActor (Double, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

  public static let maxTabs = 40

  private let sample: Sample
  private let candidates: Candidates
  private let schedule: Schedule
  private var policy = HeavyTabPolicy()
  private let notificationCenter: NotificationCenter
  private var cancel: (@MainActor () -> Void)?
  private var inFlight: UUID?
  private var ticks = 0
  private var active: Bool
  private var observers: [NSObjectProtocol] = []

  public init(sample: @escaping Sample, candidates: @escaping Candidates, schedule: @escaping Schedule = TabSleepRunner.scheduleTicks,
    initiallyActive: Bool? = nil, notificationCenter: NotificationCenter = .default) {
    self.sample = sample
    self.candidates = candidates
    self.schedule = schedule
    self.notificationCenter = notificationCenter
    active = initiallyActive ?? NSApplication.shared.isActive
  }

  public var isRunning: Bool { cancel != nil }

  public func start() {
    guard cancel == nil else { return }
    cancel = schedule(HeavyTabPolicy.intervalMs) { [weak self] in self?.tick() }
    for (name, on) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
      observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setActive(on) }
      })
    }
  }

  public func stop() {
    cancel?()
    cancel = nil
    inFlight = nil
    ticks = 0
    for observer in observers { notificationCenter.removeObserver(observer) }
    observers.removeAll()
    policy = HeavyTabPolicy()
    HeavyTabs.publish([:])
  }

  public func setActive(_ on: Bool) {
    guard on != active else { return }
    active = on
    guard on, cancel != nil else { return }
    ticks = 0
    tick()
  }

  public func tick() {
    guard cancel != nil, active, inFlight == nil else { return }
    let ids = Array(candidates().prefix(Self.maxTabs))
    guard !ids.isEmpty else {
      policy.retain([])
      HeavyTabs.publish(policy.heavy)
      return
    }
    let memory = ticks % HeavyTabPolicy.memoryEvery == 0
    ticks += 1
    let ticket = UUID()
    inFlight = ticket
    sample(ids, memory) { [weak self] samples in
      guard let self, self.inFlight == ticket else { return }
      self.inFlight = nil
      self.policy.retain(Set(ids))
      for id in ids {
        let reading: HeavyTabPolicy.Memory = memory ? .sampled(samples?.memoryBytes?[id]) : .skipped
        self.policy.ingest(id, cpu: samples?.cpu[id], memory: reading)
      }
      HeavyTabs.publish(self.policy.heavy)
    }
  }
}
