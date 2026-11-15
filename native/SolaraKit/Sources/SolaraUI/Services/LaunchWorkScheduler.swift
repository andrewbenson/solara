import AppKit
import Foundation

@MainActor
public final class LaunchWorkScheduler {
  public struct Window: Hashable {
    public let id: String
    public let generation: UInt64
  }

  public enum Prerequisite: Int, CaseIterable {
    case store, owner, slots, guest, chromeCommit
  }

  private struct Readiness {
    let window: Window
    var stage = -1
    var suspended = false
    var committedAt: Double?
  }

  private struct Job {
    let token: UUID
    let id: String
    let window: Window?
    var priority: Int
    let deadline: Double
    var order: UInt64
    let chunk: (Double) -> Bool
    let cancelled: (() -> Void)?
  }

  private let clock: () -> Double
  private let epoch: () -> Double
  private var windows: [String: Readiness] = [:]
  private var jobs: [UUID: Job] = [:]
  private var order: UInt64 = 0
  private var stopped = false
  private var running = false
  public var paused = false
  public private(set) var queued = 0
  public private(set) var executed = 0
  public private(set) var cancelled = 0
  public private(set) var idleOpportunities = 0
  public private(set) var chromeCommittedAt: Double?
  public var pending: Int { jobs.count }
  public var hasReadyWindow: Bool { windows.values.contains { $0.stage == Prerequisite.chromeCommit.rawValue && !$0.suspended } }
  public var runnable: Bool { !stopped && !paused && hasReadyWindow && jobs.values.contains(where: eligible) }

  public init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, epoch: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
    self.clock = clock
    self.epoch = epoch
  }

  @discardableResult
  public func begin(windowId: String, generation: UInt64) -> Window {
    let token = Window(id: windowId, generation: generation)
    if let previous = windows[windowId], previous.window != token { end(previous.window) }
    if windows[windowId] == nil { windows[windowId] = Readiness(window: token) }
    return token
  }

  public func window(_ id: String) -> Window? { windows[id]?.window }

  public func contains(_ token: UUID) -> Bool { jobs[token] != nil }

  private func eligible(_ job: Job) -> Bool {
    job.window.map {
      windows[$0.id]?.window == $0 && windows[$0.id]?.stage == Prerequisite.chromeCommit.rawValue && windows[$0.id]?.suspended == false
    } ?? true
  }

  @discardableResult
  public func reach(_ prerequisite: Prerequisite, window: Window) -> Bool {
    guard !stopped, var readiness = windows[window.id], readiness.window == window,
      prerequisite.rawValue <= readiness.stage + 1 else { return false }
    if prerequisite.rawValue <= readiness.stage { return true }
    readiness.stage = prerequisite.rawValue
    if prerequisite == .chromeCommit {
      readiness.committedAt = epoch()
      if chromeCommittedAt == nil { chromeCommittedAt = readiness.committedAt }
    }
    windows[window.id] = readiness
    return true
  }

  public func suspend(_ window: Window, _ suspended: Bool) {
    guard windows[window.id]?.window == window else { return }
    windows[window.id]?.suspended = suspended
    if suspended {
      for token in jobs.values.filter({ $0.window == window }).map(\.token) { cancel(token) }
    }
  }

  public func end(_ window: Window) {
    guard windows[window.id]?.window == window else { return }
    windows[window.id] = nil
    for token in jobs.values.filter({ $0.window == window }).map(\.token) { cancel(token) }
  }

  @discardableResult
  public func enqueue(id: String, window: Window? = nil, priority: Int = 0, deadline: Double = 30,
    cancelled onCancel: (() -> Void)? = nil, chunk: @escaping (Double) -> Bool) -> UUID {
    let token = UUID()
    guard !stopped, window.map({ windows[$0.id]?.window == $0 }) ?? true else { onCancel?(); return token }
    order += 1
    jobs[token] = Job(token: token, id: id, window: window, priority: priority,
      deadline: clock() + max(0, deadline), order: order, chunk: chunk, cancelled: onCancel)
    queued += 1
    return token
  }

  public func cancel(_ token: UUID) {
    guard let job = jobs.removeValue(forKey: token) else { return }
    cancelled += 1
    job.cancelled?()
  }

  public func promote(_ token: UUID) { jobs[token]?.priority = Int.max }

  @discardableResult
  public func idleOpportunity() -> Bool {
    guard runnable, !running else { return false }
    running = true
    defer { running = false }
    idleOpportunities += 1
    let now = clock()
    let next = jobs.values.filter(eligible).min { a, b in
      let aExpired = a.deadline <= now, bExpired = b.deadline <= now
      if aExpired != bExpired { return aExpired }
      if aExpired { return a.order < b.order }
      if a.priority != b.priority { return a.priority > b.priority }
      return a.order < b.order
    }
    guard let next else { return false }
    executed += 1
    let complete = next.chunk(now + 0.002)
    guard jobs[next.token] != nil else { return true }
    if complete {
      jobs[next.token] = nil
    } else {
      order += 1
      jobs[next.token]?.order = order
    }
    return true
  }

  public func quit() {
    stopped = true
    windows = [:]
    cancelPending()
  }

  public func cancelPending() { for token in Array(jobs.keys) { cancel(token) } }

  public func invalidateWindows() { for window in windows.values.map(\.window) { end(window) } }

  public func snapshot() -> [String: Any] {
    let states: [[String: Any]] = windows.values.sorted { $0.window.id < $1.window.id }.map {
      ["windowId": $0.window.id, "generation": $0.window.generation,
        "storeReady": $0.stage >= 0, "ownerReady": $0.stage >= 1, "slotsReady": $0.stage >= 2,
        "guestReady": $0.stage >= 3, "suspended": $0.suspended,
        "chromeCommittedAt": $0.committedAt.map { $0 as Any } ?? NSNull()]
    }
    return ["version": 1, "queued": queued, "executed": executed, "cancelled": cancelled, "pending": pending,
      "paused": paused, "idleOpportunities": idleOpportunities, "windows": states,
      "chromeCommittedAt": chromeCommittedAt.map { $0 as Any } ?? NSNull(), "selectedPageDrawAt": NSNull()]
  }
}

