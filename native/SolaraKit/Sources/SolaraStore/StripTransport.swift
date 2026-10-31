import Foundation
import SolaraModel
import Synchronization

public protocol StripEngine: AnyObject {
  func observe(_ receive: @escaping (JSONValue) -> Void) -> Int
  func stopObserving(_ token: Int)
  func snapshot() -> JSONValue
  func send(id: Int, command: JSONValue)
}

public typealias StripSequencer = (@escaping () -> Void) -> Void

@MainActor
public final class StripTransport {
  private let store: Store
  nonisolated private let receipts: StripReceipts
  private let engine: StripEngine
  private let sequence: StripSequencer
  private let later: (@escaping @MainActor () -> Void) -> Void
  nonisolated private let trouble: @Sendable (String) -> Void
  private var token: Int?
  private var listener: Int?
  private var refusals: Int?
  private var ready = false
  private var generation = 0
  private var lastReactedRev = -1
  private var projectSoon = false
  private var placed: Table<Tab>?
  private var windows: Table<BrowserWindow>?
  private var groups: Table<TabGroup>?

  public init(
    store: Store, engine: StripEngine, sequence: StripSequencer? = nil,
    later: @escaping (@escaping @MainActor () -> Void) -> Void = { work in DispatchQueue.main.async { MainActor.assumeIsolated(work) } },
    trouble: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data("SolaraStore: \($0)\n".utf8)) }
  ) {
    self.store = store
    self.engine = engine
    receipts = StripReceipts(store: store)
    self.sequence = sequence ?? { work in store.sequence(work) }
    self.later = later
    self.trouble = trouble
  }

  public func start() {
    guard token == nil else { return }
    generation = receipts.begin()
    let generation = generation
    refusals = store.observeSequencedFailures { [weak self, trouble] command, error in
      guard command.name == "stripTransaction" else { return }
      let message = "the store refused \(command.name): \(error)"
      let report: @MainActor () -> Void = {
        guard let self, self.token != nil, self.generation == generation else { return }
        trouble(message)
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated(report)
      } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(report) }
      }
    }
    token = engine.observe { [weak self] tx in self?.hear(tx, generation: generation) }
    listener = store.subscribe { [weak self] commit in self?.heard(commit) }
    store.sequence {
      let snapshot = engine.snapshot()
      Self.perform(Command("stripSnapshot", [snapshot]), generation: generation, store: store, engine: engine, receipts: receipts, trouble: trouble)
      ready = true
      receipts.activate(generation)
    }
    scheduleProject()
  }

  public func stop() {
    receipts.stop()
    if let token { engine.stopObserving(token) }
    if let listener { store.unsubscribe(listener) }
    if let refusals { store.unsubscribe(refusals) }
    token = nil
    listener = nil
    refusals = nil
    ready = false
    projectSoon = false
    placed = nil
    windows = nil
    groups = nil
    lastReactedRev = -1
  }

  private func run(_ command: Command) {
    let generation = generation
    sequence { [store, engine, receipts, trouble] in
      Self.perform(command, generation: generation, store: store, engine: engine, receipts: receipts, trouble: trouble)
    }
  }

  nonisolated private static func perform(
    _ command: Command, generation: Int, store: Store, engine: StripEngine, receipts: StripReceipts, trouble: @Sendable (String) -> Void
  ) {
    guard receipts.live(generation) else { return }
    let commit: Commit
    do {
      commit = try store.dispatch(command, origin: .engine)
    } catch {
      return trouble("the store refused \(command.name): \(error)")
    }
    for case .stripCommand(_, let id, let command) in commit.effects where receipts.live(generation) {
      engine.send(id: id, command: command)
    }
  }

  nonisolated private func hear(_ tx: JSONValue, generation: Int) {
    guard receipts.reserve(tx, generation: generation) else { return }
    let follow: @MainActor () -> Void = { [weak self] in
      guard let self, self.generation == generation else { return }
      self.receipts.flush()
      self.scheduleProject()
    }
    if Thread.isMainThread {
      MainActor.assumeIsolated(follow)
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated(follow) }
    }
  }

  nonisolated private func heard(_ commit: Commit) {
    if commit.origin != .engine, commit.effects.contains(where: { if case .stripCommand = $0 { true } else { false } }) {
      trouble("a \(commit.origin) commit planned a strip command that only the strip transport may send; dropped")
    }
    if Thread.isMainThread {
      MainActor.assumeIsolated { self.react(commit) }
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated { self.react(commit) } }
    }
  }

  private func react(_ commit: Commit) {
    guard commit.rev >= lastReactedRev else { return }
    lastReactedRev = commit.rev
    let s = commit.state
    defer {
      placed = s.tabs
      windows = s.windows
      groups = s.groups
    }
    guard ready, let placed, let windows, let groups else {
      if ready { scheduleProject() }
      return
    }
    if s.windows.changed(from: windows) || s.groups.changed(from: groups) || moved(s.tabs, from: placed) { scheduleProject() }
  }

  private func moved(_ tabs: Table<Tab>, from before: Table<Tab>) -> Bool {
    tabs.changedIds(from: before).contains { id in
      guard let a = tabs[id], let b = before[id] else { return true }
      return a.windowId != b.windowId || a.profileId != b.profileId || a.pinned != b.pinned
    }
  }

  private func scheduleProject() {
    if projectSoon || !ready { return }
    projectSoon = true
    let generation = generation
    later { [weak self] in
      guard let self, self.ready, self.generation == generation else { return }
      self.projectSoon = false
      self.run(Command("projectStrips"))
    }
  }
}

private final class StripReceipts: Sendable {
  private struct State: Sendable {
    var generation = 0
    var active = false
    var ready = false
    var early: [JSONValue] = []
  }

  private let store: Store
  private let state = Mutex(State())

  init(store: Store) { self.store = store }

  func begin() -> Int {
    store.sequence {
      state.withLock { state in
        state.generation += 1
        state.active = true
        state.ready = false
        state.early = []
        return state.generation
      }
    }
  }

  func reserve(_ tx: JSONValue, generation: Int) -> Bool {
    store.sequence {
      let ready = state.withLock { state -> Bool in
        guard state.active, state.generation == generation else { return false }
        guard state.ready else { state.early.append(tx); return false }
        return true
      }
      guard ready else { return false }
      store.enqueueSequenced(Command("stripTransaction", [tx]), origin: .engine)
      return true
    }
  }

  func activate(_ generation: Int) {
    store.sequence {
      let early = state.withLock { state -> [JSONValue] in
        guard state.active, state.generation == generation else { return [] }
        state.ready = true
        defer { state.early = [] }
        return state.early
      }
      for tx in early { store.enqueueSequenced(Command("stripTransaction", [tx]), origin: .engine) }
      store.sequence {}
    }
  }

  func stop() {
    store.sequence {
      state.withLock { state in
        state.active = false
        state.ready = false
        state.early = []
      }
    }
  }

  func live(_ generation: Int) -> Bool { state.withLock { $0.active && $0.generation == generation } }

  func flush() { store.sequence {} }
}
