import AppKit
import Foundation
import SolaraModel
import SolaraStore

@MainActor
public final class WindowLayoutController {
  public let shell: WindowShellView
  public let generation: UInt64
  public let anchors: WindowAnchors
  public private(set) var layoutGeneration: UInt64 = 0
  public private(set) var stopped = false
  public var onState: ((BrowserState, Int) -> Void)?
  public var onRemoved: (() -> Void)?
  public var onStop: (() -> Void)?
  public var subscriptionCount: Int { listener == nil ? 0 : 1 }
  private let store: Store
  private let inbox: WindowLayoutCommits
  private var lastInput: WindowLayoutInput?
  private var lastAnchors: [String: CGRect] = [:]
  private var listener: Int?
  private var started = false
  private var revision = -1
  private var observedWindow = false
  private var pending: (BrowserState, Int)?

  public init(shell: WindowShellView, generation: UInt64, store: Store) {
    self.shell = shell
    self.generation = generation
    self.store = store
    inbox = WindowLayoutCommits(windowId: shell.windowId)
    anchors = WindowAnchors(windowId: shell.windowId, windowGeneration: generation)
    #if SOLARA_PROBES
    NativeWorkCounters.host(self, windowId: shell.windowId, kind: "WindowLayoutController") { controller in
      (!controller.stopped, controller.subscriptionCount)
    }
    #endif
  }

  public func start() {
    guard !started, !stopped else { return }
    started = true
    inbox.deliver = { [weak self] state, revision, observedWindow in
      guard let self else { return }
      self.observedWindow = self.observedWindow || observedWindow
      self.receive(state, revision: revision, generation: self.generation)
    }
    let inbox = inbox
    store.sequence {
      listener = store.subscribe { commit in inbox.receive(commit.state, revision: commit.rev) }
      let snapshot = store.snapshot
      receive(snapshot.state, revision: snapshot.rev, generation: generation)
    }
  }

  public func receive(_ state: BrowserState, revision: Int, generation: UInt64) {
    guard started, !stopped, generation == self.generation, revision > self.revision else { return }
    self.revision = revision
    if state.windows[shell.windowId] != nil { observedWindow = true }
    pending = (state, revision)
    FrameUpdates.schedule(self) { [weak self] in self?.apply() }
  }

  private func apply() {
    guard !stopped, let pending else { return }
    self.pending = nil
    guard pending.0.windows[shell.windowId] != nil else {
      if observedWindow {
        let removed = onRemoved
        stop()
        removed?()
      }
      return
    }
    onState?(pending.0, pending.1)
  }

  @discardableResult
  public func apply(input: WindowLayoutInput, anchors childAnchors: [String: CGRect] = [:]) -> Bool {
    guard started, !stopped, input.windowId == shell.windowId, input.windowGeneration == generation,
      input.storeRevision >= revision, input.storeRevision >= (anchors.current?.storeRevision ?? -1) else { return false }
    shell.update { $0 = input.presentation }
    if let lastInput, lastInput.hasSameLayout(as: input), childAnchors == lastAnchors {
      _ = anchors.restamp(input)
      return false
    }
    let snapshot = WindowLayoutSnapshot.of(input, generation: layoutGeneration + 1)
    guard anchors.publish(WindowAnchorBatch(snapshot: snapshot, anchors: childAnchors)) else { return false }
    layoutGeneration = snapshot.generation
    lastInput = input
    lastAnchors = childAnchors
    return true
  }

  public func stop() {
    guard !stopped else { return }
    stopped = true
    inbox.stop()
    shell.stopLayoutMotion()
    anchors.stop()
    lastInput = nil
    lastAnchors = [:]
    if let listener { store.unsubscribe(listener) }
    listener = nil
    pending = nil
    onState = nil
    onRemoved = nil
    let cleanup = onStop
    onStop = nil
    cleanup?()
  }
}

private final class WindowLayoutCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  private let windowId: String
  private var observedWindow = false
  private var latest: (BrowserState, Int)?
  private var scheduled = false
  @MainActor var deliver: ((BrowserState, Int, Bool) -> Void)?

  @MainActor init(windowId: String) { self.windowId = windowId }

  func receive(_ state: BrowserState, revision: Int) {
    let schedule = lock.withLock { () -> Bool in
      guard !stopped, latest.map({ revision > $0.1 }) ?? true else { return false }
      observedWindow = observedWindow || state.windows[windowId] != nil
      latest = (state, revision)
      guard !scheduled else { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    if Thread.isMainThread {
      MainActor.assumeIsolated { flush() }
    } else {
      DispatchQueue.main.async { [weak self] in self?.flush() }
    }
  }

  @MainActor private func flush() {
    let pending = lock.withLock { () -> (BrowserState, Int, Bool)? in
      scheduled = false
      defer { latest = nil }
      guard !stopped, let latest else { return nil }
      return (latest.0, latest.1, observedWindow)
    }
    if let pending { deliver?(pending.0, pending.1, pending.2) }
  }

  @MainActor func stop() {
    lock.withLock {
      stopped = true
      latest = nil
    }
    deliver = nil
  }
}