@MainActor
public final class LaunchWorkInteraction {
  private let clock: () -> Double
  private var holds: [String: Int] = [:]
  private var resizing: Set<Int> = []
  private var owners: [String: (generation: UInt64, number: Int)] = [:]
  private var quietUntil = 0.0
  public var held: Bool { !holds.isEmpty || !resizing.isEmpty }
  public var paused: Bool { held || clock() < quietUntil }
  public var retryDelay: Double { max(0.016, quietUntil - clock()) }

  public init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

  public func activity(quietFor seconds: Double = 0.12) { quietUntil = clock() + max(0, seconds) }

  public func register(windowId: String, generation: UInt64, number: Int) {
    if let previous = owners[windowId], previous.generation != generation { close(window: previous.number) }
    owners[windowId] = (generation, number)
  }

  public func setRetained(windowId: String, generation: UInt64, on: Bool) {
    guard on, let owner = owners[windowId], owner.generation == generation else { return }
    close(window: owner.number)
  }

  public func endOwner(windowId: String, generation: UInt64) {
    guard let owner = owners[windowId], owner.generation == generation else { return }
    owners[windowId] = nil
    close(window: owner.number)
  }

  public func hold(_ id: String, window: Int, active: Bool) {
    if active { holds[id] = window } else { holds[id] = nil }
    activity()
  }

  public func resize(window: Int, active: Bool) {
    if active { resizing.insert(window) } else { resizing.remove(window) }
    activity()
  }

  public func close(window: Int) {
    holds = holds.filter { $0.value != window }
    resizing.remove(window)
    activity()
  }

  public func deactivate() {
    holds = [:]
    resizing = []
    activity()
  }
}

@MainActor
public enum LaunchGuestReadiness {
  public static func contains(in root: NSView, windowId: String) -> Bool {
    guard !root.isHidden, !root.bounds.isEmpty else { return false }
    if root.accessibilityIdentifier() == "solara-window-guest.\(windowId)" { return true }
    return root.subviews.contains { contains(in: $0, windowId: windowId) }
  }
}
