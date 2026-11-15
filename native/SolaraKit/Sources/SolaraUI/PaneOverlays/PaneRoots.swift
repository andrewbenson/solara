import AppKit

@MainActor
public final class PaneRoots {
  public typealias Schedule = @MainActor (_ delay: TimeInterval, _ run: @escaping @MainActor () -> Void) -> (() -> Void)

  public static let grace: TimeInterval = 1

  public let windowId: String
  public var onEnd: ((_ tabId: String, _ root: NSView) -> Void)?
  public var onShown: ((_ tabId: String, _ root: NSView, _ shown: Bool) -> Void)?
  private let makeRoot: (_ tabId: String) -> NSView?
  private let container: (_ tabId: String) -> NSView?
  private let schedule: Schedule
  private var roots: [String: NSView] = [:]
  private var appeared: Set<String> = []
  private var retiring: [String: (generation: Int, cancel: () -> Void)] = [:]
  private var generation = 0
  private var stopped = false

  public init(
    windowId: String,
    makeRoot: @escaping (_ tabId: String) -> NSView?,
    container: @escaping (_ tabId: String) -> NSView?,
    schedule: @escaping Schedule = PaneRoots.mainQueue
  ) {
    self.windowId = windowId
    self.makeRoot = makeRoot
    self.container = container
    self.schedule = schedule
  }

  nonisolated public static func mainQueue(_ delay: TimeInterval, _ run: @escaping @MainActor () -> Void) -> (() -> Void) {
    let work = DispatchWorkItem { MainActor.assumeIsolated { run() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return { work.cancel() }
  }

  public var tabIds: Set<String> { Set(roots.keys) }

  public func root(_ tabId: String) -> NSView? { roots[tabId] }

  public func isRetiring(_ tabId: String) -> Bool { retiring[tabId] != nil }

  public func update(visible: Set<String>, open: Set<String>) {
    guard !stopped else { return }
    for tabId in roots.keys where !open.contains(tabId) { end(tabId) }
    var shown = Set<String>()
    for tabId in visible where open.contains(tabId) && show(tabId) { shown.insert(tabId) }
    for tabId in roots.keys where !shown.contains(tabId) && retiring[tabId] == nil { retire(tabId) }
  }

  public func contentAppeared(_ tabId: String, root: NSView) {
    guard roots[tabId] === root else { return }
    appeared.insert(tabId)
    if retiring[tabId] == nil { setShown(tabId, root, true) }
  }

  public func stop() {
    stopped = true
    for tabId in Array(roots.keys) { end(tabId) }
  }

  private func show(_ tabId: String) -> Bool {
    guard let into = container(tabId) else { return false }
    retiring.removeValue(forKey: tabId)?.cancel()
    let root: NSView
    if let existing = roots[tabId] {
      root = existing
    } else {
      guard let made = makeRoot(tabId) else { return false }
      made.isHidden = true
      made.autoresizingMask = [.width, .height]
      roots[tabId] = made
      root = made
    }
    if root.superview !== into {
      root.removeFromSuperview()
      into.addSubview(root, positioned: .below, relativeTo: nil)
    }
    if root.frame != into.bounds { root.frame = into.bounds }
    if appeared.contains(tabId) { setShown(tabId, root, true) }
    return true
  }

  private func retire(_ tabId: String) {
    if let root = roots[tabId] { setShown(tabId, root, false) }
    generation += 1
    let mine = generation
    let cancel = schedule(Self.grace) { [weak self] in
      guard let self, self.retiring[tabId]?.generation == mine else { return }
      self.retiring[tabId] = nil
      self.end(tabId)
    }
    retiring[tabId] = (mine, cancel)
  }

  private func setShown(_ tabId: String, _ root: NSView, _ shown: Bool) {
    guard root.isHidden == shown else { return }
    root.isHidden = !shown
    onShown?(tabId, root, shown)
  }

  private func end(_ tabId: String) {
    retiring.removeValue(forKey: tabId)?.cancel()
    appeared.remove(tabId)
    guard let root = roots.removeValue(forKey: tabId) else { return }
    root.removeFromSuperview()
    onEnd?(tabId, root)
  }
}

@MainActor
public final class PaneGuestLifetime {
  private static var nextGeneration: UInt64 = 0
  public private(set) var generation: UInt64 = 0
  public private(set) var generations = Set<UInt64>()
  public private(set) var shown = false
  public private(set) var retired = false
  public private(set) var ended = false
  public var onEnd: (() -> Void)?
  private var announced = Set<UInt64>()

  public init() {}

  public func setShown(_ shown: Bool) {
    guard !retired, !ended, self.shown != shown else { return }
    self.shown = shown
    if shown {
      precondition(Self.nextGeneration < 9_007_199_254_740_991)
      Self.nextGeneration += 1
      generation = Self.nextGeneration
      generations.insert(generation)
    }
  }

  public func announce(generation: UInt64) {
    guard generations.contains(generation) else { return }
    announced.insert(generation)
  }

  public func release(generation: UInt64) {
    guard generations.contains(generation) else { return }
    announced.remove(generation)
    finish()
  }

  public func retire() {
    retired = true
    shown = false
    finish()
  }

  public func abandon() {
    retired = true
    shown = false
    announced = []
    finish()
  }

  private func finish() {
    guard retired, announced.isEmpty, !ended else { return }
    ended = true
    let end = onEnd
    onEnd = nil
    end?()
  }
}

public struct PaneGuestAnnouncements: Sendable {
  private var tickets: [UInt64: Set<UInt64>] = [:]
  private var nextLease: UInt64 = 0

  public init() {}

  public mutating func acquire(_ generation: UInt64) -> UInt64 {
    precondition(nextLease < 9_007_199_254_740_991)
    nextLease += 1
    announce(generation, ticket: nextLease)
    return nextLease
  }

  public mutating func announce(_ generation: UInt64, ticket: UInt64) {
    tickets[generation, default: []].insert(ticket)
  }

  public mutating func reject(_ generation: UInt64, ticket: UInt64) -> Bool {
    guard var current = tickets[generation], current.remove(ticket) != nil else { return false }
    tickets[generation] = current.isEmpty ? nil : current
    return current.isEmpty
  }

  public func contains(_ generation: UInt64) -> Bool { tickets[generation]?.isEmpty == false }

  public mutating func remove(_ generation: UInt64) { tickets[generation] = nil }
}
